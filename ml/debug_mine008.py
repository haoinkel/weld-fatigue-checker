# -*- coding: utf-8 -*-
"""mine_008 单图验证：letterbox 预处理 + 复刻 Swift 解码链路（与修复后 App 一致）。"""
import numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

# 训练 7 类序（build_surface_notebook.py:107）
CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
# raw_mine 5 类序
RAW_MINE = ["porosity", "crack", "undercut", "overlap", "unfused"]
# App 校准后阈值（SurfaceDefectDetector.swift）
THRESH = {"porosity": 0.30, "crack": 0.30, "overlap": 0.25, "spatters": 0.30,
          "good_weld": 0.40, "undercut": 0.25, "unfused": 0.20}
NMS_IOU = 0.6
IMGSZ = 640
GRAY = 114

ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"
IMG  = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images/mine_008.jpg"
LAB  = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels/mine_008.txt"

img = Image.open(IMG); img = ImageOps.exif_transpose(img).convert("RGB")
W, H = img.size
scale = min(IMGSZ / W, IMGSZ / H)
lbW, lbH = int(round(W * scale)), int(round(H * scale))
offX, offY = (IMGSZ - lbW) // 2, (IMGSZ - lbH) // 2
canvas = Image.new("RGB", (IMGSZ, IMGSZ), (GRAY, GRAY, GRAY))
canvas.paste(img.resize((lbW, lbH), Image.BILINEAR), (offX, offY))
arr = np.asarray(canvas, dtype=np.float32) / 255.0
x = arr.transpose(2, 0, 1)[None].astype(np.float32)

sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
o = out[0] if out.ndim == 3 else out.T          # (11, 8400)
sc, co = o[4:11, :], o[0:4, :]

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    return ix*iy / (a[2]*a[3] + b[2]*b[3] - ix*iy) if (a[2]*a[3] + b[2]*b[3] - ix*iy) > 0 else 0.0

# 解码 + 分类阈值 + NMS + good_weld 过滤
cand = []
for a in range(o.shape[1]):
    b = int(np.argmax(sc[:, a])); s = float(sc[b, a])
    if b == 4 or s < THRESH[CLASS_NAMES[b]]:     # 4=good_weld 过滤
        continue
    cx, cy, w, h = co[0,a]/IMGSZ, co[1,a]/IMGSZ, co[2,a]/IMGSZ, co[3,a]/IMGSZ
    cand.append([s, b, [cx-w/2, cy-h/2, w, h]])
cand.sort(reverse=True)
keep = []
for c in cand:
    if all(c[0] > k[0] or iou(c[2], k[2]) < NMS_IOU for k in keep):
        keep.append(c)

# 逆映射回原图坐标
def to_orig(bx):
    px = (bx[0]*IMGSZ - offX) / scale; py = (bx[1]*IMGSZ - offY) / scale
    pw = bx[2]*IMGSZ / scale;          ph = bx[3]*IMGSZ / scale
    return px/W, py/H, pw/W, ph/H

gt = []
for line in open(LAB):
    p = line.split()
    if len(p) >= 5:
        gt.append((int(float(p[0])), float(p[1]), float(p[2]), float(p[3]), float(p[4])))

print(f"图像 {W}x{H}, letterbox scale={scale:.4f} offset=({offX},{offY})")
print(f"\nGT ({len(gt)} 框, raw_mine 5类序):")
for c, cx, cy, w, h in gt:
    print(f"  {RAW_MINE[c]:<10} cx={cx:.3f} cy={cy:.3f} w={w:.3f} h={h:.3f}")

print(f"\n预测 ({len(keep)} 个, 过阈值+NMS):")
matched = set()
for s, b, bx in keep:
    px, py, pw, ph = to_orig(bx)
    best, bi = 0.0, -1
    for i, (c, cx, cy, w, h) in enumerate(gt):
        v = iou(bx, (cx-w/2, cy-h/2, w, h))
        if v > best: best, bi = v, i
    tag = ""
    if best >= 0.5 and bi not in matched:
        tag = f"  <=> GT:{RAW_MINE[gt[bi][0]]} IoU={best:.2f} {'✅' if RAW_MINE[gt[bi][0]]==CLASS_NAMES[b] else '⚠️类不符'}"
        matched.add(bi)
    elif best >= 0.5:
        tag = f"  (重复匹配 GT:{RAW_MINE[gt[bi][0]]} IoU={best:.2f})"
    else:
        tag = "  (误报,无GT重合)" if best < 0.1 else f"  (定位偏差,最高IoU={best:.2f})"
    print(f"  conf={s:.3f} {CLASS_NAMES[b]:<10} x={px:.3f} y={py:.3f} w={pw:.3f} h={ph:.3f}{tag}")

missed = [RAW_MINE[c] for i,(c,_) in enumerate([(g[0],None) for g in gt]) if i not in matched]
missed = [RAW_MINE[g[0]] for i, g in enumerate(gt) if i not in matched]
print(f"\n漏检 GT: {missed if missed else '无 ✅'}")
