# -*- coding: utf-8 -*-
"""实拍域 40 张全量基线：当前 ONNX 模型(整图640+letterbox+校准阈值+NMS) 对 raw_mine 全量算检出率。
作为切图重训前后的 pass/fail 对照闸门。结果写入 ml/baseline_rawmine40_result.txt"""
import os, glob, argparse, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
RAW_MINE = ["porosity", "crack", "overlap"]  # 约定闸门=30框(剔除 spatters/good_weld)，与 07:30 既定定义一致
THRESH = {"porosity": 0.30, "crack": 0.30, "overlap": 0.25, "spatters": 0.30,
          "good_weld": 0.40, "undercut": 0.25, "unfused": 0.20}
NMS_IOU, IMGSZ, GRAY = 0.6, 640, 114
ONNX_DEF = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"
BASE = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine"

ap = argparse.ArgumentParser()
ap.add_argument("--onnx", default=ONNX_DEF, help="重训后导出的 ONNX 路径（默认当前模型）")
ap.add_argument("--out", default=None, help="结果输出文件（默认覆盖 baseline_rawmine40_result.txt）")
args = ap.parse_args()
ONNX = args.onnx
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    u = a[2]*a[3] + b[2]*b[3] - ix*iy
    return ix*iy/u if u > 0 else 0.0

def infer(img):
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
    cand = []
    for a in range(o.shape[1]):
        b = int(np.argmax(sc[:,a])); s = float(sc[b,a])
        cls = CLASS_NAMES[b]
        if cls not in RAW_MINE or s < THRESH[cls]:
            continue
        cx, cy, w, h = co[0,a]/IMGSZ, co[1,a]/IMGSZ, co[2,a]/IMGSZ, co[3,a]/IMGSZ
        cand.append([s, b, [cx-w/2, cy-h/2, w, h]])
    cand.sort(reverse=True)
    keep = []
    for c in cand:
        if all(c[0] > k[0] or iou(c[2], k[2]) < NMS_IOU for k in keep):
            keep.append(c)
    preds = []
    for s, b, bx in keep:
        px = (bx[0]*IMGSZ - offX)/scale/W; py = (bx[1]*IMGSZ - offY)/scale/H
        pw = bx[2]*IMGSZ/scale/W;          ph = bx[3]*IMGSZ/scale/H
        preds.append((CLASS_NAMES[b], (px, py, pw, ph)))
    return preds

imgs = sorted(glob.glob(BASE+"/images/*.jpg"))
total_img = len(imgs)
img_with_det = 0
gt_total = 0; det_total = 0; fp_total = 0
per_class_gt = {}; per_class_det = {}
lines = []
for f in imgs:
    n = os.path.splitext(os.path.basename(f))[0]
    img = ImageOps.exif_transpose(Image.open(f)).convert("RGB")
    gt = []
    lbl = BASE+f"/labels/{n}.txt"
    if os.path.exists(lbl):
        for line in open(lbl):
            p = line.split()
            if len(p) >= 5:
                c, cx, cy, w, h = int(float(p[0])), *map(float, p[1:5])
                if 0 <= c < len(CLASS_NAMES) and CLASS_NAMES[c] in RAW_MINE:
                    gt.append((CLASS_NAMES[c], (cx-w/2, cy-h/2, w, h)))
    preds = infer(img)
    matched_gt = set()
    fp = 0
    for pname, pbox in preds:
        best, bi = 0.0, -1
        for i, (gname, gbox) in enumerate(gt):
            if gname != pname: continue
            v = iou(pbox, gbox)
            if v > best: best, bi = v, i
        if best >= 0.5 and bi not in matched_gt:
            matched_gt.add(bi)
        else:
            fp += 1
    det = len(matched_gt)
    missed = len(gt) - det
    if det > 0: img_with_det += 1
    gt_total += len(gt); det_total += det; fp_total += fp
    for i, (gname, _) in enumerate(gt):
        per_class_gt[gname] = per_class_gt.get(gname, 0) + 1
        if i in matched_gt:
            per_class_det[gname] = per_class_det.get(gname, 0) + 1
    lines.append(f"{n}: GT={len(gt)} 检出={det} 漏={missed} 误报={fp}")

recall = det_total/gt_total if gt_total else 0
out = []
out.append("="*60)
out.append(f"实拍域 40 张基线 (ONNX={os.path.basename(ONNX)}, 整图640 letterbox)")
out.append("="*60)
out.append(f"图片总数: {total_img}")
out.append(f"有≥1正确检出的图片: {img_with_det}/{total_img}  ({img_with_det/total_img*100:.0f}%)")
out.append(f"GT 框总数: {gt_total}  正确检出: {det_total}  漏检: {gt_total-det_total}  误报: {fp_total}")
out.append(f"整域召回率(框级): {recall*100:.1f}%")
out.append("-"*60)
out.append("各类召回:")
for c in RAW_MINE:
    g = per_class_gt.get(c, 0); d = per_class_det.get(c, 0)
    out.append(f"  {c:<10} {d}/{g}  ({d/g*100:.0f}%)" if g else f"  {c:<10} 0/0  (N/A 无GT)")
out.append("="*60)
out.append("逐图:")
out.extend(lines)
txt = "\n".join(out)
print(txt)
result_path = args.out or os.path.join(os.path.dirname(__file__), "baseline_rawmine40_result.txt")
with open(result_path, "w", encoding="utf-8") as fh:
    fh.write(txt)
print(f"\n→ 基线已写入 {result_path}")
