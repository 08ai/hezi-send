#!/bin/bash
# build.sh — 编译 HeziSend.dylib 并打包为 DEB
# 运行环境: macOS + Xcode Command Line Tools
# 用法: bash build.sh

set -e

NAME="HeziSend"
DEB_NAME="hezi-groupsend"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "=== 1. 编译 dylib ==="
clang -arch arm64 -dynamiclib \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -fobjc-arc -lsqlite3 \
    -miphoneos-version-min=14.0 -isysroot "$SDK" \
    -o "${NAME}.dylib" "${NAME}.m"
echo "OK: ${NAME}.dylib"

echo "=== 2. 签名 (可选) ==="
ldid -S "${NAME}.dylib" 2>/dev/null || echo "ldid not found, skipping sign"

echo "=== 3. 构建 DEB 目录结构 ==="
DEB_DIR="deb_build"
rm -rf "$DEB_DIR"
mkdir -p "${DEB_DIR}/DEBIAN"
mkdir -p "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries"

cp control "${DEB_DIR}/DEBIAN/"
cp "${NAME}.dylib" "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries/"
cp "${NAME}.plist" "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries/"

echo "=== 4. 修正权限 ==="
chmod 755 "${DEB_DIR}/DEBIAN"
chmod 644 "${DEB_DIR}/DEBIAN/control"
chmod 755 "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries"
chmod 644 "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries/${NAME}.dylib"
chmod 644 "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries/${NAME}.plist"

echo "=== 5. 打包 DEB ==="
dpkg-deb -b "$DEB_DIR" "${DEB_NAME}.deb"
echo "OK: ${DEB_NAME}.deb ($(wc -c < ${DEB_NAME}.deb) bytes)"

echo ""
echo "=== 安装到手机 ==="
echo "  scp ${DEB_NAME}.deb root@<iphone-ip>:/tmp/"
echo "  ssh root@<iphone-ip> 'dpkg -i /tmp/${DEB_NAME}.deb && killall -9 MomoSceneChat'"
echo ""
echo "=== 卸载 ==="
echo "  ssh root@<iphone-ip> 'dpkg -r com.hezi.groupsend'"
