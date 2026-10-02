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

**当前训练方案（已写入 `colab_train_weld.ipynb`）**：Roboflow 被墙，从 GitHub Release 直连 `steel-pipe-weld-defect-detection` 数据集；**训 5 类**（`porosity` 气孔 / `crack` 裂纹 / `undercut` 咬边 / `overlap` 焊瘤 / `unfused` 未融合）。笔记本自动下载→类别重映射（air-hole→porosity、crack→crack、bite-edge→undercut、overlap→overlap、unfused→unfused，兼容 YOLO/VOC 标注）→ `images/labels` 分离目录按文件名全局配对 → 8:2 划分 → 训 YOLOv8n → 导出 `.mlmodel`；**余高(excess_weld_metal) 由 App 内 LiDAR 几何计算、不进视觉模型**。用户无需任何 API Key，上传笔记本逐格运行即可。咬边仅 35 张、裂纹 119 张偏少，训练后重点看二者 recall。另：仓库内 `ml/raw_mine/`（用户实拍现场图，已 5 类手标）已作为**源5 自动并入** `weld_train.py` —— 整库上传到 AI Studio（work/ 下即 `ml/raw_mine`）即生效，无需外部网络，重点补 undercut 与现场光照鲁棒性；其 md5 切分、少数类过采样与 CoreML 导出逻辑同其它源。验证集 mAP@0.5 ≥ 0.85（气孔）再下载 `WeldDefectModel.mlpackage`。

---

## 实跑命令与续训流程（多源合并 `weld_train.py`）

> 本脚本把 **源1~4（即 120 轮当年的训练数据）+ 源5 raw_mine（自采 40 张）+ 以后新增数据** 合并成同一份 `dataset/data.yaml`，再训练。三条入口对应不同"权重起点 / 数据"组合。

### ① 推荐：基于 120 权重 + 把 40 张自采 + 后续新增一并训练

```bash
# 把 120 轮留下的检查点（last.pt / best.pt / 备份的 weld_defect_5cls_last_backup.pt）上传到 AI Studio work/ 后：
cd /home/aistudio/work
python weld_train.py --init-from weld_defect_5cls_last_backup.pt
```

- `--init-from` **只借用权重**，训练数据强制以**本次脚本重新合并的数据集**为准（含 raw_mine + 之后新增），绝不会被旧 `args.yaml` 绑死；
- 满足："120 + 40 + 后续补充"全部进训练，且都导出进 `WeldDefectModel.mlpackage`。

### ② 加数据后续训（最常用，无需记路径）

以后把新图丢进 `ml/raw_mine/images/` + 同名标签 `ml/raw_mine/labels/`（或新建 `raw_mine2/` 等源也行，加到 `weld_train.py` 的 `SOURCES`），**直接重跑**：

```bash
python weld_train.py        # 无 --fresh/--init-from/--resume 时，自动借上次 last.pt 权重，在含新数据的新数据集上从 0 轮训
```

- 默认"自动续训"分支 = 借上次 `last.pt` 权重 + **当前新合并数据集**，自动吃到新数据；
- raw_mine 接口长期开放：继续往里丢图即并入，不用改任何代码。

### ③ 同份数据中途被踢（仅原样续跑，勿加新数据时用）

```bash
python weld_train.py --resume     # 沿用旧 run 的 epochs/优化器/原 data 路径
```

- ⚠️ 若上次 run 是在 raw_mine 接入**之前**跑的，`--resume` 会**漏掉 raw_mine**——此时改用 ①②。

### ④ 彻底重来（从 COCO 预训练，不继承任何权重）

```bash
python weld_train.py --fresh      # 清旧 runs，从 yolov8n.pt 全新训 120 轮；数据仍含全部源 + raw_mine
```

### ⏱ 省时：避免把 120 原始数据重训几小时

`--init-from`（①）默认会在**合并全数据（含 120 原始数据）**上跑满 `TOTAL_EPOCHS=120` 轮，AI Studio 免费 GPU 上要几小时。若只想"把 40 张自采图快速并进模型、不想花几小时重训 120 原始数据"，用下面两个省时开关：

```bash
# 方案 A（省时且质量稳）：仍在全数据上，但只训 40 轮（起点已是 120 收敛点，足够融 40 新图 + 保旧知识）
python weld_train.py --init-from weld_defect_5cls_last_backup.pt --epochs 40

# 方案 B（最快，数十分钟级）：只用 raw_mine 40 张自采图、低学习率微调，完全不碰 120 原始数据
python weld_train.py --init-from weld_defect_5cls_last_backup.pt --finetune --epochs 30
```

- `--epochs N`：覆盖训练轮数（默认 120）。任何入口（①/②/④）都可加；
- `--finetune`：仅用 `raw_mine` 自采数据，自动清空旧 `dataset/` 避免残留源1~4，并把 `lr0` 降到 `1e-3` 保护 120 权重；
- 质量权衡：方案 B 最快，但 40 图偏少、可能轻微过拟合到自采图背景，**建议配合 `--epochs 30`**；正式上线前若追求最优 map，仍走 ① 全量 120 轮（或方案 A 折中）。
- 后续补数据：再往 `ml/raw_mine/` 丢图后，重跑 `--finetune --epochs 30` 即可增量微调，无需重训历史数据。

### 🔁 持续学习：每次只训新增图，历史绝不重跑（推荐长期用法）

`--finetune`（上段）只在 `raw_mine` 自采库上训，虽不碰源1~4，但 `raw_mine` 会随补图变大、旧自采图仍被反复训。若要做到"**历史数据（120 原始 + 已训自采）一次都不重跑**"，用持续学习模式：

```bash
# 第一次（无 manifest）：把 120 原始数据 + 当前自采一次性全训，建立基线（可加 --epochs 120 求最优）
python weld_train.py --incremental --init-from weld_defect_5cls_last_backup.pt --epochs 120

# 之后每次补图：只训【新增图】+ 抽 ≤200 张历史图回放防遗忘，权重自动继承上次 last.pt
python weld_train.py --incremental
```

- 机制：维护 `dataset/.trained_manifest.txt` 记录已训图；本轮只把新增图进训练，并从历史图随机抽 ≤`REPLAY_CAP`(200) 张回放（防灾难性遗忘），源1~4 与已训自采**不再全量重跑**；
- 权重链：`120.pt` → 首次 `--incremental` 全训 → `last.pt` → 后续 `--incremental` 只训新增 → `last.pt` …… 历史越积越多但**每张只训一次**；
- 默认轮数降至 30（`--epochs` 可改），数十分钟级；
- ⚠️ 想"彻底重排所有历史"：删 `dataset/.trained_manifest.txt` 再跑 `--incremental` 即回到全量一次性；不要把 `dataset/` 整个删了（会丢 manifest 导致无法识别新增）。

### 断点备份（防 AI Studio 被杀）

- 每个 epoch 末自动备份 `last.pt` → `/home/aistudio/work/weld_defect_5cls_last_backup.pt`；
- 用 Notebook 侧边「下载文件」存本机兜底；若 `work/` 被清，重新上传该备份为 `runs/detect/weld_defect_5cls/weights/last.pt` 再跑即无缝续训；
- 该备份文件本身也是 `--init-from` 的好来源（即"基于上次权重继续"）。

### 你手上 120 权重在哪？

- 若 AI Studio `work/` 没被清：`runs/detect/weld_defect_5cls*/weights/last.pt` 或 `best.pt` 直接拿来 `--init-from`；
- 若当时按备份提示下载过：`weld_defect_5cls_last_backup.pt`；
- **都没有**：只能走 ④ `--fresh`（数据仍含 120 当年的全部源 + raw_mine，只是权重不继承 120；或以后找回 120 的 .pt 再 `--init-from` 补训）。
