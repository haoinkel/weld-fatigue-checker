# 焊缝疲劳合规检查器（Weld Fatigue Checker）

通过焊缝照片识别**接头设计细节**与**表面缺陷**，结合 EN 1993-1-9（疲劳）与 ISO 5817（缺陷质量等级），
对焊接结构给出**疲劳相关判定**的辅助工具原型。

> ⚠ 本仓库为原型/参考实现。**照片只能提供两个疲劳输入**（接头细节→FAT、表面缺陷→验收/提级）；
> **应力幅 Δσ 与循环次数 N 必须由用户在界面填写、或来自 FEA/传感器**——疲劳寿命对 Δσ 是 3 次方敏感。
> 结论须由持证人员复核，非认证检测。

## 📲 在 iPad Pro 2025 11" M5 上安装（必读）

完整安装与使用步骤见 **[`INSTALL_iPad_2025_M5.md`](INSTALL_iPad_2025_M5.md)**：
- 形态 A：PWA 直接「添加到主屏幕」（无需 Mac，10 分钟可装）
- 形态 B：原生 SwiftUI 工程（Mac + Xcode，含 LiDAR 自动测距 + Core ML 端侧推理）

两种形态共用同一套规则与 16 条设计审查规则（R1~R16）。

---

## 1. 这套程序能做什么 / 不能做什么

| 能力 | 来源 | 说明 |
|---|---|---|
| 接头形式识别 | 照片(ML) | 对接/角接/T型/搭接、荷载方向、几何尺寸 |
| 细节类别→FAT | EN1993-1-9 知识库 | 核心"标准大脑" |
| 表面缺陷检测与验收 | 照片(ML)+ISO5817 | 咬边/气孔/焊瘤/错边/余高 |
| 疲劳强度验算 | 规则引擎 | FAT + 用户 Δσ + N → 利用率/通过与否 |
| 改善措施建议 | EN1993-1-9 | 焊趾打磨/TIG/锤击提升 FAT |
| **完整疲劳寿命** | ❌ 照片无法给 | 需 Δσ、N（变幅谱）、可靠度 → 用户提供 |

---

## 1.1 双通道输入模型（关键）

按你的输入方式，系统分两条互补通道，最终汇入同一套规则引擎：

| 通道 | 输入 | 提供 | 识别手段 |
|---|---|---|---|
| **A. 3D 设计审查** | 3D 图 / CAD / LiDAR 扫描 | 接头几何、传力路径 → **细节类别 + FAT**；并标出"被迫低 FAT"的细部、给出改型建议 | 几何解析（真实模型）或视觉（渲染图） |
| **B. 焊缝外观成型** | iPad Pro 2025 11″(M5) 现场拍照 | 表面缺陷（咬边/气孔/焊瘤/错边/余高）→ **ISO 5817 验收/提级** | Core ML 缺陷检测（设备本地） |

- 3D 通道决定"设计合不合理"（细节与 FAT 的源头，几何最可靠）；照片通道决定"焊得怎么样"。
- **iPad Pro M4 的 LiDAR 还能把建成焊缝扫成 3D 网格**，与设计 3D 做"建成 vs 设计"比对（进阶能力）。
- 两条通道都仍**无法替代 Δσ 与 N**：仍需用户/FFA/传感器提供。

## 2. 目录结构

```
weld_fatigue_checker/
├── knowledge/
│   ├── en1993_1_9.json     # 细节→FAT、S-N参数、改善系数（取自你OCR的表8.1/8.2+常识）
│   └── iso5817.json         # 缺陷验收限值（B/C/D，须以PDF校核）
├── engine/
│   ├── fatigue.py           # 校核引擎（纯标准库，可移植 Swift）
│   ├── vision_adapter.py    # 照片视觉输入 JSON Schema + 占位适配层
│   ├── design_review.py     # 3D 设计审查：几何->细节->FAT + 良好细部规则警告
│   └── geometry_adapter.py   # 3D 摄取适配层：OBJ(可跑)/IFC·STEP/Render/LiDAR -> 统一 design_input
├── app/
│   └── demo.py              # 命令行端到端演示
├── tools/
│   └── extract_fat.py       # 从 OCR 抽取疑似 FAT 候选，辅助校核
└── README.md
```

---

## 3. 快速开始（桌面验证逻辑）

```bash
cd weld_fatigue_checker
python app/demo.py                       # 仅照片通道：横向角焊缝 FAT80, Δσ=60, N=2e6
python app/demo.py --demo-design --delta-sigma 70 --n 2000000   # 仅 3D 设计通道(承载十字接头)
python app/demo.py --design-json d.json --vision-json v.json --delta-sigma 60 --n 2000000 --level C
python tools/extract_fat.py              # 列出 OCR 中疑似 FAT 数值供校核
```

视觉输入 JSON 结构见 `engine/vision_adapter.py` 的 `VISION_SCHEMA`；可用
`python app/demo.py --vision-json your_input.json` 载入人工/预标注结果。

---

## 4. iPad Pro 2025 11″ (M5) 原生部署架构（推荐落地形态）

iPad Pro M5（16 核神经网络引擎 + 激光雷达）的硬件直接决定了选型优势：

- **神经网络引擎 (~38 TOPS)**：识别模型（接头分类 + 缺陷检测 YOLO/Mask R-CNN）可 **Core ML 在设备本地推理**，
  离线、不联网、适合现场巡检的数据隐私。
- **LiDAR 激光雷达**：直接测得焊缝/板件的真实世界距离 → **自动标定尺寸**（板厚、焊脚、咬边深度），
  彻底解决"手机照片无比例尺"的痛点，无需贴参照物。
- **原生 App 体验**：相机取景框叠加标定与引导，现场即时出报告。

建议技术栈：

| 层 | 技术 |
|---|---|
| UI | SwiftUI + Swift Concurrency |
| 取景/标定 | AVFoundation + ARKit(LiDAR) 获取真实尺度；LiDAR 还可把建成焊缝扫成 3D 网格，与设计 3D 比对 |
| 3D 设计审查 | 导入/读取 3D 模型（几何解析或渲染图视觉识别）→ `design_review.py` 映射细节与 FAT |
| 视觉识别 | Create ML 训练 → Core ML (.mlmodel)；用 Vision 框架跑检测/分类 |
| 规则引擎 | 把 `engine/fatigue.py` 逻辑移植为 Swift（或 PythonKit 嵌入） |
| 知识库 | `knowledge/*.json` 随包内置，作为 App Bundle 资源 |
| 报告 | PDFKit 导出带标注框的照片 + FAT + 缺陷清单 + 整改建议 |

模型训练路径：用 iPad/手机采集焊缝照片 → LabelStudio/CVAT 标注（接头类型 + 缺陷框）
→ Create ML / YOLO 训练 → `coremltools` 转 Core ML → 集成。

> MVP 过渡：在模型训练好前，可用**多模态大模型 API** 作为识别后端（输出同构 JSON），
> 先验证"规则引擎 + 交互流程"。但生产级建议走本地 Core ML，理由如上。

---

## 5. 下一步（按优先级）

1. **校核知识库**：用 `tools/extract_fat.py` + ISO 5817 PDF 把 `knowledge/*.json` 数值逐项坐实。
2. **定接口范围**：先覆盖角焊缝+对接焊缝（最常见），再扩到全部细节类别。
3. **采集数据**：按接口范围拍照并建立标注集（这是准确率瓶颈）。
4. **训练模型**：Create ML / YOLO → Core ML。
5. **原生 App**：SwiftUI + LiDAR 标定 + PDFKit 报告。
6. **合规口径**：若需中国规范，规则引擎增加 GB 50017 / GB/T 3811 细节类别（体系不同，需切换）。

---

## 7. iPad 可安装程序（app_ios/）

针对你的 **iPad Pro 2025 11″（M5，带激光雷达）**，已提供两种可安装形态（逻辑与上面引擎同源）。
**两本标准在两条路线里都随程序打包、完全离线**：

- **`app_ios/pwa/` — 今天就能装的 PWA**：用 iPad Safari「添加到主屏幕」即离线运行。
  含相机取景、参照物标定与缺陷测距、点击标缺陷、3D 设计审查、R1~R16 不合理处识别与改型建议、
  ISO 5817 验收、**④标准库页签**（可直接查阅封装的 FAT 表与缺陷限值）、PDF 报告。
  限制：设备虽带 LiDAR，但 Safari 不向网页开放 ARKit 深度，故 PWA 用参照物标定；也无端侧 Core ML。
  详见 `app_ios/pwa/README.md`。
- **`app_ios/native/` — 原生 SwiftUI 工程**：SwiftUI + Core ML（相机端侧推理）
  + `LidarScaleCalibrator.swift`（ARKit 射线投射，**LiDAR 免参照物自动测距**）+ PDFKit 报告；
  EN 1993-1-9 与 ISO 5817 以 `Resources/*.json` 随 App 包打包，运行时由 `KnowledgeBank` 从 Bundle 加载。
  需 Mac + Xcode 16 编译后连 iPad 运行，为生产级形态。详见 `app_ios/native/README.md`。

两条路线共享同一套规则逻辑（`KnowledgeBank` / `FatigueEngine` / `DesignReviewer` 即从 `engine/*.py` 移植），
可先以 PWA 立即上手验证流程，再用原生工程获得设备端 AI 与真实尺度标定。

---

## 6. 免责声明

本工具为**辅助判定**用途，不构成认证检测或设计签字。所有疲劳判定须由具备资质的人员依据
适用规范复核，并结合完整的荷载谱、可靠度要求与制造质量文件综合确定。
