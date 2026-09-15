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
  echo "（未检测到 Vendor/OCCT：STEP/IGES 导入将提示"OCCT 未启用"；其余格式仍可用）"
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
    # 注意：Xcode 26 的 `xcodebuild archive` 在未签名场景下，收尾的归档校验会读
    # 一次 bundle id 元数据并报 "Archive Missing Bundle Identifier"（即使 Info.plist
    # 里 CFBundleIdentifier 已正确展开）。改用 `build` 直接产出 .app，再手动 zip
    # 成 IPA，彻底绕过 archive 的归档校验；签名交给 Sideloadly 完成。
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' \
      -derivedDataPath build/dd \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      PRODUCT_BUNDLE_IDENTIFIER=com.yourorg.weldfatiguechecker \
      $OCCT_XCCONFIG build
    # 自动定位 .app（Xcode 26 + generic/platform=iOS 产物路径不固定，不硬编码）
    APP_PATH=$(find build/dd -name "$SCHEME.app" -type d | head -n 1)
    if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
      echo "❌ 未找到构建产物 $SCHEME.app"
      echo "   请检查上面的 xcodebuild 输出是否有编译错误。"
      exit 1
    fi
    echo "== 找到 .app: $APP_PATH =="
    du -sh "$APP_PATH"
    rm -rf build/Payload
    mkdir -p build/Payload
    cp -R "$APP_PATH" build/Payload/
    # ⚠️ 不做 ad-hoc 预签名！Xcode 26 的 codesign --sign - 会产 "Info.plist=not bound"
    # 的签名，导致 Sideloadly 重签后 iOS installd 报 IXErrorDomain Code=13 "Missing bundle ID"
    # （Apple Developer Forums 同款案例已确认）。构建侧改 codesign 无法修复，根因在
    # Xcode 26 签名 + 侧载工具重签的兼容性。
    # 因此产出【完全未签名】的干净 IPA，交给 AltStore（或更新后的 Sideloadly）从头完整签名。
    # Xcode 26 的 `build`(CODE_SIGNING_ALLOWED=NO) 仍可能留下 linker 占位签名，先剥离确保纯净：
    /usr/bin/codesign --remove-signature "build/Payload/$SCHEME.app" 2>/dev/null || true
    # 标准未签名 IPA：zip 保留符号链接（-y），结构为 Payload/App.app/...
    cd build
    /usr/bin/zip -r -y -q "$SCHEME-unsigned.ipa" Payload
    cd ..
    echo "== IPA 内容校验（前 20 行）=="
    /usr/bin/unzip -l "build/$SCHEME-unsigned.ipa" | head -n 20
    ls -lh "build/$SCHEME-unsigned.ipa"
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
