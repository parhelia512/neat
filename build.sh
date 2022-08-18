#!/usr/bin/env bash
# kdevelop build mode
if [ ! -z "${BUILD+x}" ]
then
    FAST=1
    # no log spam
    set -euo pipefail
else
    set -euxo pipefail
fi
OPTFLAG="-O"
#OPTFLAG=""

JFLAG=""
if [ \! -z ${FAST+x} ]
then
    OPTFLAG=""
    JFLAG="-j8"
fi

LLVM_CONFIG="/usr/lib/llvm/14/bin/llvm-config"
FLAGS="$JFLAG -I$($LLVM_CONFIG --includedir) -L-L$($LLVM_CONFIG --libdir)"

TAG=v0.1.7
NEAT=.cache/bootstrap/"$TAG"/neat-"$TAG"-gcc/neat

if [ ! -f "$NEAT" ]
then
    echo "Downloading bootstrap compiler $TAG..."
    TARGET=.cache/bootstrap/"$TAG"
    rm -rf "$TARGET"
    mkdir -p "$TARGET"
    pushd "$TARGET"
    FILE=neat-"$TAG"-gcc.zip
    curl -L https://github.com/Neat-Lang/neat/releases/download/"$TAG"/"$FILE" --output "$FILE"
    unzip "$FILE"
    cd neat-"$TAG"-gcc
    echo "Building bootstrap compiler $TAG..."
    ./build.sh
    popd
fi

mkdir -p build

echo "Building stage 1..."
FLAGS="$FLAGS -version=LLVMBackend"
$NEAT $FLAGS -backend=c -macro-backend=c -Pcompiler:src src/main.nt -o build/neat_stage1
NEAT=build/neat_stage1

echo "Building stage 2..."
$NEAT $FLAGS $OPTFLAG -backend=llvm -macro-backend=c -Pcompiler:src src/main.nt -o build/neat_stage2
NEAT=build/neat_stage2

cp $NEAT build/neat
rm build/neat_stage*

cat <<EOF > build/neat.ini
-syspackage compiler:src
-running-compiler-version=$TAG
EOF

# store compiler source next to compiler
rm -rf build/src
cp -R src build/
