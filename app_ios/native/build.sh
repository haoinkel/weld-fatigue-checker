#!/usr/bin/env bash
# =============================================================
# WeldFatigueChecker · Mac 编译/分发脚本
# 需要：macOS + Xcode 16 + 命令行工具（xcode-select --install）
#
# 用法：
#   ./build.sh open            # 用 Xcode 打开工程（手动签名/运行）
#   ./build.sh sim             # 编译到 iOS 模拟器（验证编译，无需 Apple ID）
#   ./build.sh device TEAM_ID  # 编译到真机（需 Apple Developer Team ID）
#   ./build.sh archive TEAM_ID # 归档 .xcarchive（TestFlight / Ad Hoc 分发）
#   ./build.sh ipa             # 编出【未签名】IPA，留给 Sideloadly 在 Windows 用免费 Apple ID 侧载
#                            （无需 $99 账号、无需自有 Mac；GitHub Actions 免费 Mac 也能跑）
# =============================================================
set -e
cd "$(dirname "$0")"
PROJ=WeldFatigueChecker.xcodeproj
SCHEME=WeldFatigueChecker

# 若 build_occt_ios.sh 已生成 Vendor/OCCT，则自动启用 USE_OCCT=1 并链接 libOCCT.a
OCCT_XCCONFIG=""
if [ -f Vendor/OCCT/lib/libOCCT.a ] && [ -f occt.xcconfig ]; then
  echo "== 检测到 Vendor/OCCT，将启用 USE_OCCT（直读 .step/.iges）=="
  OCCT_XCCONFIG="-xcconfig $(pwd)/occt.xcconfig"
else
  echo "（未检测到 Vendor/OCCT：STEP/IGES 导入将提示“OCCT 未启用”；其余格式仍可用）"
fi

case "$1" in
  open)
    echo "用 Xcode 打开 $PROJ ..."
    open "$PROJ"
    ;;
  sim)
    echo "== 编译到 iOS Simulator（CODE_SIGNING_ALLOWED=NO，仅验证能否编译）=="
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build CODE_SIGNING_ALLOWED=NO $OCCT_XCCONFIG build
    echo "✅ 模拟器编译通过。如要上真机，请用 ./build.sh device <TEAM_ID>"
    ;;
  device)
    TEAM="${2:?用法: ./build.sh device <Apple Developer Team ID>}"
    echo "== 编译到真机 (DEVELOPMENT_TEAM=$TEAM) =="
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' \
      -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" $OCCT_XCCONFIG build
    echo "✅ 真机编译完成"
    ;;
  archive)
    TEAM="${2:?用法: ./build.sh archive <Apple Developer Team ID>}"
    echo "== 归档 (DEVELOPMENT_TEAM=$TEAM) → build/WeldFatigueChecker.xcarchive =="
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' \
      -archivePath build/WeldFatigueChecker.xcarchive \
      DEVELOPMENT_TEAM="$TEAM" $OCCT_XCCONFIG archive
    echo "✅ 归档完成。用 Xcode → Window → Organizer 分发到 TestFlight / Ad Hoc"
    ;;
  ipa)
    echo "== 编出【未签名】IPA（CODE_SIGNING_ALLOWED=NO）→ 供 Sideloadly 侧载 =="
    python3 tools/gen_xcodeproj.py
    rm -rf build
    # 通过 gen_xcodeproj.py 生成显式 .xcscheme，避免 Xcode 26 自动 scheme 的
# "Supported platforms for the buildables ... is empty" 导致 archive 收尾报
# "Archive Missing Bundle Identifier"。
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' \
      -archivePath build/WeldFatigueChecker.xcarchive \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      PRODUCT_BUNDLE_IDENTIFIER=com.yourorg.weldfatiguechecker \
      $OCCT_XCCONFIG archive
    # 将未签名的 .app 打成 IPA（IPA = zip(Payload/App.app)），签名交给 Sideloadly
    rm -rf build/Payload
    mkdir -p build/Payload
    cp -R "build/WeldFatigueChecker.xcarchive/Products/Applications/$SCHEME.app" build/Payload/
    /usr/bin/ditto -c -k --keepParent build/Payload "build/$SCHEME-unsigned.ipa"
    echo "✅ 未签名 IPA 已生成：build/$SCHEME-unsigned.ipa"
    echo "   下一步：把此 IPA 下载到 Windows，用 Sideloadly + 你的免费 Apple ID 签名并安装到 iPad。"
    ;;
  *)
    echo "用法："
    echo "  ./build.sh open            # 用 Xcode 打开工程"
    echo "  ./build.sh sim             # 编译到模拟器（验证编译，无需 Apple ID）"
    echo "  ./build.sh device TEAM_ID  # 编译到真机（需 Apple Developer Team ID）"
    echo "  ./build.sh archive TEAM_ID # 归档 .xcarchive（供 TestFlight/Ad Hoc 分发）"
    echo "  ./build.sh ipa             # 编出未签名 IPA（Sideloadly 免费侧载，无需 $99）"
    echo "  ./build_occt_ios.sh        # 先在本机构建 OCCT 静态库，启用 .step/.iges 直读"
    exit 1
    ;;
esac
