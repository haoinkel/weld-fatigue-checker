# -*- coding: utf-8 -*-
"""生成标注对比图：绿框=GT，红框=预测（任意类，看定位）。并输出每图 any-class 定位召回。"""
import os, glob
from PIL import Image, ImageDraw, ImageOps
from ultralytics import YOLO

CLASS_NAMES = ["porosity","crack","overlap","spatters","good_weld","undercut","unfused"]
BEST = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/last_surface_best.pt"
OUT = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/debug_vis"
os.makedirs(OUT, exist_ok=True)
model = YOLO(BEST)

def iou(a,b):
    ix=max(0.0,min(a[0]+a[2],b[0]+b[2])-max(a[0],b[0]))
    iy=max(0.0,min(a[1]+a[3],b[1]+b[3])-max(a[1],b[1]))
    inter=ix*iy; uni=a[2]*a[3]+b[2]*b[3]-inter
    return inter/uni if uni>0 else 0.0

def load_gt(lab):
    g=[]
    if os.path.exists(lab):
        for line in open(lab):
            p=line.split()
            if len(p)>=5:
                c=int(float(p[0])); cx,cy,w,h=map(float,p[1:5])
                g.append((c,(cx-w/2,cy-h/2,w,h)))
    return g

imgs = []
for d,idir,ldir in [("raw_mine",r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images",
                     r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels"),
                    ("zenodo",r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test/images",
                     r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test/labels")]:
    for ip in sorted(glob.glob(os.path.join(idir,"*")))[:3]:
        if ip.lower().endswith((".jpg",".jpeg",".png",".bmp")):
            imgs.append((d,ip,os.path.join(ldir,os.path.splitext(os.path.basename(ip))[0]+".txt")))

for d,ip,lab in imgs:
    img = Image.open(ip).convert("RGB"); img = ImageOps.exif_transpose(img)
    W,H = img.size
    gt = load_gt(lab)
    res = model.predict(ip, imgsz=640, conf=0.05, iou=0.6, verbose=False)[0]
    dets=[]
    if res.boxes is not None:
        for i in range(len(res.boxes)):
            c=int(res.boxes.cls[i]); s=float(res.boxes.conf[i])
            xc,yc,w,h=res.boxes.xywhn[i].tolist()
            dets.append((c,s,(xc-w/2,yc-h/2,w,h)))
    # any-class 定位召回
    loc_tp=loc_fn=0
    for gc,gbox in gt:
        hit=any(iou(gbox,dbox)>=0.5 for dc,ds,dbox in dets)
        if hit: loc_tp+=1
        else: loc_fn+=1
    loc_r = loc_tp/(loc_tp+loc_fn) if (loc_tp+loc_fn) else 0
    # 画图
    draw=ImageDraw.Draw(img)
    for gc,(x,y,w,h) in gt:
        draw.rectangle([x*W,y*H,(x+w)*W,(y+h)*H], outline=(0,200,0), width=3)
    for c,s,(x,y,w,h) in dets[:20]:
        draw.rectangle([x*W,y*H,(x+w)*W,(y+h)*H], outline=(220,0,0), width=2)
    base=os.path.splitext(os.path.basename(ip))[0]
    outp=os.path.join(OUT,f"{d}_{base}_locR{loc_r*100:.0f}.png")
    img.save(outp)
    print(f"{d}/{base}: GT={len(gt)} pred={len(dets)} any-class定位召回={loc_r*100:.0f}%  保存 {outp}")
    for gc,gbox in gt:
        print(f"   GT[{CLASS_NAMES[gc]}] x={gbox[0]:.2f} y={gbox[1]:.2f} w={gbox[2]:.2f} h={gbox[3]:.2f}")
    for c,s,(x,y,w,h) in dets[:5]:
        print(f"   PRED[{CLASS_NAMES[c]}] {s:.2f} x={x:.2f} y={y:.2f} w={w:.2f} h={h:.2f}")
