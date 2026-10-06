# -*- coding: utf-8 -*-
import os, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort
CLASS_NAMES = ["porosity","crack","overlap","spatters","good_weld","undercut","unfused"]
THRESH={"porosity":0.30,"crack":0.30,"overlap":0.25,"spatters":0.30,"good_weld":0.40,"undercut":0.25,"unfused":0.20}
IMGSZ,GRAY,STRIDE=640,114,512
sess=ort.InferenceSession(r"D:/workbuddy/workbuddy学习/surfacedetecttrain/best.onnx",providers=["CPUExecutionProvider"])
def infer_crop(crop):
    W,H=crop.size
    scale=min(IMGSZ/W,IMGSZ/H); lbW,lbH=int(round(W*scale)),int(round(H*scale))
    offX,offY=(IMGSZ-lbW)//2,(IMGSZ-lbH)//2
    canvas=Image.new("RGB",(IMGSZ,IMGSZ),(GRAY,GRAY,GRAY)); canvas.paste(crop.resize((lbW,lbH),Image.BILINEAR),(offX,offY))
    x=(np.asarray(canvas,np.float32)/255.0).transpose(2,0,1)[None].astype(np.float32)
    o=sess.run(None,{sess.get_inputs()[0].name:x})[0]; o=o[0] if o.ndim==3 else o.T
    sc,co=o[4:11,:],o[0:4,:]
    out=[]
    for a in range(o.shape[1]):
        b=int(np.argmax(sc[:,a])); s=float(sc[b,a])
        if b==4 or s<THRESH[CLASS_NAMES[b]]: continue
        cx,cy,w,h=co[0,a]/IMGSZ,co[1,a]/IMGSZ,co[2,a]/IMGSZ,co[3,a]/IMGSZ
        px=(cx-w/2)*IMGSZ-offX; py=(cy-h/2)*IMGSZ-offY; pw=w*IMGSZ; ph=h*IMGSZ
        # 转回 crop 归一化
        px=(px/scale)/W; py=(py/scale)/H; pw=(pw/scale)/W; ph=(ph/scale)/H
        out.append((CLASS_NAMES[b],round(s,2),px,py,pw,ph))
    return out
img=ImageOps.exif_transpose(Image.open(r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images/mine_001.jpg")).convert("RGB")
W,H=img.size
print(f"image size={W}x{H}")
def starts(size):
    if size<=IMGSZ: return [0]
    st=list(range(0,size-IMGSZ+1,STRIDE))
    if st[-1]!=size-IMGSZ: st.append(size-IMGSZ)
    return st
for tx in starts(W):
    for ty in starts(H):
        cw=min(tx+IMGSZ,W)-tx; ch=min(ty+IMGSZ,H)-ty
        crop=img.crop((tx,ty,tx+cw,ty+ch))
        dets=infer_crop(crop)
        if not dets: continue
        print(f"\nTILE tx={tx} ty={ty} cw={cw} ch={ch}")
        for name,s,px,py,pw,ph in dets:
            fx=(tx+px*cw)/W; fy=(ty+py*ch)/H; fw=pw*cw/W; fh=ph*ch/H
            # 校验是否在 0..1
            ok = (0<=fx<=1 and 0<=fy<=1 and 0<=fw<=1 and 0<=fh<=1)
            print(f"  {name} conf={s} cropbox=({px:.3f},{py:.3f},{pw:.3f},{ph:.3f}) full=({fx:.3f},{fy:.3f},{fw:.3f},{fh:.3f}) {'OK' if ok else 'OUT-OF-RANGE'}")
# GT
lbl=r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels/mine_001.txt"
print("\nGT:")
for line in open(lbl):
    p=line.split()
    if len(p)>=5:
        c,cx,cy,w,h=int(float(p[0])),*map(float,p[1:5])
        print(f"  {CLASS_NAMES[c]} ({(cx-w/2):.3f},{(cy-h/2):.3f},{w:.3f},{h:.3f})")
