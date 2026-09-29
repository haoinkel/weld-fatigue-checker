# 焊缝缺陷模型 · 云端训练路线（无 Mac / 不耗 GitHub 额度）

> 适用场景：没有 Mac、GitHub Actions 免费额度已耗尽。本路线让"训练"与"打包"解耦——训练现在就能在云端 GPU 上跑，只有最后打包那一步等额度恢复。

## 为什么能现在训

| 步骤 | 是否需要 Mac | 是否耗 Actions 额度 | 在哪做 |
|---|---|---|---|
| ① 标注 / 准备数据 | 否 | 否 | Roboflow / CVAT / labelImg |
| ② 迁移训练 YOLOv8n | 否（需 GPU） | 否 | Colab / Roboflow 云端 |
| ③ 导出 .mlmodel | 否 | 否 | Colab（coremltools） |
| ④ Xcode 编译 .mlmodelc + 打 IPA | **是** | **是** | GitHub macOS runner（等额度） |

→ ①②③ 现在就能做；④ 等额度恢复后一个 commit 触发即可。

## 类别（视觉模型 5 类，须与 App labelMap 一致）

> 余高(excess_weld_metal) **不进视觉模型**，由 App 内 LiDAR 几何计算（见下）。

```
porosity            # 气孔
crack              # 裂纹（含弧坑裂纹）
undercut           # 咬边
overlap            # 焊瘤
unfused            # 未融合
```

## 两种云端训练入口（任选，笔记本通用）

> ⚠️ **Roboflow 国内被墙（roboflow.com 打不开），已弃用**。数据改为 GitHub 直连数据集，训练平台改国内可达的。

### A. 百度 AI Studio（推荐，国内可直连，免费 V100）

> 国内平台，无需翻墙；数据集从 GitHub 云端直拉，不依赖本机网络能否连 GitHub。

1. 打开 aistudio.baidu.com → 百度账号登录（首次需**实名认证**，几分钟）；
2. 进「项目大厅 / 我的项目」→ **创建项目** → 类型选 **Notebook** → Notebook 版本选 **BML CodeLab**（JupyterLab，体验与 Colab 一致）；
3. 项目创建成功 → 「查看」进详情页 → 点右方 **「运行」** → 环境选 **高级版(GPU-V100-16GB)**（免费；**别选基础版 CPU**，纯 CPU 训不动）→ 「确定」进 Notebook 环境；
4. 在环境内点「上传」按钮，把 `colab_train_weld.ipynb` 传上去（自动进 `work/` 目录，该目录文件会保留）；
5. 双击打开笔记本 → 从上到下逐格点 ▶（或「运行 → 运行全部」）：
   - 第 1 格 `pip install ultralytics coremltools` 首装花几分钟（走百度镜像，正常）；
   - 中间自动：下 GitHub 数据集 → 8 类筛成 5 类（气孔/裂纹/咬边/焊瘤/未融合）→ 8:2 划分 → 训 YOLOv8n（约 10–20 分钟）→ 导出 `WeldDefectModel.mlmodel`；
6. 看 `mAP50`：**≥ 0.85 才下载**（裂纹仅 119 张偏少，重点关注其 recall）；左侧文件面板右键 `WeldDefectModel.mlmodel` 下载到电脑存好。

⚠️ **AI Studio 特有注意**：免费 GPU 每天有限时（约 4–12h），训练前确认还有额度；**实例闲置会超时自动释放**，训练期间保持页面活跃；只有 `work/` 目录文件保留（笔记本全程相对路径，默认在 work 下，模型也在 work 下，不会丢）；长任务可用项目详情页「后台任务」基于 ipynb 后台跑（关网页也继续），更稳。

### B. Google Colab（若你能打开）
打开 colab.research.google.com → 上传 `colab_train_weld.ipynb` → 运行时改 GPU → 逐格运行。

### C. Kaggle Notebook（kaggle.com/code，每周 30h 免费 T4）
新建 Notebook → Settings 开 GPU → 上传本 `.ipynb` 运行。

> 三者用同一个 `colab_train_weld.ipynb`，数据均从 GitHub Release 直拉，无需任何外部账号/API Key。

## 数据门槛（先达标再训）

- **首选数据集（已写入笔记本，GitHub 直连）**：`huangyebiaoke/steel-pipe-weld-defect-detection`（Release 里的 `steel-tube-dataset-all.zip`，YOLO+VOC 双格式，GPL-3.0）。含 8 类，其中 **气孔 air-hole 5191 张**、**裂纹 crack 119 张**、**咬边 bite-edge 35 张**。
- **先行训 5 类**：`porosity`(气孔) / `crack`(裂纹) / `undercut`(咬边) / `overlap`(焊瘤) / `unfused`(未融合) —— 气孔 5191 张充足；裂纹 119 张、咬边 35 张偏少，训练时重点盯这两类的 recall，过低再补。
- **余高(excess_weld_metal) 不进视觉模型**：App 内余高由 LiDAR 剖面 `WeldProfileAnalyzer` 几何计算（更早诊断确认 2D 亮度判余高不可靠），视觉模型不负责余高。
- **咬边(undercut) 已纳入训练**：该数据集仅 35 张偏少，云端训练后重点看其 recall；若 recall 过低，用 App 拍照模式拍真实咬边自标 ~50 张并入重训补充。
- 验证集 mAP@0.5 ≥ 0.85（气孔）再上机。
- X 光/DR 集（GDXray、NEU-DET）域不同，仅作裂纹难样本补充（<20%）。

## 训完后的接入（额度恢复时一并提交）

1. `WeldDefectModel.mlmodel` 放入 `WeldFatigueChecker/` 并勾选 Target Membership；
2. 改写 `MLDefectDetector.runModel`：从解析 Create ML 掩膜改为解析 YOLO 输出（coordinates / confidence / class）；ROI 闸门、NMS、labelMap 不变；
3. commit → CI 打包出新 IPA（OCCT 缓存命中后只编 App，约 2–3 分钟 ≈ 20–30 额度分钟）→ Sideloadly 侧载验证。

## 可用公开数据集（2026-09 核实，可见光类）

> ⚠️ Roboflow 系列（Weld Faults 等）国内被墙，**当前实际采用 GitHub 直连的 `steel-pipe-weld-defect-detection`**（见上「数据门槛」）。下表其余集作补充/备选参考。

> 训练时把标签名**统一成视觉模型的 5 类**：`porosity` / `crack` / `undercut` / `overlap` / `unfused`（否则 `labelMap` 匹配不到会降级成 `defect`）。余高=overfill 由 App LiDAR 几何计算、**不进视觉模型**。

| 数据集 | 类别覆盖 | 格式 | 量级 | 许可 | 对应 App 类 |
|---|---|---|---|---|---|
| Roboflow **Weld Faults** `yolov8-hcd60/weld-faults-rofln` | burn-through、**cracks**、lack-of-fusion、**overfill**、**porosity** | YOLOv8 直下（含托管推理 API） | 234 图 | Public Domain | porosity、excess_weld_metal(←overfill)、crack |
| Kaggle **Surface Weld Defect** `benyaminrazaziyan` | **Crack**、**Porosity**、Spatter（**自带预训练 yolov8**） | YOLO，800×800 | ~7.6k 文件 | MIT | porosity、crack |
| Roboflow **Welding Defects** `racheal/welding-defects-nra9l` | 多类缺陷（可导出 YOLOv8） | YOLOv8 直下 | 1997 图 | CC BY 4.0 | 视具体类 |
| Roboflow **Welding Data Set** `welding-data-6mmob` | 8 类（含增强） | YOLOv8 直下 | 2700 图 | CC BY 4.0 | 视具体类 |
| 论文集 **Welding Defect Test-V2**（Roboflow 搜名） | geometric、non-fusion、**porosity**、spatters | YOLO | 3866 图 | 研究 | porosity |
| **NEU-DET** | 6 类钢板缺陷（含 crazing=裂纹） | 可转 YOLO | 1800 图 | 研究 | crack 难样本 |
| Kaggle **Welding Defect - Object Detection** `sukmaadhiwijaya` | bad/good/defect（好坏二分类式） | YOLO | 6236 文件 | CC0 | 仅作负样本/好坏判定 |

**组合建议（起步骨架）**
1. **porosity / excess_weld_metal / crack**：直接用 Roboflow *Weld Faults*（overfill→余高、cracks→裂纹、porosity→气孔）+ Kaggle *Surface Weld Defect*（Crack/Porosity 增广），两类来源互补。
2. **undercut（咬边）**：公开可见光集极少单独标注；当前已从 GitHub `steel-pipe-weld-defect-detection` 取 bite-edge(35 张) 纳入训练，若 recall 不足再用 App 拍照自标 ~50 张补充。
3. 商用注意：CC0 / MIT / Public Domain 可商用；CC BY 需署名；论文集/NEU-DET 标"研究"用途，量产后自采数据替换。
4. 数据量起底：每类 ≥50 张（总 200+），验证集 mAP@0.5 ≥ 0.85 再上机。

**当前训练方案（已写入 `colab_train_weld.ipynb`）**：Roboflow 被墙，从 GitHub Release 直连 `steel-pipe-weld-defect-detection` 数据集；**训 5 类**（`porosity` 气孔 / `crack` 裂纹 / `undercut` 咬边 / `overlap` 焊瘤 / `unfused` 未融合）。笔记本自动下载→类别重映射（air-hole→porosity、crack→crack、bite-edge→undercut、overlap→overlap、unfused→unfused，兼容 YOLO/VOC 标注）→ `images/labels` 分离目录按文件名全局配对 → 8:2 划分 → 训 YOLOv8n → 导出 `.mlmodel`；**余高(excess_weld_metal) 由 App 内 LiDAR 几何计算、不进视觉模型**。用户无需任何 API Key，上传笔记本逐格运行即可。咬边仅 35 张、裂纹 119 张偏少，训练后重点看二者 recall。
