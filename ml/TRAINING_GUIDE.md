# WeldFatigueChecker 阶段1：Create ML 实例分割训练指南

目标：用公开焊缝**表面缺陷**数据集训练一个实例分割模型，替换阶段0 的纯 CV 启发式
检测（重点解决「弧坑裂纹」漏报/误报），并把模型推理结果直接接入 `ISO5817Grader.swift`
做 ISO 5817 等级判定。M5 的 Neural Engine 可在设备端实时推理。

---

## 0. 整体链路（复习）

```
相机帧 / 照片
   │
   ├─ 阶段0 CV 规则（已在 App）──────┐
   │                                 ▼
   └─ 阶段1 Core ML 实例分割模型 ──> 缺陷掩膜(像素级) ──> 量尺寸(mm)
                                                                 │
                                          LiDAR 余高/咬边深度 ────┤
                                                                 ▼
                                                           ISO5817Grader.grade()
                                                                 │
                                                                 ▼
                                                  等级 B/C/D + 合格性 + 报告
```

模型只取代「找缺陷位置+分类」，尺寸→等级的判定逻辑复用已有 `ISO5817Grader`。

---

## 1. 数据集获取（表面域优先，X光仅补充）

| 数据集 | 域 | 许可 | 格式 | 类别（映射到 App type） |
|---|---|---|---|---|
| **Kaggle Surface Weld Defect (Crack, Porosity, Spatter)** | 表面可见光 | MIT | YOLO, 800×800 | Crack→`crack`, Porosity→`porosity`, Spatter→`excess_weld_metal` |
| **Kaggle Weld Quality Inspection - Instance Segmentation** | 表面可见光 | CC0 | YOLO-Seg | Crack/Excess Reinforcement/Porosity/Spatters→上述；Bad/Good Welding 默认跳过 |
| **Roboflow Metal Welding Defects** | 表面可见光 | 视集 | YOLOv8 | 按实际类名映射 |
| GDXray / NEU-DET(CR) | **X 光/DR** | 学术 | 多变 | ⚠️ 域不同，仅作 fine-tune 补充，需标注域差异 |

> ⚠️ **域差异风险**：X 光/DR 图像与 iPad 拍的表面可见光是不同分布。直接拿 X 光模型
> 跑表面图会明显掉点。建议**表面集预训练 + 少量表面真值 fine-tune**；X 光集只用于
> 扩充裂纹等难样本，且训练时混合比例控制在 <20%，并在表面验证集上评估。

### 下载示例（Kaggle，需 `kaggle` CLI 或网页）
```bash
# 安装: pip install kaggle && 配置 ~/.kaggle/kaggle.json
kaggle datasets download -d benyaminrazaziyan/surface-weld-defect-dataset-crak-porosityspatter
unzip surface-weld-defect-dataset-crak-porosityspatter.zip -d ~/datasets/surface_weld
```

---

## 2. 转换为 Create ML 格式

脚本：`ml/prepare_dataset.py`（纯标准库，bitmap 模式才需 Pillow）。

```bash
# YOLO 表面集（800×800 同尺寸，省去读图）
python3 ml/prepare_dataset.py --source yolo \
    --root ~/datasets/surface_weld \
    --names obj.names --img-size 800 800 \
    --out ./createml_weld --splits train valid test

# COCO 实例分割集
python3 ml/prepare_dataset.py --source coco \
    --root ~/datasets/weld_quality_inspection \
    --out ./createml_weld --splits train valid

# 自定义映射（覆盖/补充默认映射）
python3 ml/prepare_dataset.py --source yolo --root ... --names names.txt \
    --map "Crater Crack:crack,Bad Welding:undercut" --out ./createml_weld
```

输出结构（Create ML 可直接读）：
```
createml_weld/
  images/train/*.jpg      images/valid/*.jpg
  annotations/train/*.json annotations/valid/*.json   # 每图一个 unified JSON
  class_labels.txt         # 标签 = App 缺陷 type（crack/porosity/excess_weld_metal/...）
```

脚本会把数据集类名**自动映射**到 App 内部 type（`DEFAULT_MAP` 见脚本头部），未映射类
默认跳过（Good Welding 等）。映射后标签写入 `class_labels.txt`，训练时必须原样填入模型。

---

## 3. 训练（Create ML，Xcode 26 / macOS）

两种方式任选其一：

### A. Create ML app（GUI，推荐，无需写训练代码）
1. 打开 Xcode → `Open Developer Tool` → **Create ML**。
2. 新建项目 → 选 **Instance Segmentation** 模板 → 填项目名/作者。
3. Training Images 选 `createml_weld/images/train`，Annotations 选 `createml_weld/annotations/train`。
4. Validation Images/Annotations 选 `valid` 对应目录。
5. 标签（Labels）导入 `createml_weld/class_labels.txt`。
6. 设超参（起步建议）：epochs 40、batch 自动、backbone 默认（MobileNet 类轻量，
   适合端侧）；若显存/内存够可试 ResNet50 提精度。
7. 点 Train。实时监控 loss 与 **mAP**（实例分割常用 mAP@0.5 / mAP@0.5:0.95）。
8. 训练完 **Preview** 拖几张验证图看掩膜效果；满意后 `Get` 导出 `.mlmodel`。

### B. mlmodelc（命令行，CI 友好）
用 `coremltools` + `CreateML` Python API（macOS）：
```python
import coremltools as ct
from coremltools.models import MLModel
# Create ML 的实例分割可用 ct.converters 或 CreateML 框架的 MLInstanceSegmentation
# 具体见 Apple 文档；本环境无 Mac，命令仅作提示，请在 Mac 上执行。
```

---

## 4. 评估指标

- **mAP@0.5**：掩膜 IoU≥0.5 算命中，主看指标。
- **mAP@0.5:0.95**：更严格，COCO 标准。
- 每类分别看（尤其 `crack` 弧坑裂纹——难样本，关注召回率 recall，漏报比误报更危险）。
- 目标：表面验证集 mAP@0.5 ≥ 0.85 再考虑上机替换 CV 规则。

---

## 5. 接入 App（替换 CV 规则，保留 LiDAR）—— 已落地

> ⚠️ **路线已切换为 YOLOv8 检测**（训练见 `ml/CLOUD_TRAINING.md`），不再是 Create ML 实例分割。
> `MLDefectDetector.swift` 已重写为解析 YOLOv8 + NMS 的 Core ML 双输出（`coordinates`/`confidence`），
> 加载走 Neural Engine（`cpuAndNeuralEngine`），保留 ROI 闸门与 LiDAR 余高路线不变。以下接入步骤按 YOLOv8 为准。
>
> 阶段2 代码已写入工程：`app_ios/native/WeldFatigueChecker/MLDefectDetector.swift`，
> 并在 `Views/PhotoCheckView.swift` 增加了「使用 AI 模型识别」开关（默认开）。
> 下面是把训练好的模型接进 App 的最后一步。

---

### 5.0 扩充样本：多源合并 + 增强（下次重训必读）

**本次训练聚焦 MAG 焊接工艺**：优先采用 MAG/GMAW 焊道可见光数据。LoHi-WELD（源3）即 MAG 机器人焊道集，是 MAG 聚焦的**首选补充源**；huangyebiaoke（源1）为基础源，工艺未明，作为通用兜底。

当前模型最弱的是 **crack(119)** 与 **undercut(35)** 两个少数类，iPad 实测 recall 风险最大。
`ml/weld_train.py` 已改为**多源合并**，重训时自动把多个数据集统一映射成 5 类 YOLO，
任一源缺失即跳过（单源也能训）。

**数据源（必须是表面可见光，X 射线/RT 一律排除）：**

| 源 | 目录 | 获取方式 | 类别映射 | 许可 |
|---|---|---|---|---|
| 1. huangyebiaoke/steel-pipe-weld-defect-detection | `raw/` | 脚本自动 ghproxy 下载 | air-hole→porosity, crack→crack, bite-edge→undercut, overlap→overlap, unfused→unfused | — |
| 2. JIAN SONG「焊接缺陷」(Roboflow) | `raw_jian/` | **手动**：Roboflow 导出 YOLO zip → 分卷上传 AI Studio 解压到此 | 咬bian/咬边→undercut, 气孔→porosity, 焊瘤→overlap, 裂纹→crack | Public Domain |
| 3. **LoHi-WELD (MAG 聚焦首选源, IEEE Access 2024, GMAW/MAG 机器人焊道可见光, 3022张)** | `raw_lohi/` | **AI Studio 云端 gdown**：`gdown 1pXeEnREfV_MYcL5MY2vkd9njBm_blPUK -O raw_lohi.zip && unzip -o raw_lohi.zip -d raw_lohi`（本地/沙箱被墙 502，须在训练环境内执行）；有则启用，无则跳过 | pores→porosity, deposits→overlap, discontinuities→unfused, stains→丢弃 | 免费可商用(须引用) |
| 4. kunkun-vhmx2/weld (Roboflow) | `raw_kunkun/` | **手动**：Roboflow 导出 YOLO zip → 分卷上传 AI Studio 解压到此；精细5类，直接补 crack | Crack→crack, Lack Of Fusion→unfused, Lack Of Penetration→unfused, Porosity→porosity, Slag Inclusion→丢弃 | CC BY 4.0 |

> ⚠️ 已**剔除**的候选（不可靠/不可下/不兼容）：
> - `graylin2025/datasets_sl` 只是数据集**索引页**，焊接条目托管在 mbd.pub 网盘，无类名、无法确认可见光 → 无法用 ghproxy 自动化下载。
> - `QQ767172261/...6000-sheets` 仓库**只有训练代码、不含真实数据**（6000 图需另下，且未确认可见光）。
> - `weld-defects-mlopr`（Roboflow, 5198图）仅 **3 粗类 Defect/Bad Weld/Good Weld**，无法细分到 crack/undercut 等5类，对精细模型几乎零增益 → 排除。
> - `Welding Data Set v3`（Roboflow）标注为 **Semantic Segmentation（分割 mask）**，非 YOLO 检测框，直接喂入会生成错误框 → 排除（除非另写 seg→bbox 转换）。
> - **Roboflow 整站在国内被墙**（账号/网页打不开、下载端点 403，2026-09-26 核实）：故 `JIAN SONG`、`kunkun` 两个 Roboflow 源在无代理/VPN 时**均无法下载**。
> - **Google Drive 同样被墙**（本地与沙箱均 502 隧道失败）：故 LoHi-WELD 数据无法从本机/沙箱拉取，只能在【AI Studio 云端】用 `gdown` 绕过（文件ID `1pXeEnREfV_MYcL5MY2vkd9njBm_blPUK` = 图像集）。
> - **HuggingFace 也被墙（502）**：HF 上的焊接集（如 `rikkarth/welding-defect-object-detection`、`jparedesDS/...`）即便可达也多为粗类(Defect/Good/Bad Weld)，无法细分到5类 → 不采用。
> - **Kaggle 焊接集不匹配**：搜到的只有 `Severstal`（钢板表面缺陷、RLE 分割掩码格式、非焊道），其余多为 X 射线；无干净的 MAG 焊道可见光检测集 → 不采用。
> - `firc-dataset` 等"免费"焊接集实为 mbd.pub/CSDN 付费引流、仓库不含真实数据。当前网络下**没有免费可达的可见光裂纹数据集可本机下载**。

**内置增强（零外源依赖，当前唯一确定可用的补强手段）：**
- 训练 `copy_paste=0.2`（Ultralytics 原生）：把缺陷 cutout 随机贴到干净焊道背景，对少数类最有效。
- 训练集对 `crack`/`undercut` **过采样**到中位类数量（复制含该类框的图片）。
- 验证集保持原始分布（仅训练集增广），避免指标虚高。
- **结论**：无代理时直接 `%run weld_train.py`（仅 源1 + 内置增强）即可。若想引入 MAG 数据，**优先在 AI Studio 内用 `gdown` 拉 LoHi-WELD**（见源3），其余 Roboflow 源需代理/VPN 才能放下 `raw_jian/`/`raw_kunkun/`。

**重训步骤：** 把更新后的 `ml/weld_train.py` 上传 AI Studio（或复用 `work/`），
按需把 JIAN SONG / LoHi-WELD / kunkun 解压到 `raw_jian/` / `raw_lohi/` / `raw_kunkun/`，`%run weld_train.py` 即可；
训练完自动导出 `WeldDefectModel.mlpackage`（注意用 `model` 当前指向的带编号权重，勿硬编码旧目录）。

---

1. **导出模型文件名必须为 `WeldDefectModel.mlpackage`**（与 `MLDefectDetector.modelFileName` 一致）。
   把它放到 `WeldFatigueChecker/` **根目录**（不要放进 `Resources/`，Resources 是 folder reference 不编译内部）。
   `tools/gen_xcodeproj.py` 会自动把它作为编译资源引用，Xcode 编译后包内生成 `WeldDefectModel.mlmodelc`，
   运行时由 `compiledModelURL` 找到。若改了文件名，改 `MLDefectDetector.swift` 顶部 `modelFileName` 对应即可。
2. `MLDefectDetector.detect(in:)` 已与 `PhotoDefectDetector.detect` **同接口同返回**
   （`[DetectedDefect]`），`PhotoCheckView.autoAnnotate` 已改为调用它 —— 上层零改动。
   模型缺失/推理抛错时**自动回退 CV 规则**，因此未放模型也能正常跑（此时开关显示「未加载→CV」）。
3. **模型输出解析（YOLOv8 + nms=True 导出的 Core ML 双输出，已重写 `MLDefectDetector.runModel` 接住）**：
   - `coordinates`：检测框坐标（MLMultiArray [M, 4]），归一化 `[x_center, y_center, width, height]`，范围 0..1。
   - `confidence`：类分数（MLMultiArray [M, num_classes]），取 argmax 作为类别与分数，低于
     `MLDefectDetector.confidenceThreshold`(默认 0.45) 丢弃。NMS 已在模型内完成，runModel 不再重复。
   - 类别顺序必须与训练 `data.yaml` 的 `names` 一致：`['porosity','crack','undercut','overlap','unfused']`
     （argmax 索引 0..4 直接对应，见 `MLDefectDetector.classNames`）。
   - 类名 → App type 的映射见 `MLDefectDetector.labelMap`（已含 `porosity/crack/undercut/overlap/unfused`
     及常见同义名如 `pore/air-hole/crater_crack/bite-edge/lack_of_fusion`）。余高 `excess_weld_metal`
     由 LiDAR 单独算，不进视觉模型。
4. **LiDAR 余高/咬边深度路线保持不变**（`WeldProfileAnalyzer` + `LiDARWeldScanSheet`），
   模型只负责缺陷有无/分类/平面尺寸，不负责高度量测。

---

## 6. 重打包与侧载验证

1. commit 改动到 GitHub → CI（`.github/workflows/build_ipa_sideload.yml` 调 `build.sh ipa`，已含资源平铺）重打包出新 IPA。
2. Sideloadly 侧载 v6 覆盖 v5（同 bundle id，图标保留，数据自动更新）。
3. iPad 上打开 App → 拍照/选图 → 验证自动框出气孔/咬边/裂纹并显示等级。
4. 免费签名 7 天有效，保持 iTunes/Finder Wi-Fi 同步自动续签。

---

## 7. 实时预览识别（LiveScanView）—— 已落地

> 阶段2 延伸：把「选照片」升级为「相机实时预览识别」。代码已写入：
> `RealtimeDefectScanner.swift`（相机会话 + 逐帧检测）与 `Views/LiveScanView.swift`（预览叠层 + 捕获），
> 并在 `PhotoCheckView` 增加「🎥 实时扫描识别」按钮（任意带摄像头设备可用，不依赖 LiDAR）。

- **链路**：`AVCaptureSession` 取后置广角摄像头帧 → 节流到约 6~7 fps → `UIImage` → 调
  `MLDefectDetector.detect(in:)`（与照片检测同一入口，有模型走 AI、无模型走 CV 回退）。
- **实时叠加**：归一化检测框 + App type 经 aspectFill 映射叠在 `AVCaptureVideoPreviewLayer` 上，
  竖屏 `videoOrientation = .portrait` 保证预览与框对齐。
- **捕获**：点「📸 捕获快照」把当前帧与缺陷写入 `store.vision.imperfections`（自动框），
  自动回到「外观检查」——此时**尺寸仍是像素**，需「📏 标定比例」或 LiDAR 点测得到真实 mm，
  再触发 ISO 5817 评级（同照片流程，零改动）。
- 引擎开关（AI/CV）、模型加载态、FPS 实时显示；相机权限缺失会提示去设置开启。
- ⚠️ 实时模式默认**不评级**（无参照比例，mm 未知）；评级在捕获后的照片流程完成。
  若需实时直接评级，需给实时模式接入「已知工作距离的像素/mm 比例」（相机内参 + 工作距离），
  当前未实现——需求明确时可再加。

---

## 8. 风险提示

- 训练数据若以公开集为主，模型对**你现场真实工件**的分布可能漂移，建议补充 50~200 张
  自有样本 fine-tune（用 LabelMe/CVAT 标注，再跑本脚本转换）。
- 裂纹检测对光照/角度敏感，现场务必稳定打光、垂直拍摄。
- 模型结论是**辅助判定**，最终验收须由持证人员按 ISO 5817 结合无损检测确认。
