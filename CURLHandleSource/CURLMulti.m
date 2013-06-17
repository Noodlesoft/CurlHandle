//
//  CURLMulti.m
//  CURLHandle
//
//  Created by Sam Deane on 20/09/2012.
//  Copyright (c) 2013 Karelia Software. All rights reserved.
//

/**
 As mentioned in the header, the intention is that all access to the multi
 is controlled via our internal serial queue. The queue also protects additions to
 and removals from our array of the easy handles that we're managing.

 The CURL multi handle is generally not stored by the CURLMUlti object. 
 Instead it is set up when the dispatch timer is created, and it's value is
 captured by the timer block, which passes it on to everything else that needs it.
 
 The one (annoying) exception to this is that the socket_callback from curl
 only has one context value, which we use to pass a pointer to the CURLMulti
 object. Since the code called by this callback needs access to the multi value,
 we have to store it on CURLMulti - using the multiForSocket property.
 
 However, these callbacks only occur as a result of calling curl_multi_socket_action(),
 which only happens from within the processMulti: call. Therefore, we only set
 multiForSocket at the start of the processMulti call, and we clear it again at the end.

 The other GCD structures (self.timer and self.queue) should stay valid until they are destroyed
 as part of the shutdown process. 
 
 # Shutdown
 
 Shutdown just cancels the timer, and removes our reference to it. All other cleanup happens
 in the timer's cancel handler. This removes all easy handles from the multi, cleans it up, and
 disposes of it. It then releases the queue.
 
 Because the timer and the queue blocks both contain references to self, the object itself
 should not get deallocated until both the timer and queue have gone away. 
 
 Since the timer block is the only thing that actually causes activity on the multi, 
 once the timer has been cancelled, nothing else should actually touch the multi,
 other than the cleanup block.

 The queue itself is cleaned up on the main queue, once the rest of the shutdown process has finished.
 This additional paranoia (using the main queue for the cleanup) is probably not strictly necessary any more.
 */


#import "CURLMulti.h"

#import "CURLHandle.h"
#import "CURLHandle+MultiSupport.h"
#import "CURLSocket.h"


@interface CURLHandle (Private)
- (void)completeWithError:(NSError *)error;
@end


@interface CURLMulti()

#pragma mark - Private Properties

@property (readonly, copy, nonatomic) NSArray* handles;
@property (assign, nonatomic) CURLM* multiForSocket;
@property (strong, nonatomic) NSMutableArray* sockets;
@property (assign, nonatomic) dispatch_queue_t queue;
@property (assign, nonatomic) dispatch_source_t timer;

@end


#define USE_GLOBAL_QUEUE YES            // turn this on to share one queue across all instances
#define COUNT_INSTANCES NO              // turn this on for a bit of debugging to ensure that things are getting cleaned up properly

#if COUNT_INSTANCES
static NSInteger gInstanceCount = 0;
#endif

NSString *const kActionNames[] =
{
    @"CURL_SOCKET_TIMEOUT",
    @"CURL_CSELECT_IN",
    @"CURL_CSELECT_OUT",
    @"",
    @"CURL_CSELECT_ERR",
};

#pragma mark - Callback Prototypes

static int timeout_callback(CURLM *multi, long timeout_ms, void *userp);
static int socket_callback(CURL *easy, curl_socket_t s, int what, void *userp, void *socketp);


@implementation CURLMulti

#pragma mark - Synthesized Properties

@synthesize sockets = _sockets;
@synthesize queue = _queue;
@synthesize timer = _timer;
@synthesize multiForSocket = _multiForSocket;

#pragma mark - Object Lifecycle

+ (CURLMulti*)sharedInstance;
{
    static CURLMulti* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CURLMulti alloc] init];
        [instance startup];
    });

    return instance;
}

- (id)init
{
    if ((self = [super init]) != nil)
    {
        if ([self createTimer])
        {
            _handles = [[NSMutableArray alloc] init];
            self.sockets = [NSMutableArray array];
#if COUNT_INSTANCES
            ++gInstanceCount;
#endif
        }
        else
        {
            [self release];
            self = nil;
        }
    }

    return self;
}

- (void)dealloc
{
    CURLMultiLog(@"deallocing");
    NSAssert((_multiForSocket == nil) && (_timer == nil) && (_queue == nil), @"should have been shut down by the time we're dealloced");

    [_handles release];
    [_sockets release];

#if COUNT_INSTANCES
    --gInstanceCount;
    CURLMultiLog(@"dealloced: %ld instances remaining", gInstanceCount);
#else
    CURLMultiLog(@"dealloced");
#endif
    
    [super dealloc];
}

#pragma mark - Startup / Shutdown

- (void)startup

{
    CURLMultiLog(@"started");
}


- (void)shutdown
{
    // if the queue is gone, we've already been shut down and are probably being disposed
    dispatch_source_t timer = self.timer;
    if (timer)
    {
        CURLMultiLog(@"shutdown");
        self.timer = nil;
        dispatch_source_cancel(timer);
    }
    else
    {
        CURLMultiLogError(@"shutdown called multiple times");
    }
}

#pragma mark - Easy Handle Management

- (void)manageHandle:(CURLHandle*)handle
{
    NSAssert(self.queue, @"need queue");

    dispatch_async(self.queue, ^{
        [self addHandle:handle];
    });
}

- (void)cancelHandle:(CURLHandle*)handle
{
    NSAssert(self.queue, @"need queue");

    dispatch_async(self.queue, ^{
        
        [self removeHandle:handle];
        
        // Handle completes once any pending work on the queue is performed
        dispatch_async(self.queue, ^{
            [handle completeWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
        });
    });
}

- (CURLHandle*)findHandleWithEasyHandle:(CURL*)easy
{
    CURLHandle* result = nil;
    CURLHandle* info;
    CURLcode code = curl_easy_getinfo(easy, CURLINFO_PRIVATE, &info);
    if (code == CURLE_OK)
    {
        NSAssert([info isKindOfClass:[CURLHandle class]], @"easy handle doesn't seem to be backed by a CURLHandle object");

        result = info;
    }
    else
    {
        NSAssert(NO, @"failed to get backing object for easy handle");
    }

    return result;
}

#pragma mark - Multi Handle Management

- (CURLM*)multiCreate
{
    CURLMcode result = CURLM_OK;
    _multi = curl_multi_init();
    if (_multi)
    {
        result = curl_multi_setopt(_multi, CURLMOPT_TIMERFUNCTION, timeout_callback);
        if (result == CURLM_OK)
        {
            result = curl_multi_setopt(_multi, CURLMOPT_TIMERDATA, self);
        }

        if (result == CURLM_OK)
        {
            result = curl_multi_setopt(_multi, CURLMOPT_SOCKETFUNCTION, socket_callback);
        }

        if (result == CURLM_OK)
        {
            result = curl_multi_setopt(_multi, CURLMOPT_SOCKETDATA, self);
        }

        if (result != CURLM_OK)
        {
            curl_multi_cleanup(_multi);
            _multi = nil;
        }
    }

    return _multi;
}

- (void)cleanupMulti:(CURLM*)multi
{
    CURLMultiLog(@"cleaning up");

    for (CURLHandle *aHandle in self.handles)
    {
        [self removeHandle:aHandle];
    }

    // give handles a last chance to process
    [self multiTimedOut:multi];

    [_handles release]; _handles = nil;
    self.sockets = nil;

    CURLMcode result = curl_multi_cleanup(multi);
    NSAssert(result == CURLM_OK, @"cleaning up multi failed unexpectedly with error %d", result);
}

- (void)multiTimedOut:(CURLM*)multi
{
    [self processMulti:multi action:0 forSocket:CURL_SOCKET_TIMEOUT];
}

- (void)processMulti:(CURLM*)multi action:(int)action forSocket:(int)socket
{
    //BOOL isTimeout = socket == CURL_SOCKET_TIMEOUT;

    // process the multi
    //if (!isTimeout)
    {
        int running;
        CURLMultiLogDetail(@"\n\nSTART processing for socket %d action %@", socket, kActionNames[action]);
        CURLMcode result;
        do
        {
            self.multiForSocket = multi;
            result = curl_multi_socket_action(multi, socket, action, &running);
            self.multiForSocket = nil;
        } while (result == CURLM_CALL_MULTI_SOCKET);

        if (result == CURLM_OK)
        {
            CURLMultiLogDetail(@"%d handles reported as running", running);
            CURLMsg* message;
            int count;
            while ((message = curl_multi_info_read(multi, &count)) != NULL)
            {
                CURLMultiLog(@"got message (%d remaining)", count);
                if (message->msg == CURLMSG_DONE)
                {
                    CURLcode code = message->data.result;
                    CURL* easy = message->easy_handle;
                    CURLHandle* handle = [self findHandleWithEasyHandle:easy];
                    if (handle)
                    {
                        const char* url;
                        curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &url);
                        CURLMultiLog(@"done msg result %d for %@ %s", code, handle, url);
                        [handle retain];

                        // the order is important here - we remove the handle from the multi first...
                        [self removeHandle:handle];

                        // ...then tell the easy handle to complete, which can cause curl_easy_cleanup to be called
                        [handle completeWithCode:code isMulti:NO];

                        // ...then tell it that it's no longer in use by the multi, which breaks the reference cycle between us
                        //[handle removedByMulti:self];

                        [handle autorelease];
                    }
                    else
                    {
                        // this really shouldn't happen - there should always be a matching CURLHandle - but just in case...
                        CURLMultiLogError(@"SOMETHING WRONG: done msg result %d for easy without a matching CURLHandle %p", code, easy);
                        result = curl_multi_remove_handle(multi, message->easy_handle);
                        NSAssert(result == CURLM_OK, @"failed to remove curl easy from curl multi - something odd going on here");
                    }
                }
                else
                {
                    CURLMultiLogError(@"got unexpected multi message %d", message->msg);
                }
            }
        }
        else
        {
            CURLMultiLogError(@"curl_multi_socket_action returned error %d", result);
        }
    }

    CURLMultiLogDetail(@"\nDONE processing for socket %d action %@\n\n", socket, kActionNames[action]);
}

- (NSArray *)handles; { return [[_handles copy] autorelease]; }

- (void)addHandle:(CURLHandle *)handle;
{
    NSAssert(![self.handles containsObject:handle], @"shouldn't add a handle twice");
    
    CURLMcode result = curl_multi_add_handle(_multi, [handle curl]);
    if (result == CURLM_OK)
    {
        CURLMultiLog(@"added handle %@", handle);
        [_handles addObject:handle];
    }
    else
    {
        CURLMultiLogError(@"failed to add handle %@", handle);
        [handle completeWithCode:result isMulti:YES];
    }
}

- (void)removeHandle:(CURLHandle *)handle;
{
    NSAssert([_handles containsObject:handle], @"we should be managing this handle");
    
    CURLMultiLog(@"removed handle %@", handle);
    self.multiForSocket = _multi;
    CURLMcode result = curl_multi_remove_handle(_multi, [handle curl]);
    self.multiForSocket = nil;
    
    NSAssert(result == CURLM_OK, @"failed to remove curl easy from curl multi - something odd going on here");
    [_handles removeObject:handle];
}

- (void)multiUpdateSocket:(CURLSocket*)socket raw:(curl_socket_t)raw what:(NSInteger)what
{
    CURLM* multi = self.multiForSocket;
    NSAssert(multi != nil, @"should never be called without a multi value");
    if (multi)
    {
        if (what == CURL_POLL_NONE)
        {
            NSAssert(socket == nil, @"should have no socket object first time");
        }

        if (!socket)
        {
            NSAssert(what != CURL_POLL_REMOVE, @"shouldn't need to make a socket if we're being asked to remove it");
            socket = [[CURLSocket alloc] init];
            [self.sockets addObject:socket];
            curl_multi_assign(multi, raw, socket);
            CURLMultiLog(@"new socket:%@", socket);
            [socket release];
        }

        [socket updateSourcesForSocket:raw mode:what multi:self];
        CURLMultiLog(@"updated socket:%@", socket);

        if (what == CURL_POLL_REMOVE)
        {
            NSAssert(socket != nil, @"should have socket");
            CURLMultiLog(@"removed socket:%@", socket);
            [self.sockets removeObject:socket];
            curl_multi_assign(multi, raw, nil);
        }
    }
}

#pragma mark - Queue Management

- (dispatch_queue_t)createQueue
{
    dispatch_queue_t queue;

#if USE_GLOBAL_QUEUE

    // make a single queue, stored in a static, which we use for all CURLMulti instances
    static dispatch_queue_t sGlobalQueue;
    static dispatch_once_t sGlobalQueueToken;
    dispatch_once(&sGlobalQueueToken, ^{
        sGlobalQueue = dispatch_queue_create("com.karelia.CURLMulti", NULL);
    });

    queue = sGlobalQueue;
    dispatch_retain(queue);
#else

    // make a new queue for each CURLMulti instance
    NSString* name = [NSString stringWithFormat:@"com.karelia.CURLMulti.%p", self];
    queue = dispatch_queue_create([name UTF8String], NULL);

#endif

    CURLMultiLog(@"created queue");
    return queue;
}


#pragma mark - Timer Management

- (BOOL)createTimer
{
    CURLM* multi = [self multiCreate];
    if (multi)
    {
        dispatch_queue_t queue = [self createQueue];
        if (queue)
        {
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
            _timeoutTimerSuspended = YES;
            // CURLM will command us to resume the timer when it's ready

            dispatch_source_set_event_handler(timer, ^{
                CURLMultiLogDetail(@"timer fired");

                // perform processing
                [self multiTimedOut:multi];
            });

            dispatch_source_set_cancel_handler(timer, ^{

                NSAssert(self.timer == nil, @"timer property should have been cleared by now");

                [self cleanupMulti:multi];

                dispatch_queue_t queue = self.queue;
                dispatch_async(dispatch_get_main_queue(), ^{
                    dispatch_release(timer);
                    dispatch_release(queue);
                    CURLMultiLog(@"released queue and timer");
                });

                self.queue = nil;
            });

            self.timer = timer;
            self.queue = queue;
        }
    }

    return multi && self.timer && self.queue;
}

#pragma mark - Callback Support

- (void)updateTimeout:(NSInteger)timeout
{
    // if multi is nil, the object is being thrown away
    if ([self notShutdown])
    {
        dispatch_source_t timer = self.timer;
        NSAssert(timer != nil, @"should still have a timer");

        CURLMultiLog(@"timeout changed to %ldms", (long)timeout);
        
        if (timer)
        {
            if (timeout < 0)
            {
                if (!_timeoutTimerSuspended)
                {
                    _timeoutTimerSuspended = YES;
                    dispatch_suspend(timer);
                }
            }
            else
            {
                int64_t dispatchTimeout = timeout * NSEC_PER_MSEC;
                
                dispatch_source_set_timer(timer,
                                          dispatch_time(DISPATCH_TIME_NOW, dispatchTimeout),// fire when timeout is reached
                                          DISPATCH_TIME_FOREVER,                            // libcurl takes care of rescheduling
                                          dispatchTimeout/100);                             // we're fairly delay tolerant
                
                if (_timeoutTimerSuspended)
                {
                    _timeoutTimerSuspended = NO;
                    dispatch_resume(timer);
                }
            }
        }
    }
}

- (void)fireTimeoutNow
{
    dispatch_source_t timer = self.timer;
    if (timer)
    {
        [self multiTimedOut:_multi];
    }
}

- (NSString*)nameForType:(dispatch_source_type_t)type
{
    return (type == DISPATCH_SOURCE_TYPE_READ) ? @"reader" : @"writer";
}

- (dispatch_source_t)updateSource:(dispatch_source_t)source type:(dispatch_source_type_t)type socket:(CURLSocket*)socket raw:(int)raw required:(BOOL)required
{
    if (required)
    {
        if (!source)
        {
            CURLMultiLog(@"%@ dispatch source added for socket %d", [self nameForType:type], raw);
            source = dispatch_source_create(type, raw, 0, self.queue);

            CURLM* multi = self.multiForSocket;
            NSAssert(multi != nil, @"should never be called without a multi value");
            int action = (type == DISPATCH_SOURCE_TYPE_READ) ? CURL_CSELECT_IN : CURL_CSELECT_OUT;
            dispatch_source_set_event_handler(source, ^{
                CURLMultiLog(@"%@ dispatch source fired for socket %d with value %ld", [self nameForType:type], raw, dispatch_source_get_data(source));
                BOOL sourceIsActive = [self.sockets containsObject:socket] && [socket ownsSource:source];
                NSAssert(sourceIsActive, @"should have active source");
                if (sourceIsActive)
                {
                    [self processMulti:multi action:action forSocket:raw];
                }
            });

            dispatch_source_set_cancel_handler(source, ^{
                CURLMultiLog(@"%@ removed dispatch source for socket %d", [self nameForType:type], raw);
                dispatch_release(source);
            });

            dispatch_resume(source);
        }
    }
    else if (source)
    {
        CURLMultiLog(@"%@ removing dispatch source for socket %d", [self nameForType:type], raw);
        dispatch_source_cancel(source);
        source = nil;
    }

    return source;
}

#pragma mark - Utilities

- (BOOL)notShutdown
{
    return self.timer != nil;
}

- (NSString*)description
{
    NSString* managing = [self.handles count] ? [NSString stringWithFormat:@": %@", [self.handles componentsJoinedByString:@","]] : @": no handles";
    return [NSString stringWithFormat:@"<MULTI %p%@>", self, managing];
}

#pragma mark - Callbacks


int timeout_callback(CURLM *multi, long timeout_ms, void *userp)
{
    CURLMulti* source = userp;
    [source updateTimeout:timeout_ms];

    return CURLM_OK;
}

int socket_callback(CURL *easy, curl_socket_t s, int what, void *userp, void *socketp)
{
    CURLMulti* multi = userp;
    NSCAssert([multi findHandleWithEasyHandle:easy] != nil, @"socket callback for a handle %p that isn't managed by %@", easy, multi);

    [multi multiUpdateSocket:socketp raw:s what:what];
    
    return CURLM_OK;
}


@end
