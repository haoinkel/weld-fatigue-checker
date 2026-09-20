#!/usr/bin/env bash
# =============================================================
# build_occt_ios.sh · 在 Mac 上把 OpenCascade(OCCT) 编成 iOS 静态库
# 目的：让原生 App 能直读 .step / .iges（无需转格式、端侧离线）
#
# 前置：macOS + Xcode 16（含命令行工具 xcode-select --install）+ Homebrew
#   brew install cmake
#
# 产物：
#   Vendor/OCCT/lib/libOCCT.a        # 所有 TK*.a 合并后的单一静态库
#   Vendor/OCCT/include/...          # OCCT 头文件
#   occt.xcconfig                    # 供 build.sh 自动读取的编译开关
#
# 之后运行 ./build.sh sim|device|archive 即可自动启用 USE_OCCT=1 并链接 libOCCT.a
# =============================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

OCCT_VER="8.0.1"
OCCT_TAG="V8_0_1"
OCCT_TARBALL="https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/${OCCT_TAG}.tar.gz"
SRC="$HERE/build/occt-src"
INSTALL="$HERE/build/occt-install"
VENDOR="$HERE/Vendor/OCCT"

echo "== 检查依赖 =="
command -v cmake >/dev/null 2>&1 || { echo "缺少 cmake，请先：brew install cmake"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "缺少 Xcode 命令行工具，请先：xcode-select --install"; exit 1; }

# 已有产物时直接跳过（CI 缓存命中场景）；OCCT_FORCE_BUILD=1 可强制重建
if [ -f "$VENDOR/lib/libOCCT.a" ] && [ -f "$HERE/occt.xcconfig" ] && [ "${OCCT_FORCE_BUILD:-0}" != "1" ]; then
  echo "检测到 Vendor/OCCT/lib/libOCCT.a 已存在，跳过 OCCT 构建（OCCT_FORCE_BUILD=1 可强制重建）"
  exit 0
fi

echo "== 拉取 OCCT ${OCCT_VER} 源码 =="
mkdir -p "$SRC"
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "下载 $OCCT_TARBALL"
  curl -L "$OCCT_TARBALL" -o /tmp/occt.tar.gz
  tar -xzf /tmp/occt.tar.gz -C "$SRC" --strip-components=1
fi

SDK_IPHONE=$(xcrun --sdk iphoneos --show-sdk-path)
SDK_SIM=$(xcrun --sdk iphonesimulator --show-sdk-path)

build_one() {
  local SYSROOT="$1" ARCH="$2" OUT="$3" DEST="$4"
  echo "== 构建 $ARCH @ $SYSROOT =="
  mkdir -p "$OUT"
  cmake -S "$SRC" -B "$OUT" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SYSROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_INSTALL_PREFIX="$DEST" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DINSTALL_DIR="$DEST" \
    -DUSE_FREETYPE=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_QT=OFF -DUSE_D3D=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_MODULE_TKSTEP=ON -DBUILD_MODULE_TKIGES=ON -DBUILD_MODULE_TKMesh=ON \
    -DBUILD_MODULE_TKDraw=OFF -DBUILD_MODULE_TKQADraw=OFF -DBUILD_MODULE_TKTObj=OFF \
    -DBUILD_MODULE_TKTopTest=OFF -DBUILD_MODULE_TKGeomBase=ON -DBUILD_MODULE_TKBRep=ON \
    -DBUILD_MODULE_TKTopAlgo=ON -DBUILD_MODULE_TKGeomAlgo=ON -DBUILD_MODULE_TKMath=ON \
    -DBUILD_MODULE_TKPrim=ON -DBUILD_MODULE_TKBO=ON -DBUILD_MODULE_TKShHealing=ON \
    -DBUILD_MODULE_TKXSBase=ON -DBUILD_MODULE_TKFeat=ON -DBUILD_MODULE_TKOffset=ON \
    -DBUILD_MODULE_TKFillet=ON -DBUILD_MODULE_TKHLR=ON -DBUILD_MODULE_TKG3d=ON \
    -DBUILD_MODULE_TKG2d=ON -DBUILD_MODULE_TKernel=ON
  cmake --build "$OUT" -j "$(sysctl -n hw.ncpu)"
  cmake --install "$OUT"
}

build_one "$SDK_IPHONE" "arm64"               "$HERE/build/occt-iphoneos" "$INSTALL/iphoneos"
# CI 出 IPA 只需真机架构；设 OCCT_SKIP_SIM=1 跳过模拟器构建（省约一半时间）
if [ "${OCCT_SKIP_SIM:-0}" = "1" ]; then
  echo "OCCT_SKIP_SIM=1：跳过模拟器架构（仅构建真机 arm64）"
else
  build_one "$SDK_SIM"    "arm64;x86_64"        "$HERE/build/occt-sim"      "$INSTALL/sim"
fi

echo "== 合并为单一静态库 libOCCT.a =="
mkdir -p "$VENDOR/lib"
LIBS=$(find "$INSTALL" -name "libTK*.a" -type f | tr '\n' ' ')
libtool -static -o "$VENDOR/lib/libOCCT.a" $LIBS
echo "libOCCT.a 大小：$(du -h "$VENDOR/lib/libOCCT.a" | cut -f1)"

echo "== 拷贝头文件 =="
mkdir -p "$VENDOR/include"
cp -R "$SRC/inc/." "$VENDOR/include/" 2>/dev/null || true
[ -d "$INSTALL/iphoneos/inc" ] && cp -R "$INSTALL/iphoneos/inc/." "$VENDOR/include/" 2>/dev/null || true

echo "== 生成 occt.xcconfig =="
cat > "$HERE/occt.xcconfig" <<EOF
// 由 build_occt_ios.sh 自动生成；build.sh 检测到 Vendor/OCCT 后会引用本文件
USE_OCCT=1
HEADER_SEARCH_PATHS = $(inherited) "$VENDOR/include"
LIBRARY_SEARCH_PATHS = $(inherited) "$VENDOR/lib"
OTHER_LDFLAGS = $(inherited) -lOCCT -lc++ -ObjC
GCC_PREPROCESSOR_DEFINITIONS = $(inherited) USE_OCCT=1
EOF

echo "✅ OCCT 构建完成。现在运行 ./build.sh sim（或 device/archive）即可直读 .step/.iges。"
