#!/bin/zsh
# Fetches vAmiga at a pinned commit into $VAMIGA_SRC (default /tmp/vamiga), builds its core library and drv.
#   tools/vamiga/build.sh            -> /tmp/vamiga-build/drv
set -e
HERE=${0:A:h}
SRC=${VAMIGA_SRC:-/tmp/vamiga}
BLD=${VAMIGA_BUILD:-/tmp/vamiga-build}
COMMIT=899da5ddd872dfb2e9e35e80247cbb2b36086524
if [ ! -d $SRC/.git ]; then git clone https://github.com/dirkwhoffmann/vAmiga.git $SRC; fi
(cd $SRC && (git cat-file -e $COMMIT 2>/dev/null || git fetch origin $COMMIT) && git checkout -q $COMMIT)
cmake -S $SRC/Core -B $BLD -DCMAKE_BUILD_TYPE=Release > $BLD.cmake.log
cmake --build $BLD -j8 --target VACore > $BLD.build.log
INC=$(grep CXX_INCLUDES $BLD/CMakeFiles/VAHeadless.dir/flags.make | sed 's/CXX_INCLUDES = //')
c++ -O2 -std=c++20 -DNDEBUG -DUSE_ZLIB=1 -D_USE_MATH_DEFINES -Wno-unused-parameter -Wno-gnu-anonymous-struct \
    -Wno-nested-anon-types -Wno-keyword-macro -Wno-unused-result ${=INC} $HERE/drv.cpp -o $BLD/drv \
    $BLD/libVACore.a $BLD/rvlib/librvlib.a $BLD/utlib/libutlib.a $BLD/rvlib/ThirdParty/xdms/libxdms.a \
    -lz -framework CoreMIDI -framework CoreFoundation
echo "built $BLD/drv (ROMs: $SRC/Resources/Assets.xcassets/Binary/aros-20260820-{rom,ext}.dataset)"
