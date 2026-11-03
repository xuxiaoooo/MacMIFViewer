#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f Vendor/lib/libtiff.a ]; then scripts/build-dependencies.sh; fi
mkdir -p .build
root=$(mktemp -d .build/test.XXXXXX)
trap 'rm -rf "$root"' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -O2 \
  -I Vendor/include -c ViewerApp/Native/TiffBridge.c -o "$root/TiffBridge.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk" -O -parse-as-library \
  -import-objc-header ViewerApp/Native/TiffBridge.h ViewerApp/Core/*.swift tests/ReaderRegression.swift \
  "$root/TiffBridge.o" Vendor/lib/libtiff.a Vendor/lib/libjpeg.a -lz -o "$root/regression"
.venv/bin/python tests/tiff_fixtures.py create "$root"
if [ "$#" -gt 0 ]; then
  .venv/bin/python tests/compare_native_mrxs.py "$root" "$1"
else
  "$root/regression" "$root"
fi
.venv/bin/python tests/tiff_fixtures.py verify "$root"
.venv/bin/python -m unittest discover -s tools/mrxs_probe/tests -v
