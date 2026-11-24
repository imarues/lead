#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos --find clang)"
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1
export CGO_CFLAGS="-arch arm64 -isysroot $sdk -miphoneos-version-min=14.0"
export CGO_LDFLAGS="$CGO_CFLAGS"
mkdir -p build
go build -mod=mod -trimpath -buildmode=c-archive -o build/libLeadWarp.a .
echo "$here/build/libLeadWarp.a"
