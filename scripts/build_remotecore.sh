#!/bin/bash
set -euo pipefail

# Build RemoteCore (VNC/RDP, Rust) as RemoteCoreFFI.xcframework for the Mac and
# iOS apps. Package.swift links it when RemoteCore/build/RemoteCoreFFI.xcframework
# exists; without it the apps build with VNC/RDP turned off.
cd "$(dirname "$0")/../RemoteCore"
export MACOSX_DEPLOYMENT_TARGET="${MACVIEWER_MIN_MACOS:-11}.0"
export IPHONEOS_DEPLOYMENT_TARGET=16.0

targets=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
rustup target add "${targets[@]}"
for target in "${targets[@]}"; do
  cargo build --locked --release --lib --target "$target"
done

out=build
rm -rf "$out"
mkdir -p "$out/macos" "$out/ios-sim" "$out/headers"
lib=libremotecore.a
lipo -create target/aarch64-apple-darwin/release/$lib target/x86_64-apple-darwin/release/$lib -output "$out/macos/$lib"
lipo -create target/aarch64-apple-ios-sim/release/$lib target/x86_64-apple-ios/release/$lib -output "$out/ios-sim/$lib"
cp include/remotecore.h include/module.modulemap "$out/headers/"
xcodebuild -create-xcframework \
  -library "$out/macos/$lib" -headers "$out/headers" \
  -library target/aarch64-apple-ios/release/$lib -headers "$out/headers" \
  -library "$out/ios-sim/$lib" -headers "$out/headers" \
  -output "$out/RemoteCoreFFI.xcframework"
echo "Built $PWD/$out/RemoteCoreFFI.xcframework"
