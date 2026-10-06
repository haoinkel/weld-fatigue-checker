# -*- coding: utf-8 -*-
"""诊断 v3：EXIF 旋转统计 + mine_012 定位核对（GT 框 vs 最高分预测框）。"""
import os, glob
from PIL import Image, ImageOps
import numpy as np

BASE = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine"
CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
RAW_MINE = ["porosity", "crack", "overlap", "spatters", "good_weld"]

# 1) EXIF 旋转统计
print("=== EXIF 方向统计（前 12 张）===")
imgs = sorted(glob.glob(BASE+"/images/*.jpg"))
rot_count = 0
for f in imgs[:12]:
    im = Image.open(f)
    ori = im.getexif().get(0x0112, 1)  # Orientation tag
    w,h = im.size
    print(f"{os.path.basename(f)}: raw={w}x{h} orient={ori}")
    if ori in (6,8): rot_count += 1
print(f"... 12 张中 {rot_count} 张带 90/270 旋转标签")

# 2) mine_012 定位核对：用 transpose 后图像 + GT，dump 最高分预测
import onnxruntime as ort
ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/best.onnx"
IMGSZ, GRAY, STRIDE = 640, 114, 512
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
def iou(a,b):
    ix=max(0.0,min(a[0]+a[2],b[0]+b[2])-max(a[0],b[0]))
    iy=max(0.0,min(a[1]+a[3],b[1]+b[3])-max(a[1],b[1]))
    u=a[2]*a[3]+b[2]*b[3]-ix*iy
    return ix*iy/u if u>0 else 0.0
def infer_crop_all(crop):
    W,H=crop.size
    scale=min(IMGSZ/W,IMGSZ/H)
    lbW,lbH=int(round(W*scale)),int(round(H*scale))
    offX,offY=(IMGSZ-lbW)//2,(IMGSZ-lbH)//2
    canvas=Image.new("RGB",(IMGSZ,IMGSZ),(GRAY,GRAY,GRAY))
    canvas.paste(crop.resize((lbW,lbH),Image.BILINEAR),(offX,offY))
    x=(np.asarray(canvas,np.float32)/255.0).transpose(2,0,1)[None].astype(np.float32)
    o=sess.run(None,{sess.get_inputs()[0].name:x})[0]
    o=o[0] if o.ndim==3 else o.T
    sc,co=o[4:11,:],o[0:4,:]
    out=[]
    for a in range(o.shape[1]):
        b=int(np.argmax(sc[:,a])); s=float(sc[b,a])
        if CLASS_NAMES[b] not in RAW_MINE: continue
        out.append((CLASS_NAMES[b],s,(co[0,a]/IMGSZ,co[1,a]/IMGSZ,co[2,a]/IMGSZ,co[3,a]/IMGSZ)))
    return out
def tile_starts(size):
    if size<=IMGSZ: return [0]
    st=list(range(0,size-IMGSZ+1,STRIDE))
    if not st or st[-1]!=size-IMGSZ: st.append(size-IMGSZ)
    return st

n="mine_012"
f=BASE+f"/images/{n}.jpg"
img=ImageOps.exif_transpose(Image.open(f)).convert("RGB")
W,H=img.size
gt=[]
lbl=BASE+f"/labels/{n}.txt"
for line in open(lbl):
    p=line.split()
    if len(p)>=5:
        c=int(float(p[0])); cx,cy,w,h=map(float,p[1:5])
        if 0<=c<len(CLASS_NAMES) and CLASS_NAMES[c] in RAW_MINE:
            gt.append((CLASS_NAMES[c],(cx-w/2,cy-h/2,w,h)))
print(f"\n=== {n} (transposed {W}x{H}) GT 框 ===")
for gname,(gx,gy,gw,gh) in gt:
    print(f"  {gname:<10} center=({gx+gw/2:.3f},{gy+gh/2:.3f}) size=({gw:.3f}x{gh:.3f})")
# 收集所有预测，按类取 top5
preds=[]
for tx in tile_starts(W):
    for ty in tile_starts(H):
        cw=min(tx+IMGSZ,W)-tx; ch=min(ty+IMGSZ,H)-ty
        crop=img.crop((tx,ty,tx+cw,ty+ch))
        for cls,s,(bx,by,bw,bh) in infer_crop_all(crop):
            fx=(tx+bx*cw)/W; fy=(ty+by*ch)/H; fw=bw*cw/W; fh=bh*ch/H
            preds.append((cls,s,(fx,fy,fw,fh)))
print(f"\n=== {n} 各类 TOP 预测（按分数）===")
bycls={}
for cls,s,box in preds:
    bycls.setdefault(cls,[]).append((s,box))
for cls in RAW_MINE:
    lst=sorted(bycls.get(cls,[]),reverse=True)[:3]
    for s,box in lst:
        cx2,cy2=box[0]+box[2]/2,box[1]+box[3]/2
        print(f"  {cls:<10} s={s:.3f} center=({cx2:.3f},{cy2:.3f}) size=({box[2]:.3f}x{box[3]:.3f})")
# 逐 GT 找最佳匹配
print(f"\n=== {n} 每 GT 的最佳预测匹配（IoU）===")
for gname,(gx,gy,gw,gh) in gt:
    gbox=(gx,gy,gw,gh)
    best,info=0.0,None
    for cls,s,(fx,fy,fw,fh) in preds:
        if cls!=gname: continue
        v=iou((fx,fy,fw,fh),gbox)
        if v>best: best,info=(v,(s,fx,fy,fw,fh))
    if info:
        s,fx,fy,fw,fh=info
        print(f"  GT {gname:<10} -> best IoU={best:.3f} pred_s={s:.3f} center=({fx+fw/2:.3f},{fy+fh/2:.3f})")
    else:
        print(f"  GT {gname:<10} -> 无同预测")
