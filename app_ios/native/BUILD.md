# WeldFatigueChecker · 在 Mac 上编译与分发

> 本工程**不含**已编译的 `.ipa`。iOS App 必须在 macOS + Xcode 中构建（Windows 无法交叉编译 iOS 目标）。
> 下面的 `WeldFatigueChecker.xcodeproj` 已生成，可直接在 Xcode 16 打开。

## 前置条件
- 一台 Mac（Apple Silicon 或 Intel 均可），装 **Xcode 16**。
- 命令行工具：`xcode-select --install`。
- 真机/TestFlight 分发需要 **Apple Developer 账号**（免费账号可跑模拟器与真机调试；上架/TestFlight 需付费）。

## 快速验证（无需 Apple 账号）
```bash
cd app_ios/native
./build.sh sim
```
`sim` 模式把工程编译到 iOS 模拟器（`CODE_SIGNING_ALLOWED=NO`），**目的只是确认所有 Swift 源码能编译通过**。
这一步能抓出绝大多数代码/接口层面的错误。注意：模拟器里 ARKit `sceneDepth`（LiDAR）不可用，需在真机验证自动识别。

## 上真机 / 分发
```bash
./build.sh device  <你的 Team ID>        # 编译到已连接的 iPad
./build.sh archive <你的 Team ID>         # 归档 .xcarchive
```
- Team ID 在 [developer.apple.com](https://developer.apple.com) → 账号 → Membership 里查（形如 `ABCDE12345`）。
- 归档后在 Xcode → **Window → Organizer** 里选 `WeldFatigueChecker.xcarchive` → **Distribute App** → TestFlight / Ad Hoc / 企业签。
- 目标设备选 **iPad Pro 11″ (M5, LiDAR)**，部署目标 iPadOS 18。

## 在 Xcode 里手动操作（图形界面）
1. 双击 `WeldFatigueChecker.xcodeproj` 打开。
2. 选 TARGET → **Signing & Capabilities** → 选你的 Team（自动签名）。
3. 顶部设备选 **iPad Pro (LiDAR)** 或连上的真机 → ⌘R 运行。
4. 归档：菜单 **Product → Archive**。

## 工程要点
- 所有 Swift 源已加入编译；`Resources/` 作为**文件夹引用**整体拷贝进 App 包，
  因此 `Resources/packs/*.pack.json`（EN 1993-1-9、ISO 5817 标准包）会随 .ipa 离线可用。
- 系统框架（SwiftUI / ARKit / AVFoundation / CoreVideo / PDFKit / PhotosUI / SceneKit / ModelIO）由 Swift 自动链接，无需手动加。
- `Info.plist` 已配置相机/相册/LiDAR 权限说明、`UIDeviceFamily=1,2`、最低系统 18.0。
- 占位 `PRODUCT_BUNDLE_IDENTIFIER = com.yourorg.weldfatiguechecker`，发布前请改成你自己的反向域名。

## 启用 .step / .iges 直读（OpenCascade / OCCT）
原生 App 的「3D 模型」标签页支持 `.obj/.stl/.ply/.usdz/.glb/.gltf`（Model I/O 原生读取，无需额外库），
以及 `.step/.iges`（需把 OpenCascade 编成 iOS 静态库）。

> iOS 原生**不**直接支持 STEP/IGES，必须靠 OCCT。下面一步在本机构建好 `Vendor/OCCT`，
> 之后 `./build.sh` 会自动探测并开启 `USE_OCCT=1` 链接 `libOCCT.a`。

```bash
# 在 Mac 上（前置：brew install cmake；Xcode 16 命令行工具）
./build_occt_ios.sh          # 下载 OCCT 7.8.1 → 编 arm64(设备)+arm64/x86_64(模拟器) → 合并 libOCCT.a
./build.sh sim               # 现在编译会带上 OCCT，.step/.iges 可直读
```
- `build_occt_ios.sh` 产物：`Vendor/OCCT/lib/libOCCT.a`、`Vendor/OCCT/include/`、`occt.xcconfig`。
- 未运行该脚本时，应用仍可编译运行，但导入 `.step/.iges` 会在界面提示「OCCT 未启用」（其余格式不受影响）。
- OCCT 构建较耗时（首次约 20–60 分钟，取决于机型）；若链接报缺少某 TK 模块，可在脚本里按需增开 `BUILD_MODULE_TK*`。

## 已知限制（运行时再确认）
- LiDAR 自动识别依赖真机 depth 数据，模拟器无法验证；请在 iPad Pro 2025 M5 真机实测。
- `.step/.iges` 直读需在 Mac 先跑 `build_occt_ios.sh`；模拟器若仅 arm64 也能跑 OCCT（脚本已编 arm64 模拟器库）。
- 未生成 App 图标资源目录，构建会有"无图标"警告（不影响编译/运行），需要时可补 `Assets.xcassets`。
- 模型单位假设为 mm：包围盒「填入设计表单」按 mm 计算；若模型单位为 m，请自行除以 1000。
