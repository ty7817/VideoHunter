#!/bin/bash
#
# 在 macOS 上本地打包一个未签名 IPA。
# 用法：bash scripts/build-ipa.sh [输出目录]
#

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-build}"
BUILD_DIR="$(mktemp -d)/build"

echo "==> 编译 Release"
xcodebuild \
  -project VideoHunter.xcodeproj \
  -target VideoHunter \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$BUILD_DIR/Build/Products/Release-iphoneos/VideoHunter.app"

if [ ! -d "$APP" ]; then
  echo "编译产物不存在：$APP"
  exit 1
fi

echo "==> 打包"
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/Payload" "$OUT_DIR/VideoHunter-unsigned.ipa"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/Payload/"
( cd "$OUT_DIR" && zip -qry VideoHunter-unsigned.ipa Payload )

echo "==> 完成：$OUT_DIR/VideoHunter-unsigned.ipa"
