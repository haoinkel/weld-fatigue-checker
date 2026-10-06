# -*- coding: utf-8 -*-
"""实拍域 40 张基线（切片推理版）：复刻 App R3 的切片逻辑（640 瓦片/步长512/跨片NMS），
对 raw_mine 全量算检出率。这是 tile 重训模型的正确成功闸门（整图640直推测不出 tile 尺度收益）。
结果写入 ml/baseline_rawmine40_tiled_result.txt"""
import os, glob, argparse, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
RAW_MINE = ["porosity", "crack", "overlap"]  # 约定闸门=30框(剔除 spatters/good_weld)，与 07:30 既定定义一致
THRESH = {"porosity": 0.30, "crack": 0.30, "overlap": 0.25, "spatters": 0.30,
          "good_weld": 0.40, "undercut": 0.25, "unfused": 0.20}
NMS_IOU, IMGSZ, GRAY, STRIDE = 0.6, 640, 114, 512
ONNX_DEF = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/best.onnx"
BASE = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine"

ap = argparse.ArgumentParser()
ap.add_argument("--onnx", default=ONNX_DEF)
ap.add_argument("--out", default=None)
args = ap.parse_args()
sess = ort.InferenceSession(args.onnx, providers=["CPUExecutionProvider"])

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    u = a[2]*a[3] + b[2]*b[3] - ix*iy
    return ix*iy/u if u > 0 else 0.0

def infer_crop(crop):
    """crop: PIL Image。返回该 crop 内归一化预测 [(name,(px,py,pw,ph)) in 0..1 of crop]"""
    W, H = crop.size
    scale = min(IMGSZ/W, IMGSZ/H)
    lbW, lbH = int(round(W*scale)), int(round(H*scale))
    offX, offY = (IMGSZ-lbW)//2, (IMGSZ-lbH)//2
    canvas = Image.new("RGB", (IMGSZ, IMGSZ), (GRAY, GRAY, GRAY))
    canvas.paste(crop.resize((lbW, lbH), Image.BILINEAR), (offX, offY))
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

def tile_starts(size):
    if size <= IMGSZ:
        return [0]
    starts = list(range(0, size-IMGSZ+1, STRIDE))
    if not starts or starts[-1] != size-IMGSZ:
        starts.append(size-IMGSZ)
    return starts

def infer_tiled(img):
    W, H = img.size
    preds = []  # (name, fx,fy,fw,fh) 全图归一化
    for tx in tile_starts(W):
        for ty in tile_starts(H):
            cw = min(tx+IMGSZ, W)-tx; ch = min(ty+IMGSZ, H)-ty
            crop = img.crop((tx, ty, tx+cw, ty+ch))
            for name, (px, py, pw, ph) in infer_crop(crop):
                fx = (tx + px*cw)/W; fy = (ty + py*ch)/H
                fw = pw*cw/W;       fh = ph*ch/H
                preds.append((name, (fx, fy, fw, fh)))
    # 跨片全局 NMS（同一缺陷可能多瓦片命中）
    preds.sort(key=lambda p: p[1][0], reverse=True)  # 暂用 conf 占位不行，重排按面积? 用原顺序即可
    # 重新按 conf 排：上面 infer_crop 已 NMS，但跨片需再 NMS；用 (name, box) 做 IoU 合并
    merged = []
    # 先按类别内 IoU 合并（不同类不合并）
    by_cls = {}
    for name, box in preds:
        by_cls.setdefault(name, []).append(box)
    for name, boxes in by_cls.items():
        boxes_sorted = sorted(boxes, key=lambda b: b[2]*b[3], reverse=True)
        mk = []
        for box in boxes_sorted:
            if all(iou(box, k) < NMS_IOU for k in mk):
                mk.append(box)
        for box in mk:
            merged.append((name, box))
    return merged

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
    preds = infer_tiled(img)
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
out.append(f"实拍域 40 张基线（切片推理复刻R3, ONNX={os.path.basename(args.onnx)}）")
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
result_path = args.out or os.path.join(os.path.dirname(__file__), "baseline_rawmine40_tiled_result.txt")
with open(result_path, "w", encoding="utf-8") as fh:
    fh.write(txt)
print(f"\n→ 切片基线已写入 {result_path}")
