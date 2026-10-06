# -*- coding: utf-8 -*-
"""单图诊断：ONNX 裸输出数值 + 两种解码（raw vs sigmoid）+ 与 GT 比对。"""
import os, json, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"
IMG  = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images/mine_001.jpg"
LAB  = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels/mine_001.txt"
IMGSZ = 640

img = Image.open(IMG); img = ImageOps.exif_transpose(img).convert("RGB")
W, H = img.size
arr = np.asarray(img.resize((IMGSZ, IMGSZ), Image.BILINEAR), dtype=np.float32) / 255.0
x = np.expand_dims(arr.transpose(2,0,1), 0).astype(np.float32)

sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
print("ONNX out shape:", out.shape)
# 归一成 (11, 8400)
if out.ndim == 3:
    o = out[0]
elif out.ndim == 2 and out.shape[0] == 8400:
    o = out.T
else:
    o = out
print("工作矩阵 shape:", o.shape, "(期望 11 x 8400)")
coords = o[0:4, :]; scores = o[4:11, :]
print(f"coords: min={coords.min():.3f} max={coords.max():.3f}  -> {'(0-640 像素)' if coords.max()>1.01 else '(已是归一化?!)'}")
print(f"scores: min={scores.min():.4f} max={scores.max():.4f}  -> {'(logits,需sigmoid)' if scores.max()>1.01 else '(已是概率 [0,1])'}")

# 读 GT
gt = []
if os.path.exists(LAB):
    for line in open(LAB):
        p = line.split()
        if len(p) >= 5:
            gt.append((int(float(p[0])), float(p[1]), float(p[2]), float(p[3]), float(p[4])))
print(f"\nGT ({len(gt)} 框):")
for c, cx, cy, w, h in gt:
    print(f"  {CLASS_NAMES[c]:<10} x={cx-w/2:.3f} y={cy-h/2:.3f} w={w:.3f} h={h:.3f}")

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    inter = ix*iy
    uni = a[2]*a[3] + b[2]*b[3] - inter
    return inter/uni if uni > 0 else 0.0

def decode(apply_sigmoid):
    sc = 1/(1+np.exp(-scores)) if apply_sigmoid else scores
    cand = []
    for a in range(o.shape[1]):
        col = sc[:, a]; b = int(np.argmax(col)); bs = float(col[b])
        if bs <= 0.01: continue
        cx, cy, w, h = coords[0,a]/IMGSZ, coords[1,a]/IMGSZ, coords[2,a]/IMGSZ, coords[3,a]/IMGSZ
        cand.append((bs, b, (cx-w/2, cy-h/2, w, h)))
    cand.sort(reverse=True)
    return cand[:10]

for flag, name in [(False, "raw(当概率, 与Swift一致"), (True, "sigmoid(logits)")]:
    print(f"\n===== 解码方式: {name} =====")
    top = decode(flag)
    if not top:
        print("  无任何候选 (score<=0.01)")
        continue
    for bs, b, box in top[:10]:
        match = ""
        for c, cx, cy, w, h in gt:
            i = iou(box, (cx-w/2, cy-h/2, w, h))
            if i > 0.5:
                match = f" <=> GT:{CLASS_NAMES[c]} IoU={i:.2f}"
                break
        print(f"  {bs:.3f} {CLASS_NAMES[b]:<10} x={box[0]:.3f} y={box[1]:.3f} w={box[2]:.3f} h={box[3]:.3f}{match}")
