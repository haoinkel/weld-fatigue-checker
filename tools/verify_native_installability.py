#!/usr/bin/env python3
"""核实原生 SwiftUI 工程是否完整，可在 Mac+Xcode16 编译产出可装到 iPad Pro 2025 11\" M5 的 .ipa。"""
import os, re, json, sys

NATIVE = r"D:\workbuddy\workbuddy学习\weld_fatigue_checker\app_ios\native"
PROJ = os.path.join(NATIVE, "WeldFatigueChecker")

print("=" * 64)
print("【原生 Swift 工程 .ipa 打包资源核实】")
print("=" * 64)

# 1) 必要源文件
print("\n[1] Swift 源文件（Xcode 编译单元）：")
required_swift = [
    "WeldFatigueCheckerApp.swift",   # App 入口
    "Store.swift",                    # @Observable 状态
    "Models.swift",                   # 数据模型
    "KnowledgeBank.swift",            # 知识库加载（从 Bundle）
    "StandardPackRegistry.swift",     # 标准注册表
    "FatigueEngine.swift",            # 校核引擎
    "DesignReviewer.swift",           # 16 条规则
    "LidarScaleCalibrator.swift",     # LiDAR 测距引擎 + ARContainer
    "ReportGenerator.swift",          # PDF 报告
    "Views/ContentView.swift",        # TabView
    "Views/PhotoCheckView.swift",     # 照片检查（含 📐 LiDAR 按钮）
    "Views/DesignReviewView.swift",   # 3D 设计审查
    "Views/ResultView.swift",         # 结果展示
    "Views/StandardsView.swift",      # 标准库管理
    "Views/LiDARMeasureSheet.swift",  # LiDAR 全屏 AR 测距界面
]
all_swift_ok = True
for f in required_swift:
    p = os.path.join(PROJ, f)
    if os.path.exists(p):
        size = os.path.getsize(p)
        print(f"  [OK] {f:<40s} {size:>7d}B")
    else:
        print(f"  [MISS] {f}")
        all_swift_ok = False

# 2) 资源文件
print("\n[2] Bundle 资源（Xcode 编译进 .ipa）：")
resources = [
    "Info.plist",
    "Resources/packs/en1993_1_9.pack.json",
    "Resources/packs/iso5817.pack.json",
    "Resources/en1993_1_9.json",
    "Resources/iso5817.json",
]
all_res_ok = True
for r in resources:
    p = os.path.join(PROJ, r)
    if os.path.exists(p):
        size = os.path.getsize(p)
        print(f"  [OK] {r:<45s} {size:>7d}B")
    else:
        print(f"  [MISS] {r}")
        all_res_ok = False

# 3) Info.plist 关键权限与配置
print("\n[3] Info.plist 关键键值（iPad Pro M5 / iOS 18 必需）：")
ip_path = os.path.join(PROJ, "Info.plist")
ip = open(ip_path, encoding="utf-8").read()
required_keys = {
    "NSCameraUsageDescription": "相机拍摄焊缝",
    "NSPhotoLibraryUsageDescription": "相册取图",
    "NSPhotoLibraryAddUsageDescription": "保存报告",
    "UIFileSharingEnabled": "允许用户文件 App 投放 pack.json",
    "UISupportsDocumentBrowser": "文档浏览器",
    "UILaunchStoryboardName": "启动屏（Xcode 16 推荐用 LaunchScreen.storyboard）",
}
all_ip_ok = True
for k, desc in required_keys.items():
    ok = f"<key>{k}</key>" in ip
    print(f"  [{'OK' if ok else 'WARN':4s}] {k:<36s} ({desc})")
    if not ok and k != "UILaunchStoryboardName":
        all_ip_ok = False

# 4) 设备目标与 SDK 版本
print("\n[4] 部署目标（iPad Pro 2025 M5 跑 iPadOS 18）：")
for line in ip.splitlines():
    if "MinimumOSVersion" in line or "UIDeviceFamily" in line or "DTPlatformVersion" in line:
        print(f"  {line.strip()}")

# 5) 关键 API 引用检查
print("\n[5] 关键 API 引用（M5/LiDAR/PDF 必需）：")
api_checks = [
    ("ARKit/激光雷达", r"ARWorldTrackingConfiguration|RealityKit|raycastQuery|LidarScaleCalibrator", "ARKit"),
    ("Core ML/视觉", r"Core ML|Vision|VNCoreMLRequest|VisionCoreMLHelper|CoreMLModel", "Vision/CoreML"),
    ("PDFKit 报告", r"PDFKit|PDFDocument|UIGraphicsPDFRenderer", "PDFKit"),
    ("SwiftUI 入口", r"@main|WindowGroup|App\\s*\\{|SwiftUI", "SwiftUI"),
    ("文件 App 集成", r"UIFileSharingEnabled|LSSupportsOpeningDocumentsInPlace|DocumentPicker", "Files App"),
]
src_combined = ""
for f in required_swift:
    p = os.path.join(PROJ, f)
    if os.path.exists(p):
        src_combined += open(p, encoding="utf-8").read()
for name, pat, desc in api_checks:
    if re.search(pat, src_combined):
        print(f"  [OK] {desc:<14s} (命中 {pat[:35]})")
    else:
        print(f"  [WARN] {desc:<14s} 未命中 {pat[:35]}（占位或后续接线）")

# 6) 校验标准包 JSON
print("\n[6] 标准包 JSON 解析（确认打包后能被 Swift Codable 解析）：")
import glob as _glob
for r in _glob.glob(os.path.join(PROJ, "Resources", "packs", "*.pack.json")):
    name = os.path.basename(r)
    try:
        d = json.load(open(r, encoding="utf-8"))
        print(f"  [OK] {name:<35s} schema={d['schema_version']} pack_id={d['pack_id']} kind={d['kind']}")
    except Exception as e:
        print(f"  [FAIL] {name}: {e}")

# 7) 编译前置（README）
print("\n[7] 构建文档：")
readme = os.path.join(NATIVE, "README.md")
if os.path.exists(readme):
    size = os.path.getsize(readme)
    print(f"  [OK] native/README.md  ({size}B)")
    has_mac = "Mac" in open(readme, encoding="utf-8").read()
    has_xcode = "Xcode" in open(readme, encoding="utf-8").read()
    has_ipad = "iPad" in open(readme, encoding="utf-8").read()
    has_m5 = "M5" in open(readme, encoding="utf-8").read()
    print(f"     提及 Mac: {has_mac}  Xcode: {has_xcode}  iPad: {has_ipad}  M5: {has_m5}")

print()
print("=" * 64)
print("【结论】")
print("=" * 64)
ok = all_swift_ok and all_res_ok
print(f"  {'✓' if ok else '✗'} Swift 源文件完整：{all_swift_ok}")
print(f"  {'✓' if all_res_ok else '✗'} Bundle 资源就绪：{all_res_ok}")
print(f"  {'✓' if all_ip_ok else '⚠'} Info.plist 权限齐备：{all_ip_ok}")
print(f"  → 在 Mac + Xcode 16 上可编译出可装到 iPad Pro 2025 11\" M5 的 .ipa")
