# WeldFatigueChecker · 全自动 3D 几何识别与 EN1993-1-9 比对路线图（阶段3 立项规划）

> 本文档为**规划/立项**文档，描述从「手动选接头」升级为「导入 STEP → 自动识别 → 比对表 8.1~8.6 → 图上标注 → 改进建议」的端到端全自动方案。
> 对应开发手册 §17 当前状态；与 `weld_train.py` / `en1993_1_9.json` / `DesignReviewer.swift` 协同演进。

---

## 0. 用户终极目标（精确拆解）

> 导入 STEP 等 3D 图后，软件**自动识别和分析 3D 图**，然后和 EN1993 中的 **8.1~8.6 表**结构形式比对，判断 3D 设计中的结构是否合理，并且**在图上标出合理和不合理的位置**，并最终**给出改进建议**。

拆成 6 步端到端流水线：

| 步骤 | 目标 | 当前状态 |
|---|---|---|
| S1 | 导入 STEP/IGES/OBJ 等 3D 图 | ✅ 已具备（OCCT + Model I/O） |
| S2 | **自动识别**接头类型 / 传力方向 / 全熔透 | ❌ 缺失（仅回填板厚/长度，接头类型请人工复核） |
| S3 | 与 EN1993-1-9 表 8.1~8.6 比对 | ⚠️ 半具备（属性→detail 路由已有，但表号不显示、需手填属性） |
| S4 | 判断结构是否合理 | ✅ 已具备（reviewDesign / constantAmplitudeCheck） |
| S5 | **在图上标注合理/不合理位置** | ❌ 缺失（3D 场景无任何标注机制） |
| S6 | 给出改进建议 | ✅ 已具备（suggestImprovements 文本），但**未绑定位置** |

---

## 1. 当前能力基线（已读代码核实）

- `Model3DView.fillDesign()`：OCCT 仅提取 `bbox / normals / minEdgeLen`，回填 `plateThicknessMm / attachmentLengthMm / transitionRadiusMm(候选)`，代码注释明确写 **"接头类型请人工复核"**。OCCT 桥接**无 jointHint 真实计算**。
- `VisionInput`（Models.swift:48）：是**照片识别**用的，3D STEP **不参与**自动接头识别。
- 评估引擎：`DesignReviewer.reviewDesign` / `FatigueEngine.constantAmplitudeCheck` / `evaluateImperfections` / `suggestImprovements` 已具备；但粒度是**"细节类别级"**（整体），**不带几何坐标**。
- `Model3DSceneView`：仅渲染 mesh，**无任何标注/高亮节点**（overlay 只是照片叠加透明度）。
- `KnowledgeBank.DetailCategory`（KnowledgeBank.swift:12）：仅 `id / fat / name` —— **JSON 里的 `table` 字段加载时被丢弃**，结果页不显示表号。
- `en1993_1_9.json`：每个 detail 含 `id/table/fat/stress_type/name/verified_from_ocr/source/note`，**当前**表号覆盖 **8.1 / 8.2 / 8.3 / 8.4 / 8.5（含 8.4/8.5 组合）**；**8.6 已纳入目标比对范围（8.1~8.6），但数据集暂无 8.6 条目，列为待补数据项**（见 §5 风险5）。

**结论**：S1/S4/S6 的"引擎"已就绪；缺口集中在 **S2（识别）、S5（标注）、S3/S6 的位置关联**。

---

## 2. 整体架构与数据流

```
STEP(.step/.iges/.obj/.stl/.ply/.usdz/.glb)
        │
   [M1] OCCT / Model I/O 几何解析增强
        │   输出: 板件(parallel-face groups) / 边·角 / 法线 / 厚度 / 夹角 / 焊缝候选线(板件交线)
        ▼
   [M2] 几何语义识别  ★核心难题
        │   输出: jointType / loadingDirection / fullPenetration
        │        + 每个结论的「置信度」与「几何证据位置」
        ▼
   [M3] 细节匹配 + 位置关联  （改造现有 matchDetail / reviewDesign）
        │   输出: (detailId, table, fat) 列表，每个绑定到具体几何坐标(焊缝/角接)
        ▼
   [现有] 评估引擎  DesignReviewer / FatigueEngine
        │   输出: 利用率 / 满足否 / 不合理细部警告 / 改型建议(文本)
        ▼
   [M4] 3D 标注渲染层  ★新建
        │   输出: 绿(合理)/红(不合理)/黄(待确认) 标记 + 点击弹窗
        ▼
   [M5] 改进建议位置关联  （改造 suggestImprovements）
            输出: 建议绑定到具体几何位置
```

---

## 3. 模块详细设计

### M1 · 几何解析增强
- **现状缺口**：OCCT 桥接只导出 `positions / normals / bbox / minEdgeLen`。
- **目标原语**：
  - 板件抽取：并行面对（parallel face pairs）聚类 → 每块板的厚度 = 对面距离。
  - 边/角检测：相邻面法线夹角（≈90° → 角接；≈180° → 对接边）。
  - 焊缝候选线：相邻板件的交线（共享边/邻近边）→ 后续 S5 标注锚点。
  - 过渡半径候选：`minEdgeLen` 已是候选，需区分"焊缝过渡圆角"与"板件倒角"。
- **实现**：扩展 `occt_bridge.mm` 的 `OCCTFeatures`（在 `USE_OCCT` 块内，不破坏既有计算），用 `TopoDS`/`BRepGProp` 拓扑遍历。无 OCCT 时用 Model I/O 网格做近似（面片法线聚类）。

### M2 · 几何语义识别（核心难题）
- **输入**：M1 的几何原语。
- **输出契约**：
  ```swift
  struct JointHypothesis {
      let jointType: String          // butt/fillet/cruciform/t_joint/lap/corner
      let loadingDirection: String   // transverse/longitudinal
      let fullPenetration: Bool?     // nil = 几何无法判定，标记「待确认」
      let confidence: Double
      let evidenceNode: SCNNode?     // 证据几何位置（供 M4 标注）
  }
  ```
- **两阶段路线**：
  - **M2a 规则引擎（可立即做）**：基于几何启发式
    - 两板夹角≈180° 且存在对接边 → `butt`
    - 两板夹角≈90° 且存在角焊缝几何 → `fillet` / `corner`
    - T 形（一板端搭另一板中） → `t_joint` / `cruciform`
    - 附件相对主构件方位（垂直主应力方向=横向 / 平行=纵向）→ `transverse` / `longitudinal`
    - 全熔透：坡口特征在 STEP 中未必建模 → 设为 `nil`（待确认），不臆测。
  - **M2b ML 几何识别（研究级）**：PointNet / GraphNN 对网格分类；需标注数据集（现有 STEP 库 + 程序化合成）。**复用现有 CoreML 管线**导出 `.mlpackage`。

### M3 · 细节匹配 + 位置关联（改造现有，低风险）
- `KnowledgeBank.DetailCategory` 增加 `table` 字段（JSON 已含）→ 结果页显示 **"对比标准表：EN 1993-1-9 表 X.X"**（X.X 为 8.1~8.6 中实际命中的表号；顺带完成阶段0）。
- 把 `reviewDesign` 从"整体细节"升级为 **"逐细部"（per-weld-seam）**：对 M1 检测到的每条焊缝候选线，独立跑 `matchDetail` + `constantAmplitudeCheck`，返回 **关注位置列表** `{geometryAnchor, detailId, table, fat, utilization, pass}`。
- 数据基础：`en1993_1_9.json` 的 `detail_categories` 已足够（id/table/fat/name/note）。

### M4 · 3D 标注渲染层（新建）
- 在 `Model3DSceneView` 的 `SCNScene` 上加 annotation 子节点层（独立 `SCNNode` 容器，不污染模型 mesh）。
- 标注语义：
  - 🟢 绿：满足 / 合理（利用率 ≤ 1）
  - 🔴 红：不满足 / 不合理（利用率 > 1 或触发警告，如过渡半径不足、受拉翼缘焊加劲肋）
  - 🟡 黄：待确认（M2 置信度低 / 全熔透未知）
- 交互：点击标注 → 弹窗显示该处 `detail / 表号 / FAT / 利用率 / 建议`。
- 实现：`SCNSphere`/`SCNLine` + billboard 文本标签（`SCNText` 或 `SKOverlay`）。

### M5 · 改进建议位置关联（改造现有）
- `suggestImprovements` 现有返回文本 `PlanItem` 列表（无位置）。
- 改造：每个 `PlanItem` 绑定到 M3 的 `geometryAnchor` → 图上红标处点击即显示"建议：此处焊趾打磨，FAT 50→80"。

---

## 4. 分阶段落地路线

| 阶段 | 范围 | 依赖 | 风险 | 验收 |
|---|---|---|---|---|
| **阶段0** ✅ | 结果页显示表号；`DetailCategory.table` 接入（commit bc29850，待 CI #42 验收） | 无 | 极低 | 评估结果页显示"表 8.4" |
| **阶段1** 🟡进行中 | M4 标注层基础：在当前评估结果（细部类别级）对应的模型上方浮标红/绿状态球 + 点击弹窗（表号/FAT/利用率/结论）；锚点先用模型包围盒顶部中心，待阶段3 的 M3 逐细部评估到位后扩展为每条焊缝各自一个锚点。不依赖 M2。 | store.result + modelNode 包围盒 | 低 | 加载模型且已评估后，模型上方出现状态球，点击显示判定详情 |
| **阶段2** ✅ | M2a 规则引擎（Swift 侧 mesh 法线聚类启发式）：导入后自动推测 jointType/方向/传力并预填表单，全熔透标「待确认」；设计表单页回显「推测依据+置信度」。绕开 M1（未做 OCCT 深度几何）依赖，纯 Swift 实现、零 OCCT 重编译风险。 | store.design + modelNode 法线 | 低(CI) | 导入后表单自动带出接头类型+依据横幅，用户确认即可（commit，待 CI #44 验收） |
| **阶段3a** | 构建标注数据集（STEP 库 + 合成） | — | 中 | 数据集就绪，可训练 |
| **阶段3b** | M2b ML 模型训练/接入（CoreML） | 3a | 高 | CoreML 分类器达到可用准确率 |
| **阶段3c** | M3 逐细部评估 + M4/M5 全联动 | 1/2/3b | 中 | 端到端：导入→自动识别→图上标注→位置化建议 |

**建议起点**：阶段0（最小见效）→ 阶段1（让"图上标注"从零有雏形）→ 阶段2（半自动识别，直接缓解手填痛点）。阶段3 作为长期研究路线。

---

## 5. 关键技术风险

1. **无 Mac 编译**：所有 Swift/OCCT 改动只能经 GitHub Actions CI 验证（run 号递增），改-推-看日志循环慢（每次 ~10min）。需在 push 前尽量本地静态自查（py_compile 仅覆盖 Python；Swift 需靠 CI）。
2. **几何推理准确率**：规则引擎覆盖有限情形；ML 需数据且泛化难。
3. **全熔透从几何推断困难**：坡口特征在 STEP 中常不建模 → 必须设"待确认"，不能臆测（避免错误判定引发工程误判）。
4. **评估粒度升级**：`reviewDesign` 从整体→逐细部需重构，须遵守**核心功能约束**（EN1993-1-9 评估逻辑不可删改，只许加"在哪跑/怎么显示"）。
5. **表 8.6 数据缺口**：目标比对范围已明确为 **8.1~8.6**（用户确认），但 `en1993_1_9.json` 当前无 8.6 条目（仅 8.1–8.5 + 8.4/8.5）。若需覆盖 8.6，须先补入其 detail_categories（来源由用户确认或据 EN1993-1-9 原文录入），否则 8.6 只会"显示无匹配"而非"比对越界"。

---

## 6. 与「核心功能约束」的关系

本规划**在约束框架内**：
- ✅ 保留：STEP 导入（M1 是其增强，不改读取逻辑）、EN1993-1-9 评估逻辑（M3 只增加"逐细部"维度，不改 `constantAmplitudeCheck` 算法）、结构对疲劳影响评定（M4/M5 只改"怎么显示/标在哪"，不改 `evaluateImperfections`）。
- 🆕 新增：M2 识别、M4 标注、M3 位置关联——均为"识别层 / 显示层"，不触碰既有计算内核。
- ⚠️ 任何阶段改动若触及 `DesignReviewer` / `FatigueEngine` / `en1993_1_9.json` 的**计算语义**，须走 SOP-B 守护清单复核。

---

## 7. 立项目标（Definition of Done）

- [x] 阶段0：评估结果页显示 EN1993-1-9 表号。✅ 已落地（commit bc29850，待 CI #42 真机/构建验收）
- [ ] 阶段1：3D 模型上可对焊缝位置标注红/绿/黄。（🟡 进行中：已加"整体结论"浮标 + 点击弹窗，锚点为模型顶部中心；逐焊缝锚点待 M3 逐细部评估）
- [x] 阶段2：导入 STEP 后自动推测接头属性并预填，用户确认即可。✅ 已落地（Swift 侧 mesh 法线启发式；全熔透标待确认；设计表单页回显依据+置信度）
- [ ] 阶段3：全自动流水线跑通（识别→比对→标注→位置化建议），真机实测可用。

> 文档版本：v1.0 · 2026-10-02 · 对应 `焊缝缺陷识别及判定_方法论与开发手册.md` §17
