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

> 阶段2 代码已写入工程：`app_ios/native/WeldFatigueChecker/MLDefectDetector.swift`，
> 并在 `Views/PhotoCheckView.swift` 增加了「使用 AI 模型识别」开关（默认开）。
> 下面是把训练好的模型接进 App 的最后一步。

1. **导出模型时文件名必须为 `WeldDefectModel.mlmodel`**（与 `MLDefectDetector.modelFileName` 一致）。
   拖入 Xcode 工程、勾选 Target Membership（Copy Bundle Resources），Xcode 编译后包内生成
   `WeldDefectModel.mlmodelc`。
   - ⚠️ 代码用**通用 `MLModel(contentsOf:)` + Vision `VNCoreMLRequest`** 加载，**不依赖** Xcode
     自动生成的 `WeldDefectModel.swift` 包装类，所以标签名/字段名以模型实际输出为准（见第 3 步）。
   - ⚠️ 若你导出时用了别的文件名，改 `MLDefectDetector.swift` 顶部 `private static let modelFileName`
     与之对应即可。
2. `MLDefectDetector.detect(in:)` 已与 `PhotoDefectDetector.detect` **同接口同返回**
   （`[DetectedDefect]`），`PhotoCheckView.autoAnnotate` 已改为调用它 —— 上层零改动。
   模型缺失/推理抛错时**自动回退 CV 规则**，因此未放模型也能正常跑（此时开关显示「未加载→CV」）。
3. **模型输出字段必须匹配**（Create ML Instance Segmentation 标准三件套）：
   - `confidence`：实例分数（MLMultiArray [N]），低于 `MLDefectDetector.confidenceThreshold`(默认0.5) 丢弃。
   - `label`：类别索引（MLMultiArray [N]，映射到 `model.modelDescription.classLabels`）或字符串序列。
   - `mask`：概率掩膜（MLMultiArray [N, H, W]，>0.5 取像素），代码由掩膜算 bbox 与像素尺寸。
   - 类别名 → App type 的映射见 `MLDefectDetector.labelMap`（key 含
     `undercut/porosity/excess_weld_metal/crack/overlap/linear_misalignment` 及常见同义名）。
4. **LiDAR 余高/咬边深度路线保持不变**（`WeldProfileAnalyzer` + `LiDARWeldScanSheet`），
   模型只负责缺陷有无/分类/平面尺寸，不负责高度量测。

> 注意：训练时填入 Create ML 的标签名必须等于 `class_labels.txt`（= App type 名），否则
> `labelMap` 匹配不到，检测出的缺陷会变成 `defect` 而无法评级。

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
