# -*- coding: utf-8 -*-
"""对比实验：stretch(=App scaleFill) vs letterbox 预处理，在 porosity 图上的定位差异。"""
import os, glob, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

sess = ort.InferenceSession(r'D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx', providers=['CPUExecutionProvider'])
iname = sess.get_inputs()[0].name
idir = r'D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images'
ldir = r'D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels'
cmap = {0:0, 1:1, 2:5, 3:2, 4:6}   # raw_mine 5类序 → 7类目标

def iou(a,b):
    ix=max(0.0,min(a[0]+a[2],b[0]+b[2])-max(a[0],b[0]))
    iy=max(0.0,min(a[1]+a[3],b[1]+b[3])-max(a[1],b[1]))
    it=ix*iy; un=a[2]*a[3]+b[2]*b[3]-it
    return it/un if un>0 else 0

def run(img_arr_640):
    raw = sess.run(None, {iname: img_arr_640.astype(np.float32)})[0][0]
    sc, co = raw[4:11,:], raw[0:4,:]
    dets=[]
    for a in range(raw.shape[1]):
        col=sc[:,a]; b=int(np.argmax(col)); s=float(col[b])
        if s>0.05:
            cx,cy,w,h=co[0,a]/640,co[1,a]/640,co[2,a]/640,co[3,a]/640
            dets.append((s,b,(cx-w/2,cy-h/2,w,h)))
    return dets

def stretch(img):
    return np.asarray(img.resize((640,640),Image.BILINEAR),dtype=np.float32)/255.

def letterbox(img):
    W,H=img.size; s=min(640/W,640/H); nw,nh=int(round(W*s)),int(round(H*s))
    rs=img.resize((nw,nh),Image.BILINEAR)
    canvas=Image.new('RGB',(640,640),(114,114,114))
    canvas.paste(rs,((640-nw)//2,(640-nh)//2))
    return np.asarray(canvas,dtype=np.float32)/255., s, (640-nw)//2, (640-nh)//2

n=0; sumS=0; sumL=0; cnt=0
for ip in sorted(glob.glob(os.path.join(idir,'*'))):
    base=os.path.splitext(os.path.basename(ip))[0]; lab=os.path.join(ldir,base+'.txt')
    if not os.path.exists(lab): continue
    gts=[]
    for line in open(lab):
        p=line.split()
        if len(p)>=5:
            t=cmap.get(int(float(p[0])))
            if t is not None:
                cx,cy,w,h=map(float,p[1:5])
                gts.append((t,(cx-w/2,cy-h/2,w,h)))
    if not any(t==0 for t,_ in gts): continue
    img=ImageOps.exif_transpose(Image.open(ip).convert('RGB'))
    W,H=img.size
    # stretch
    ds=[d for d in run(np.expand_dims(stretch(img).transpose(2,0,1),0)) if d[1]==0]
    # letterbox：输出坐标在 640 letterbox 空间，需换算回原图归一化
    arrL,s,px,py=letterbox(img)
    rawL=sess.run(None,{iname:np.expand_dims(arrL.transpose(2,0,1),0).astype(np.float32)})[0][0]
    sc,co=rawL[4:11,:],rawL[0:4,:]
    dl=[]
    for a in range(rawL.shape[1]):
        col=sc[:,a]; b=int(np.argmax(col)); sv=float(col[b])
        if b==0 and sv>0.05:
            bx,by,bw,bh=co[0,a],co[1,a],co[2,a],co[3,a]
            ox=(bx-px)/s/W; oy=(by-py)/s/H; ow=bw/s/W; oh=bh/s/H
            dl.append((sv,(ox-ow/2,oy-oh/2,ow,oh)))
    dl.sort(reverse=True)
    por_gts=[gb for t,gb in gts if t==0]
    def best(d): return max((iou(d,gb) for gb in por_gts), default=0)
    bs = best(ds[0][2]) if ds else 0
    bl = best(dl[0][1]) if dl else 0
    sumS+=bs; sumL+=bl; cnt+=1
    print(f"{base} ({W}x{H}{'竖' if H>W else '横'}): stretch bestIoU={bs:.2f} | letterbox bestIoU={bl:.2f}")
    n+=1
    if n>=12: break
print(f"\n平均: stretch={sumS/cnt:.3f}  letterbox={sumL/cnt:.3f}  (n={cnt})")
