# -*- coding: utf-8 -*-
"""检查 WeldDefectModel.mlpackage 的输入/输出描述，验证 App 端解析假设。"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

import coremltools as ct
from coremltools.models import MLModel

PATH = r"D:\workbuddy\workbuddy学习\weld_fatigue_checker\app_ios\native\WeldFatigueChecker\WeldDefectModel.mlpackage"

m = MLModel(PATH)
spec = m.get_spec()

print("===== 模型描述 =====")
print("描述:", (spec.description.metadata.shortDescription or "")[:120])

print("\n===== 输入 =====")
for inp in spec.description.input:
    t = inp.type
    if t.WhichOneof("Type") == "imageType":
        print(f"  {inp.name}: image {t.imageType.width}x{t.imageType.height}")
    elif t.WhichOneof("Type") == "multiArrayType":
        shape = list(t.multiArrayType.shape)
        print(f"  {inp.name}: multiArray shape={shape}")
    else:
        print(f"  {inp.name}: {t.WhichOneof('Type')}")

print("\n===== 输出 =====")
for out in spec.description.output:
    t = out.type
    w = t.WhichOneof("Type")
    if w == "multiArrayType":
        shape = list(t.multiArrayType.shape)
        print(f"  {out.name}: multiArray shape={shape} (shapeRangeUnknown={t.multiArrayType.ShapeRange.isEnumeration if t.multiArrayType.HasField('ShapeRange') else 'n/a'})")
    else:
        print(f"  {out.name}: {w}")

print("\n===== pipeline 结构（若为 NMS pipeline）=====")
try:
    for i, p in enumerate(spec.pipeline.models):
        k = p.WhichOneof("Type")
        extra = ""
        if k == "customModel":
            extra = f" custom={p.customModel.className}"
        elif k == "neuralNetwork":
            extra = " neuralNetwork"
        print(f"  [{i}] {k}{extra}")
        # NMS 节点的参数
        nms = None
        try:
            if p.HasField("nonMaximumSuppression"):
                nms = p.nonMaximumSuppression
        except Exception:
            pass
        if nms is not None:
            print(f"      NMS: iouThresh={nms.iouThreshold} confThresh={nms.confidenceThreshold} \
classLabels={'yes' if nms.HasField('classLabels') else 'no'}")
except AttributeError:
    print("  (非 pipeline，单模型)")

print("\n===== 分类标签（若内嵌）=====")
for out in spec.description.output:
    t = out.type
    if t.WhichOneof("Type") == "dictionaryType":
        print(f"  {out.name}: dictionary")

# 输出 shape 的 range（flexible shape 时 default shape 可能为空）
print("\n===== 输出 shapeRange（若有）=====")
for out in spec.description.output:
    t = out.type
    if t.WhichOneof("Type") == "multiArrayType" and t.multiArrayType.HasField("ShapeRange"):
        sr = t.multiArrayType.ShapeRange
        sizes = []
        for d in sr.size:
            lb = list(d.lowerBound) if d.HasField("lowerBound") else []
            ub = list(d.upperBound) if d.HasField("upperBound") else []
            sizes.append(f"[{lb}..{ub}]" if lb or ub else "[?]")
        print(f"  {out.name}: {sizes}")
