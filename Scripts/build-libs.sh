build() {

	echo "Building $1"

	obj="$HOME/Library/Caches/CurlHandle/obj"
	sym="$HOME/Library/Caches/CurlHandle/sym"
	xcodebuild -project $1.xcodeproj -target $2 -configuration Debug OBJROOT="$obj" SYMROOT="$sym" > /tmp/build.log 
	res=$?

	if [ $res -ne 0 ];
	then
		cat /tmp/build.log
		echo "$1 build failed"
		exit $res
	fi

}

# remove old versions
rm -rf CURLHandleSource/built

# build SFTP libraries too?

if [ "$1" == "--curl-only" ];
then
    echo "Skipping SFTP libraries"
else
    cd SFTP
    build OpenSSL openssl
    build libssh2 libssh2
    cd ..
fi

# build libcurl and libcares
cd CURLHandleSource
build CURLHandle libcurl

echo "Done"
open "built"