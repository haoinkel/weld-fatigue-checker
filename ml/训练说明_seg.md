# 实例分割(yolov8-seg)训练说明（优化点 B v2）

> 目标：把现有 5 类 **bbox 检测** 升级为 **实例分割(mask)**，使 `MetricSizer` 后续
> 可基于精确 mask（而非整框）采样 LiDAR 深度，提升缺陷公制尺寸精度。
> v1（当前已落地）用 bbox + 深度反投影即可得 mm，本说明为精度增强预留。

## 在 AI Studio 执行步骤

1. 准备分割标签（无需人工标 polygon，矩形 mask 即可 bootstrap）：
   - **AI Studio（notebook）**：上传并运行 `ml/prepare_seg_labels.ipynb`，在「配置区」单元格把 `SRC_DIR/DST_DIR` 改成你的路径后顺序执行。
   - **本地/有 bash**：`python ml/prepare_seg_labels.py --src ml/raw_mine/labels --dst ml/dataset_weld/labels_seg`
2. 按 `ml/yolov8n_seg_weld.yaml` 组织 `images/train|val` 与 `labels_seg`，**类别顺序不变**
   （porosity/crack/undercut/overlap/unfused）。
3. 训练（Ultralytics ≥8.0，用 `-seg` 预训练权重）：
   ```python
   from ultralytics import YOLO
   model = YOLO("yolov8n-seg.pt")
   model.train(data="ml/yolov8n_seg_weld.yaml", epochs=120, imgsz=640, batch=16, name="weld_seg_v1")
   model.export(format="coreml", nms=True, quantize="w8a16", imgsz=640)
   ```
4. 导出 `WeldDefectModel.mlpackage` 覆盖进 Xcode 工程（勾选 Target Membership）。
5. App 端 `MLDefectDetector.classNames` 保持 5 类不变；mask 输出由 `MetricSizer` 后续接入。

## 注意事项
- 矩形 mask 是 bootstrap：训练初期精度有限，建议后续用模型自预测伪标签或人工精修 polygon。
- 类别扩展为 7 类（加 solid_inclusion/spatter）时，同步改 `yolov8n_seg_weld.yaml` 的 `nc/names`
  与 App 端 `classNames`，否则 argmax 错位。
- 导出量化档唯一可用为 `w8a16`（INT8 权重 + 16-bit 激活，~3.1MB，跑 Neural Engine）。
