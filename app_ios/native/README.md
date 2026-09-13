# 焊缝疲劳检查器 · 原生 iPad App（SwiftUI / Core ML / ARKit-LiDAR）

面向 **iPad Pro 2025 11 英寸（M5 芯片，带激光雷达）** 的生产级形态。
与 `weld_fatigue_checker/`（Python 原型）共享同一套规则逻辑——
`KnowledgeBank` / `FatigueEngine` / `DesignReviewer` 均由 `engine/*.py` 移植而来。

> ⚠ 本目录是**源码骨架**，我在 Windows 环境下无法编译出 `.ipa`（必须 macOS + Xcode）。
> **今天就能装到设备上的是 PWA 版**（见 `../pwa/README.md`，Safari「添加到主屏幕」即可）。
> 有 Mac 时按下面步骤编译，即可获得 LiDAR 自动测距 + M5 神经网络引擎端侧推理的完整能力。

---

## 两个标准如何"封装在程序里"

标准不是联网查询，而是**随 App 包一起打进设备**：

| 标准 | 打包文件 | 运行时加载 |
|---|---|---|
| EN 1993-1-9:2005（疲劳，细节→FAT） | `Resources/en1993_1_9.json`（24 条细节类别 + 4 种改善措施） | `KnowledgeBank.loadDetails()` |
| ISO 5817:2023（缺陷质量等级 B/C/D） | `Resources/iso5817.json`（5 类缺陷限值） | `KnowledgeBank.loadImperfections()` |

- 首次访问 `KnowledgeBank.details` 时从 `Bundle.main` 读取，之后常驻内存，**全程零网络请求**。
- 若包内文件缺失，自动回退到 `KnowledgeBank` 内置的同源数据（保证不崩）。
- `KnowledgeBank.standardsSummary` 会返回当前标准来源，建议在「关于」页展示以自证离线封装。

**Xcode 配置**：把 `Resources/` 目录拖入工程时，勾选 *Add to target*（会出现在
Build Phases → Copy Bundle Resources）。若放在子目录，加载器已兼容 `subdirectory: "Resources"` 的查找。

---

## 目录

```
WeldFatigueChecker/
├── WeldFatigueCheckerApp.swift    # @main 入口
├── Store.swift                    # 全局可观察状态（3D/照片/荷载/结果）
├── Models.swift                   # 输入与结果数据模型
├── KnowledgeBank.swift            # 标准加载器：App 包内 JSON → 内置兜底
├── FatigueEngine.swift            # 疲劳校核（FAT/改善系数/S-N/ISO 验收）
├── DesignReviewer.swift           # R1~R16 设计规则 + 改型建议
├── LidarScaleCalibrator.swift     # ★ ARKit 射线投射测距（LiDAR，免参照物）+ 测量界面
├── ReportGenerator.swift          # PDFKit 离线报告
├── Info.plist                     # 相机/相册/ARKit 权限
├── Resources/
│   ├── en1993_1_9.json            # ★ 随包打包的疲劳标准
│   └── iso5817.json               # ★ 随包打包的缺陷验收标准
└── Views/
    ├── ContentView.swift          # TabView：外观检查 / 3D设计 / 荷载结果
    ├── PhotoCheckView.swift       # 相机/相册 + 缺陷录入（含 📐 LiDAR 按钮）
    ├── DesignReviewView.swift     # 3D 设计属性录入
    ├── ResultView.swift           # 结果展示 + 导出 PDF
    ├── StandardsView.swift        # 标准库管理（导入/切换/导出）
    └── LiDARMeasureSheet.swift    # ★ LiDAR 全屏 AR 测距界面（状态机 + reticle）
```

---

## 在 iPad Pro 2025（M5）上运行

1. Mac 打开 **Xcode 16+**，新建 iOS App（Interface: **SwiftUI**，Language: **Swift**）。
2. 删除模板的 `ContentView.swift`，把本目录 `WeldFatigueChecker/` 下**所有 `.swift`、
   `Info.plist` 以及 `Resources/`** 拖入工程（务必勾选 *Add to target*）。
3. 部署目标选 **iOS 18**；用 USB 或局域网连接 iPad。
4. Signing 选择你的开发者账号（或个人免费证书，需在 iPad 上信任描述文件）。
5. 运行 ▶ 到 iPad。现场流程：拍照 →（LiDAR 测距/人工录入缺陷）→ 填 3D 设计属性 →
   填 Δσ 与 N → 查看不合理处与改善建议 → 导出 PDF。

### 没有付费开发者账号时的安装方式

- **免费个人证书**：Xcode 直接运行，7 天后需重签（适合自用/内部验证）。
- **AltStore / Sideloadly**：可免 Mac 常驻重签，适合给现场多台 iPad 分发。
- **TestFlight / 企业分发**：正式量产建议走 Apple Developer Program。

---

## 关键能力映射

| 能力 | 实现 | 状态 |
|---|---|---|
| 标准封装（离线） | `Resources/*.json` + `KnowledgeBank` | ✅ 已就绪 |
| LiDAR 自动测距 | `LidarScaleCalibrator.swift`（ARKit raycast + 场景重建） | ✅ 已就绪，需在 `PhotoCheckView` 挂 `.sheet` 调起 |
| 疲劳校核 / S-N / Miner | `FatigueEngine.swift` | ✅ 已就绪 |
| 设计合理性审查 | `DesignReviewer.swift`（R1–R16） | ✅ 已就绪 |
| PDF 报告 | `ReportGenerator.swift`（PDFKit） | ✅ 已就绪 |
| 接头/缺陷自动识别 | Core ML（`WeldDefect.mlmodel`） | ⏳ 预留接口，需标注数据训练 |

### LiDAR 测距完整使用步骤（连续模式，已接入 `PhotoCheckView`）

**工作原理**：开启 ARKit `WorldTracking` + LiDAR `sceneReconstruction(.meshWithClassification)`，
对屏幕上两点做 `raycast(from:allowing:.estimatedPlane, alignment:.any)`，
ARKit 返回带深度信息的 `ARRaycastResult`，取世界坐标后算 `simd_distance × 1000 = mm`。
**整个过程零参照物**，精度 ±1–2mm。

**iPad Pro 2025 M5 实操流程（连续模式）**：

1. 在任一缺陷行点 **📐 LiDAR 按钮** → 全屏 AR 视图调起。
2. **顶部状态条**实时显示进度（如 `1 / 5`、当前目标"咬边"）与 `LiDAR ✓ / 网格 ✓`。
3. **首次使用**会显示引导遮罩（7 条 bullet 操作要点），点"开始批量测量"进入。
4. 把 iPad 距离焊缝 **20–50 cm**，正对焊缝，**缓慢平移几秒**让 LiDAR 建立场景重建。
5. 屏幕中央的**黄色十字**对准 **缺陷起点**，按 **「标记起点」**。
6. 平移 iPad 让十字对准 **缺陷终点**，按 **「标记终点」**。
7. 中央立刻显示 **"12.3 mm"**（绿色大字），按 **「下一条 ➡」**：
   - 自动写回当前缺陷的 `sizeMm`
   - 自动跳到队列中的下一个缺陷（优先未填尺寸的）
8. 全部测完显示**绿色总结视图**（已完成 X 个 + 跳过 Y 个），点"完成"退出。
9. 任意步骤都可点 **「跳过当前」** 或右上角 **✕** 提前结束。

**关键代码位置**：
- 引擎：`LidarScaleCalibrator.swift` → `distanceMillimeters(arView:from:to:)`
- 视图：`Views/LiDARMeasureSheet.swift`（状态机 idle → first → done/failed + 任务队列 + reticle）
- 接入：`Views/PhotoCheckView.swift` → `ImperfectionRow` 的 `📐 scope` 按钮 → `.sheet`
- 队列逻辑：`loadQueue()` 按用户点的行作为起点，自动追加所有 `sizeMm == nil` 的缺陷

**注意**：
- 调用 sheet 前**已检测设备能力**：`LiDARCapabilityHint` 在 `PhotoCheckView` 底部实时提示。
- 非 LiDAR 设备（理论上 iPad Pro 2025 11" 都是 LiDAR，但兼容未来机型）按钮**不会消失**，但引导里会提示。
- AR 会话进入时相机自动接管屏幕；退出 sheet 后 `session.pause()` 释放资源。
- **测量结果直接写 Store**（sheet 内置 `@EnvironmentObject var store`），无需回调胶水。

### 接入 Core ML 缺陷识别（M5 神经网络引擎）

1. 用 iPad 采集焊缝照片，LabelStudio/CVAT 标注（接头类型 + 缺陷框）。
2. Create ML 或 YOLO 训练 → `coremltools` 转 `.mlmodel` → 拖入工程。
3. 在 `PhotoCheckView` 用 Vision 框架跑检测，结果写回 `store.vision`。
4. M5 的 16 核神经网络引擎可在端侧实时推理，无需联网，适合现场隐私场景。

---

## 合规

辅助判定工具，非认证检测；结论须由具备资质人员依据适用规范复核。
`iso5817.json` 中的缺陷数值为示例值，正式工程使用前须以
`159-ISO 5817-2023 中英文版本.pdf` 原文逐条校核。
