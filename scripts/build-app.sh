#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f Vendor/lib/libtiff.a ]; then scripts/build-dependencies.sh; fi
mkdir -p .build dist
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -O2 \
  -I Vendor/include -c ViewerApp/Native/TiffBridge.c -o .build/TiffBridge.o
sources=()
while IFS= read -r -d '' path; do sources+=("$path"); done < <(find ViewerApp -name '*.swift' -print0)
stage=$(mktemp -d .build/package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Mac MIF Viewer.app"
mkdir -p "$app/Contents/"{MacOS,Resources}
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk" -Osize -whole-module-optimization -parse-as-library \
  -Xlinker -dead_strip \
  -import-objc-header ViewerApp/Native/TiffBridge.h "${sources[@]}" .build/TiffBridge.o \
  Vendor/lib/libtiff.a Vendor/lib/libjpeg.a -lz -o "$app/Contents/MacOS/MacMIFViewer"
cp ViewerApp/Resources/Info.plist "$app/Contents/"
cp ViewerApp/Resources/Composite.metal "$app/Contents/Resources/"
xcrun swift scripts/make-icon.swift "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp .build/tiff-4.7.2/LICENSE.md "$app/Contents/Resources/libtiff-LICENSE.md"
cp .build/libjpeg-turbo-3.1.3/LICENSE.md "$app/Contents/Resources/libjpeg-turbo-LICENSE.md"
cp .build/libjpeg-turbo-3.1.3/README.ijg "$app/Contents/Resources/libjpeg-README.ijg"
xcrun strip -x "$app/Contents/MacOS/MacMIFViewer"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto "$app" "dist/Mac MIF Viewer.app"
printf 'Built %s/dist/Mac MIF Viewer.app\n' "$PWD"
