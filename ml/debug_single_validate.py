# -*- coding: utf-8 -*-
"""通用单图验证：letterbox + 复刻 Swift 解码（与修复后 App 一致）。用法:
python debug_single_validate.py <image> <label> <vis_out>"""
import sys, numpy as np
from PIL import Image, ImageOps, ImageDraw
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
RAW_MINE = ["porosity", "crack", "undercut", "overlap", "unfused"]
THRESH = {"porosity": 0.30, "crack": 0.30, "overlap": 0.25, "spatters": 0.30,
          "good_weld": 0.40, "undercut": 0.25, "unfused": 0.20}
NMS_IOU, IMGSZ, GRAY = 0.6, 640, 114
ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"

IMG, LAB, OUTV = sys.argv[1], sys.argv[2], sys.argv[3]
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])

img = ImageOps.exif_transpose(Image.open(IMG)).convert("RGB")
W, H = img.size
scale = min(IMGSZ/W, IMGSZ/H)
lbW, lbH = int(round(W*scale)), int(round(H*scale))
offX, offY = (IMGSZ-lbW)//2, (IMGSZ-lbH)//2
canvas = Image.new("RGB", (IMGSZ, IMGSZ), (GRAY, GRAY, GRAY))
canvas.paste(img.resize((lbW, lbH), Image.BILINEAR), (offX, offY))
x = (np.asarray(canvas, np.float32)/255.0).transpose(2,0,1)[None].astype(np.float32)

o = sess.run(None, {sess.get_inputs()[0].name: x})[0]
o = o[0] if o.ndim == 3 else o.T
sc, co = o[4:11,:], o[0:4,:]

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    u = a[2]*a[3] + b[2]*b[3] - ix*iy
    return ix*iy/u if u > 0 else 0.0

cand = []
for a in range(o.shape[1]):
    b = int(np.argmax(sc[:,a])); s = float(sc[b,a])
    if b == 4 or s < THRESH[CLASS_NAMES[b]]:
        continue
    cx, cy, w, h = co[0,a]/IMGSZ, co[1,a]/IMGSZ, co[2,a]/IMGSZ, co[3,a]/IMGSZ
    cand.append([s, b, [cx-w/2, cy-h/2, w, h]])
cand.sort(reverse=True)
keep = []
for c in cand:
    if all(c[0] > k[0] or iou(c[2], k[2]) < NMS_IOU for k in keep):
        keep.append(c)

gt = []
try:
    for line in open(LAB):
        p = line.split()
        if len(p) >= 5:
            gt.append((int(float(p[0])), float(p[1]), float(p[2]), float(p[3]), float(p[4])))
except FileNotFoundError:
    pass

print(f"图像 {W}x{H}, scale={scale:.4f} offset=({offX},{offY})")
print(f"GT ({len(gt)} 框):")
for c, cx, cy, w, h in gt:
    print(f"  {RAW_MINE[c]:<10} cx={cx:.3f} cy={cy:.3f} w={w:.3f} h={h:.3f}")

vis = img.copy()
if max(W, H) > 2000:
    vis = vis.resize((W//2, H//2)); W2, H2 = vis.size
else:
    W2, H2 = W, H
dr = ImageDraw.Draw(vis)
for c, cx, cy, w, h in gt:
    dr.rectangle([(cx-w/2)*W2, (cy-h/2)*H2, (cx+w/2)*W2, (cy+h/2)*H2], outline=(0,255,0), width=5)
    dr.text(((cx-w/2)*W2, (cy-h/2)*H2-24), f"GT {RAW_MINE[c]}", fill=(0,255,0))

print(f"\n预测 ({len(keep)} 个):")
matched = set()
for s, b, bx in keep:
    px = (bx[0]*IMGSZ - offX)/scale/W; py = (bx[1]*IMGSZ - offY)/scale/H
    pw = bx[2]*IMGSZ/scale/W;          ph = bx[3]*IMGSZ/scale/H
    best, bi = 0.0, -1
    for i, (c, cx, cy, w, h) in enumerate(gt):
        v = iou(bx, (cx-w/2, cy-h/2, w, h))
        if v > best: best, bi = v, i
    if best >= 0.5 and bi not in matched:
        ok = RAW_MINE[gt[bi][0]] == CLASS_NAMES[b]
        tag = f"  <=> GT:{RAW_MINE[gt[bi][0]]} IoU={best:.2f} {'✅' if ok else '⚠️类不符'}"
        matched.add(bi)
    elif best >= 0.5:
        tag = f"  (重复匹配 GT IoU={best:.2f})"
    else:
        tag = "  (误报)" if best < 0.1 else f"  (定位偏差,最高IoU={best:.2f})"
    print(f"  conf={s:.3f} {CLASS_NAMES[b]:<10} x={px:.3f} y={py:.3f} w={pw:.3f} h={ph:.3f}{tag}")
    dr.rectangle([px*W2, py*H2, (px+pw)*W2, (py+ph)*H2], outline=(255,40,40), width=5)
    dr.text((px*W2, py*H2+6), f"P {CLASS_NAMES[b]} {s:.2f}", fill=(255,80,80))

missed = [RAW_MINE[g[0]] for i, g in enumerate(gt) if i not in matched]
print(f"\n漏检 GT: {missed if missed else '无 ✅'}")
vis.save(OUTV, quality=90)
print(f"可视化: {OUTV}")
