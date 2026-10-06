# -*- coding: utf-8 -*-
"""mine_008 镜像假设验证：原图 vs 水平翻转，并输出可视化标注图。"""
import numpy as np
from PIL import Image, ImageOps, ImageDraw
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
RAW_MINE = ["porosity", "crack", "undercut", "overlap", "unfused"]
THRESH = {"porosity": 0.30, "crack": 0.30, "overlap": 0.25, "spatters": 0.30,
          "good_weld": 0.40, "undercut": 0.25, "unfused": 0.20}
NMS_IOU, IMGSZ, GRAY = 0.6, 640, 114

ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"
IMG  = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images/mine_008.jpg"
LAB  = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels/mine_008.txt"
OUTV = r"D:/workbuddy/workbuddy学习/weld_fatigue_checker/ml/debug_mine008_vis.jpg"

sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])

gt = []
for line in open(LAB):
    p = line.split()
    if len(p) >= 5:
        gt.append((int(float(p[0])), float(p[1]), float(p[2]), float(p[3]), float(p[4])))

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    u = a[2]*a[3] + b[2]*b[3] - ix*iy
    return ix*iy/u if u > 0 else 0.0

def detect(im):
    W, H = im.size
    scale = min(IMGSZ/W, IMGSZ/H)
    lbW, lbH = int(round(W*scale)), int(round(H*scale))
    offX, offY = (IMGSZ-lbW)//2, (IMGSZ-lbH)//2
    canvas = Image.new("RGB", (IMGSZ, IMGSZ), (GRAY, GRAY, GRAY))
    canvas.paste(im.resize((lbW, lbH), Image.BILINEAR), (offX, offY))
    x = (np.asarray(canvas, np.float32)/255.0).transpose(2,0,1)[None]
    o = sess.run(None, {sess.get_inputs()[0].name: x})[0]
    o = o[0] if o.ndim == 3 else o.T
    sc, co = o[4:11,:], o[0:4,:]
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
    return keep, scale, offX, offY, (W, H)

def report(tag, keep, scale, offX, offY, size):
    W, H = size
    print(f"\n===== {tag} =====")
    for s, b, bx in keep:
        px = (bx[0]*IMGSZ - offX)/scale/W; py = (bx[1]*IMGSZ - offY)/scale/H
        pw = bx[2]*IMGSZ/scale/W;          ph = bx[3]*IMGSZ/scale/H
        best = max((iou((px,py,pw,ph), (c-w/2, d-h/2, w, h)) for c,cx,d,w,h in gt), default=0)
        mir = max((iou((1-px-pw,py,pw,ph), (c-w/2, d-h/2, w, h)) for c,cx,d,w,h in gt), default=0)
        print(f"  conf={s:.3f} {CLASS_NAMES[b]:<10} x={px:.3f} y={py:.3f} w={pw:.3f} h={ph:.3f}  直接IoU={best:.2f} 镜像IoU={mir:.2f}")
    return keep

img = ImageOps.exif_transpose(Image.open(IMG)).convert("RGB")
keep1 = report("原图", *detect(img))

flip = ImageOps.mirror(img)
keep2, scale, offX, offY, size = detect(flip)
W, H = size
print("\n===== 水平翻转图（坐标已换算回原图坐标系）=====")
for s, b, bx in keep2:
    fx = bx[0]  # 在翻转图里的位置
    px_orig = 1 - (fx*IMGSZ - offX)/scale/W - bx[2]*IMGSZ/scale/W  # 翻回原图 x
    py = (bx[1]*IMGSZ - offY)/scale/H
    pw = bx[2]*IMGSZ/scale/W; ph = bx[3]*IMGSZ/scale/H
    best = max((iou((px_orig,py,pw,ph), (c-w/2, d-h/2, w, h)) for c,cx,d,w,h in gt), default=0)
    print(f"  conf={s:.3f} {CLASS_NAMES[b]:<10} x={px_orig:.3f} y={py:.3f} w={pw:.3f} h={ph:.3f}  对GT直接IoU={best:.2f}")

# 可视化：GT 绿框 / 预测 红框（画在原图）
vis = img.copy(); dr = ImageDraw.Draw(vis)
for c, cx, cy, w, h in gt:
    dr.rectangle([ (cx-w/2)*W, (cy-h/2)*H, (cx+w/2)*W, (cy+h/2)*H ], outline=(0,255,0), width=6)
    dr.text(((cx-w/2)*W, (cy-h/2)*H-30), f"GT {RAW_MINE[c]}", fill=(0,255,0))
for s, b, bx in keep1:
    px = (bx[0]*IMGSZ - offX)/scale/W; py = (bx[1]*IMGSZ - offY)/scale/H
    pw = bx[2]*IMGSZ/scale/W;          ph = bx[3]*IMGSZ/scale/H
    dr.rectangle([ px*W, py*H, (px+pw)*W, (py+ph)*H ], outline=(255,40,40), width=6)
    dr.text((px*W, py*H+8), f"P {CLASS_NAMES[b]} {s:.2f}", fill=(255,80,80))
vis.save(OUTV, quality=90)
print(f"\n可视化已存: {OUTV}")
