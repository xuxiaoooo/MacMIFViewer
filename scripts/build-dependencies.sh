#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
mkdir -p .build Vendor
cd .build
export MACOSX_DEPLOYMENT_TARGET=14.0
if ! command -v cmake >/dev/null; then
  python3 -m venv build-tools
  build-tools/bin/pip install cmake==3.31.6
  export PATH="$PWD/build-tools/bin:$PATH"
fi
if [ ! -f "$root/Vendor/lib/libjpeg.a" ]; then
  if [ ! -d libjpeg-turbo-3.1.3 ]; then
    curl -fL --max-time 60 --retry 2 https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/3.1.3 -o jpeg.tar.gz
    echo '3a13a5ba767dc8264bc40b185e41368a80d5d5f945944d1dbaa4b2fb0099f4e5  jpeg.tar.gz' | shasum -a 256 -c
    tar -xzf jpeg.tar.gz
  fi
  cmake -S libjpeg-turbo-3.1.3 -B jpeg-build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    "-DCMAKE_C_FLAGS=-ffile-prefix-map=\"$root\"=." \
    -DCMAKE_INSTALL_PREFIX="$root/Vendor" -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF
  cmake --build jpeg-build --parallel 6
  cmake --install jpeg-build
fi
if [ ! -f "$root/Vendor/lib/libtiff.a" ]; then
  if [ ! -f tiff-4.7.2.tar.gz ]; then
    curl -fL --retry 2 https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz -o tiff-4.7.2.tar.gz
  fi
  echo '672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a  tiff-4.7.2.tar.gz' | shasum -a 256 -c
  tar -xzf tiff-4.7.2.tar.gz
  cmake --fresh -S tiff-4.7.2 -B tiff-build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    "-DCMAKE_C_FLAGS=-ffile-prefix-map=\"$root\"=." \
    -DCMAKE_INSTALL_PREFIX="$root/Vendor" -DCMAKE_PREFIX_PATH="$root/Vendor" \
    -Djpeg-prefer-standard=ON -DJPEG_INCLUDE_DIR="$root/Vendor/include" -DJPEG_LIBRARY_RELEASE="$root/Vendor/lib/libjpeg.a" \
    -DBUILD_SHARED_LIBS=OFF -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
    -Djbig=OFF -Dlibdeflate=OFF -Dlzma=OFF -Dwebp=OFF -Dzstd=OFF -Dlerc=OFF -Djpeg12=OFF
  cmake --build tiff-build --parallel 6
  cmake --install tiff-build
fi
