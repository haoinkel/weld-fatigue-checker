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
# OCCT 8.x 的 iOS 交叉编译必须用 ios-cmake 工具链（否则 CMAKE_SYSTEM_NAME=iOS 不注入 -framework Foundation，
# 会导致 TKService 链接报 NSAutoreleasePool 未定义，并退化成 macOS 主机构建）
# ios-cmake 是 GitHub 单文件项目（Homebrew 无此 formula），直接下载固定版本
IOS_CMAKE_VER="4.6.0"
TOOLCHAIN="$HERE/build/ios.toolchain.cmake"
if [ ! -f "$TOOLCHAIN" ]; then
  echo "下载 ios-cmake ${IOS_CMAKE_VER} 工具链 ..."
  mkdir -p "$(dirname "$TOOLCHAIN")"
  curl -fL "https://raw.githubusercontent.com/leetal/ios-cmake/${IOS_CMAKE_VER}/ios.toolchain.cmake" -o "$TOOLCHAIN"
fi
grep -q "ios-cmake" "$TOOLCHAIN" 2>/dev/null || { echo "工具链文件无效，请检查下载"; exit 1; }
echo "使用 iOS 工具链: $TOOLCHAIN"

# 已有产物时直接跳过（CI 缓存命中场景）；OCCT_FORCE_BUILD=1 可强制重建
if [ -f "$VENDOR/lib/libOCCT.a" ] && [ -f "$HERE/occt.xcconfig" ] && [ "${OCCT_FORCE_BUILD:-0}" != "1" ]; then
  echo "检测到 Vendor/OCCT/lib/libOCCT.a 已存在，跳过 OCCT 构建（OCCT_FORCE_BUILD=1 可强制重建）"
  if [ ! -f "$VENDOR/include/TopoDS_Shape.hxx" ]; then
    echo "错误：缓存的 Vendor/OCCT 缺少头文件，请升级 CI 缓存 key 或设 OCCT_FORCE_BUILD=1 重建"; exit 1
  fi
  exit 0
fi

echo "== 拉取 OCCT ${OCCT_VER} 源码 =="
mkdir -p "$SRC"
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "下载 $OCCT_TARBALL"
  curl -L "$OCCT_TARBALL" -o /tmp/occt.tar.gz
  tar -xzf /tmp/occt.tar.gz -C "$SRC" --strip-components=1
fi

build_one() {
  local PLAT="$1" OUT="$2" DEST="$3"
  echo "== 构建 iOS($PLAT) @ $OUT =="
  mkdir -p "$OUT"
  cmake -S "$SRC" -B "$OUT" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DPLATFORM="$PLAT" \
    -DENABLE_BITCODE=OFF -DENABLE_ARC=ON -DENABLE_VISIBILITY=OFF \
    -DCMAKE_INSTALL_PREFIX="$DEST" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LIBRARY_TYPE=Static \
    -DINSTALL_DIR="$DEST" \
    -DUSE_FREETYPE=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_QT=OFF -DUSE_D3D=OFF \
    -DUSE_TCL=OFF -DUSE_TK=OFF \
    -DBUILD_TESTING=OFF -DBUILD_MODULE_Draw=OFF \
    -DBUILD_MODULE_Visualization=OFF
  cmake --build "$OUT" -j "$(sysctl -n hw.ncpu)"
  cmake --install "$OUT"
}

# CI 出 IPA 只需真机架构（OS64 = device arm64）；设 OCCT_SKIP_SIM=1 跳过模拟器（省约一半时间）
build_one "OS64" "$HERE/build/occt-iphoneos" "$INSTALL/iphoneos"
if [ "${OCCT_SKIP_SIM:-0}" = "1" ]; then
  echo "OCCT_SKIP_SIM=1：跳过模拟器架构（仅构建真机 arm64）"
else
  build_one "SIMULATORARM64" "$HERE/build/occt-sim" "$INSTALL/sim"
fi

echo "== 合并为单一静态库 libOCCT.a =="
mkdir -p "$VENDOR/lib"
LIBS=$(find "$INSTALL" -name "libTK*.a" -type f | tr '\n' ' ')
libtool -static -o "$VENDOR/lib/libOCCT.a" $LIBS
echo "libOCCT.a 大小：$(du -h "$VENDOR/lib/libOCCT.a" | cut -f1)"

echo "== 拷贝头文件 =="
# OCCT 8.0 CMake 安装头文件到 <install>/iphoneos/include/opencascade/（不是 inc/）
mkdir -p "$VENDOR/include"
if [ -d "$INSTALL/iphoneos/include/opencascade" ]; then
  cp -R "$INSTALL/iphoneos/include/opencascade/." "$VENDOR/include/"
elif [ -d "$INSTALL/iphoneos/inc" ]; then
  cp -R "$INSTALL/iphoneos/inc/." "$VENDOR/include/"
elif [ -d "$SRC/inc" ] && [ -f "$SRC/inc/TopoDS_Shape.hxx" ]; then
  cp -R "$SRC/inc/." "$VENDOR/include/"
fi
# 头文件校验：缺失即快速失败，避免 App 构建阶段才暴露
if [ ! -f "$VENDOR/include/TopoDS_Shape.hxx" ]; then
  echo "错误：OCCT 头文件未拷贝成功（TopoDS_Shape.hxx 缺失），请检查安装目录布局"; exit 1
fi
echo "头文件数量：$(find "$VENDOR/include" -name '*.hxx' | wc -l | tr -d ' ')"

echo "== 生成 occt.xcconfig =="
cat > "$HERE/occt.xcconfig" <<EOF
// 由 build_occt_ios.sh 自动生成；build.sh 检测到 Vendor/OCCT 后会引用本文件
USE_OCCT=1
// OCCT 8.0 头文件用到 std::optional/in_place_t/void_t，必须 C++17（Xcode 默认 gnu++14 会报 no type named 'in_place_t'）
CLANG_CXX_LANGUAGE_STANDARD = gnu++17
CLANG_CXX_LIBRARY = libc++
HEADER_SEARCH_PATHS = $(inherited) "$VENDOR/include"
LIBRARY_SEARCH_PATHS = $(inherited) "$VENDOR/lib"
// -force_load 关键：OCCT 的 STEP/IGES 读取器靠 C++ 静态初始化器向工厂注册，
// 链接器会死代码剥离这些"无显式引用"的注册对象，导致运行时 ReadFile 找不到模式。
// -ObjC 只对 ObjC 分类生效，对 C++ 静态库无效，必须用 -force_load 整体编入。
OTHER_LDFLAGS = $(inherited) -lc++ -ObjC -force_load "$VENDOR/lib/libOCCT.a"
GCC_PREPROCESSOR_DEFINITIONS = $(inherited) USE_OCCT=1
EOF

echo "✅ OCCT 构建完成。现在运行 ./build.sh sim（或 device/archive）即可直读 .step/.iges。"
