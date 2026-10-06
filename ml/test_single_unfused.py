# 单图测试：unfused4-20.jpg（未熔合），复刻 App 解码逻辑
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from local_onnx_verify import (sess, iname, preprocess, decode, load_gt,
                               CLASSES, THRESH, IMG_DIR, LBL_DIR)

base = "unfused4-20"
path = os.path.join(IMG_DIR, base + ".jpg")
assert os.path.exists(path), f"找不到 {path}"

x, geo, orig = preprocess(path)
out = sess.run(None, {iname: x})[0]
kept, raw = decode(out, geo, orig)

gt = load_gt(os.path.join(LBL_DIR, base + ".txt"))
# 原始数据集 8 类 → App 5 类映射（对齐 weld_train.py 'huangyebiaoke' 映射）
RAW8 = ["air-hole", "bite-edge", "broken-arc", "crack",
        "hollow-bead", "overlap", "slag-inclusion", "unfused"]
MAP8TO5 = {"air-hole": "porosity", "hollow-bead": "porosity", "crack": "crack",
           "bite-edge": "undercut", "overlap": "overlap", "unfused": "unfused",
           "broken-arc": "(丢弃)", "slag-inclusion": "(丢弃)"}

print(f"图片: {path}")
print(f"原图尺寸: {orig[0]}x{orig[1]}")
print(f"\n=== 真值标注（原始8类 → App5类）===")
for c, gr in gt:
    print(f"  {RAW8[c]} → {MAP8TO5[RAW8[c]]}  box={gr}")

print(f"\n=== 检测结果（App 标准档阈值，NMS 0.6）===")
if not kept:
    print("  无框通过阈值")
for rect, cls, sc in kept:
    print(f"  {cls}: 分数 {sc:.3f}（阈值 {THRESH[cls]}）  box={rect}")

print(f"\n=== 前 10 个最高分原始候选（诊断用，含未过阈值）===")
for cls, sc in raw[:10]:
    print(f"  {cls}: {sc:.3f}")
