# -*- coding: utf-8 -*-
"""诊断 v2：推理一次存全部候选，阈值扫描只过滤（快）。
打印 ONNX I/O；阈值扫描(0.01~0.30)看召回/误报分水岭；单图 dump 各类最高分。"""
import os, glob, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
RAW_MINE = ["porosity", "crack", "overlap", "spatters", "good_weld"]
IMGSZ, GRAY, STRIDE = 640, 114, 512
ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/best.onnx"
BASE = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine"

sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
print("INPUT :", sess.get_inputs()[0].name, sess.get_inputs()[0].shape)
print("OUTPUT:", sess.get_outputs()[0].name, sess.get_outputs()[0].shape)

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    u = a[2]*a[3] + b[2]*b[3] - ix*iy
    return ix*iy/u if u > 0 else 0.0

def infer_crop_all(crop):
    """返回该 crop 全部锚点候选 [(cls_name, score, fullimg_box_in_0..1)]，不过滤不NMS。"""
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
    out = []
    for a in range(o.shape[1]):
        b = int(np.argmax(sc[:,a])); s = float(sc[b,a])
        if CLASS_NAMES[b] not in RAW_MINE:
            continue
        bx,by,bw,bh = co[0,a]/IMGSZ, co[1,a]/IMGSZ, co[2,a]/IMGSZ, co[3,a]/IMGSZ
        out.append((CLASS_NAMES[b], s, (bx,by,bw,bh)))
    return out

def tile_starts(size):
    if size <= IMGSZ: return [0]
    starts = list(range(0, size-IMGSZ+1, STRIDE))
    if not starts or starts[-1] != size-IMGSZ: starts.append(size-IMGSZ)
    return starts

imgs = sorted(glob.glob(BASE+"/images/*.jpg"))
# 每图推理一次，存全部候选 + GT
cache = []
for f in imgs:
    n = os.path.splitext(os.path.basename(f))[0]
    img = ImageOps.exif_transpose(Image.open(f)).convert("RGB")
    W,H = img.size
    gt=[]
    lbl = BASE+f"/labels/{n}.txt"
    if os.path.exists(lbl):
        for line in open(lbl):
            p=line.split()
            if len(p)>=5:
                c=int(float(p[0])); cx,cy,w,h=map(float,p[1:5])
                if 0<=c<len(CLASS_NAMES) and CLASS_NAMES[c] in RAW_MINE:
                    gt.append((CLASS_NAMES[c],(cx-w/2,cy-h/2,w,h)))
    preds=[]
    for tx in tile_starts(W):
        for ty in tile_starts(H):
            cw=min(tx+IMGSZ,W)-tx; ch=min(ty+IMGSZ,H)-ty
            crop=img.crop((tx,ty,tx+cw,ty+ch))
            for cls,s,(bx,by,bw,bh) in infer_crop_all(crop):
                fx=(tx+bx*cw)/W; fy=(ty+by*ch)/H
                fw=bw*cw/W; fh=bh*ch/H
                preds.append((cls,s,(fx,fy,fw,fh)))
    cache.append((n,gt,preds))

print("\n=== 阈值扫描 ===")
for TH in [0.01, 0.05, 0.10, 0.20, 0.30]:
    gt_total=det_total=fp_total=0
    for n,gt,preds in cache:
        matched=set(); fp=0
        for pname,ps,(px,py,pw,ph) in preds:
            if ps<TH: continue
            pbox=(px,py,pw,ph)
            best,bi=0.0,-1
            for i,(gname,gbox) in enumerate(gt):
                if gname!=pname: continue
                v=iou(pbox,gbox)
                if v>best: best,bi=v,i
            if best>=0.5 and bi not in matched: matched.add(bi)
            else: fp+=1
        det=len(matched)
        gt_total+=len(gt); det_total+=det; fp_total+=fp
    rec=det_total/gt_total if gt_total else 0
    print(f"TH={TH:.2f}: 召回={rec*100:5.1f}% ({det_total}/{gt_total})  误报={fp_total}")

print("\n=== 单图各类最高分 ===")
for n,gt,preds in cache:
    if n in ("mine_018","mine_012","mine_021","mine_001","mine_004"):
        maxc={c:0.0 for c in RAW_MINE}
        for cls,s,_ in preds:
            if s>maxc[cls]: maxc[cls]=s
        print(f"{n}: "+", ".join(f"{c}={maxc[c]:.3f}" for c in RAW_MINE))
