#!/bin/sh
# Downloads the prebuilt whisper.cpp XCFramework into JotKit/Frameworks (gitignored, ~250 MB).
# v1.9.5 ships no XCFramework asset, so this pins the newest build that does.
set -eu
TAG="b5454"
cd "$(dirname "$0")/.."
mkdir -p Frameworks
[ -d Frameworks/whisper.xcframework ] && { echo "whisper.xcframework already present"; exit 0; }
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/whisper.zip" "https://github.com/ggml-org/whisper.cpp/releases/download/$TAG/whisper-$TAG-xcframework.zip"
unzip -q "$tmp/whisper.zip" -d "$tmp"
mv "$tmp/build-apple/whisper.xcframework" Frameworks/
rm -rf "$tmp"
echo "whisper.xcframework ($TAG) ready"
