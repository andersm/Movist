#/bin/bash
set -e

if [ -z "$MACOSX_DEPLOYMENT_TARGET" ]
then
    echo MACOSX_DEPLOYMENT_TARGET not set
    exit 1
fi

CONTRIB_DIR=`pwd`
BUILD_DIR="$CONTRIB_DIR/build"

GIT_PREFIX=`git rev-parse --show-prefix`
LIBAV_HEAD=`git rev-parse --revs-only --prefix $GIT_PREFIX @:./libav`
if [ $? -ne 0 ] || [ ! -e "libav/configure" ]; then
    echo "The git submodules necessary for building libav are missing."
    exit 1
fi

LIBAV_STAMP=""
[ -e "$BUILD_DIR/libav.stamp" ] && LIBAV_STAMP=$(<"$BUILD_DIR/libav.stamp")
if [ $? -eq 0 ] && [ "$LIBAV_HEAD" == "$LIBAV_STAMP" ]; then
    exit 0
fi

ORIGINAL_PATH="$PATH"

build_libav()
{
(cd libav && \
./configure \
--arch=$THEARC \
--cpu=$THECPU \
--cc=clang \
--enable-decoders \
--disable-vda \
--disable-encoders \
--enable-demuxers \
--disable-muxers \
--enable-parsers \
--disable-avdevice \
--disable-network \
--enable-pthreads \
--enable-gpl \
--disable-programs \
--extra-ldflags="-L$PREFIX/../lib -arch $THEARC -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
--extra-cflags="-isystem $PREFIX/../include -arch $THEARC -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wno-deprecated-declarations $THEOPT " \
--enable-protocol=file \
--prefix=$PREFIX \
&& make clean && make && make install-libs && make install-headers)
}

########## INTEL x86_64 ###########

PREFIX="$(cd build;pwd)/x86_64"
PATH="$(cd build;pwd)/bin:$PREFIX/bin:$ORIGINAL_PATH"
THEARC="x86_64"
THECPU="core2"
THEOPT="-mtune=core2"
export PATH

pushd .
build_libav
popd .

## Relocate headers and lib

cp -R $PREFIX/include/* $PREFIX/../include
cp $PREFIX/lib/*.a "$BUILD_DIR/lib/"

echo `git rev-parse --revs-only --prefix $GIT_PREFIX @:./libav` > "$BUILD_DIR/libav.stamp"
