# -*- coding: utf-8 -*-
"""裁剪实验：真实缺陷裁剪 vs 镜像位置裁剪，检测模型能否看见。"""
import sys, numpy as np
from PIL import Image, ImageOps, ImageDraw
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
THRESH = {"porosity": 0.30, "crack": 0.30, "overlap": 0.25, "spatters": 0.30,
          "good_weld": 0.40, "undercut": 0.25, "unfused": 0.20}
NMS_IOU, IMGSZ = 0.6, 640
ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    u = a[2]*a[3] + b[2]*b[3] - ix*iy
    return ix*iy/u if u > 0 else 0.0

def detect(im, conf_floor=0.05, topn=5):
    W, H = im.size
    scale = min(IMGSZ/W, IMGSZ/H)
    lbW, lbH = int(round(W*scale)), int(round(H*scale))
    offX, offY = (IMGSZ-lbW)//2, (IMGSZ-lbH)//2
    canvas = Image.new("RGB", (IMGSZ, IMGSZ), (114,)*3)
    canvas.paste(im.resize((lbW, lbH), Image.BILINEAR), (offX, offY))
    x = (np.asarray(canvas, np.float32)/255.0).transpose(2,0,1)[None].astype(np.float32)
    o = sess.run(None, {sess.get_inputs()[0].name: x})[0]
    o = o[0] if o.ndim == 3 else o.T
    sc, co = o[4:11,:], o[0:4,:]
    cand = []
    for a in range(o.shape[1]):
        b = int(np.argmax(sc[:,a])); s = float(sc[b,a])
        if b == 4 or s < conf_floor: continue
        cx, cy, w, h = co[0,a]/IMGSZ, co[1,a]/IMGSZ, co[2,a]/IMGSZ, co[3,a]/IMGSZ
        cand.append([s, CLASS_NAMES[b], [cx-w/2, cy-h/2, w, h]])
    cand.sort(reverse=True)
    keep = []
    for c in cand:
        if all(c[0] > k[0] or iou(c[2], k[2]) < NMS_IOU for k in keep):
            keep.append(c)
    return keep[:topn], (W, H)

def crop_detect(tag, img_path, cx, cy, cw, ch, out):
    img = ImageOps.exif_transpose(Image.open(img_path)).convert("RGB")
    W, H = img.size
    box = (int((cx-cw/2)*W), int((cy-ch/2)*H), int((cx+cw/2)*W), int((cy+ch/2)*H))
    crop = img.crop(box)
    crop.save(out.replace('.jpg','_src.jpg'), quality=92)
    # 原尺寸直接推理
    keep1, _ = detect(crop, 0.05, 3)
    # 放大到 1280 再推理（模拟 App 拍近景）
    big = crop.resize((1280, int(1280*crop.size[1]/crop.size[0])))
    keep2, _ = detect(big, 0.05, 3)
    print(f"\n===== {tag} (crop {crop.size}) =====")
    for name, keep in [("原尺寸", keep1), ("放大1280", keep2)]:
        print(f" [{name}]")
        for s, n, bx in keep:
            print(f"   conf={s:.3f} {n:<10} x={bx[0]:.3f} y={bx[1]:.3f} w={bx[2]:.3f} h={bx[3]:.3f}")
        if not keep: print("   (无候选)")

R = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images"
O = r"D:/workbuddy/workbuddy学习/weld_fatigue_checker/ml"
# mine_008: 真实气孔群 (0.368,0.562) vs 镜像位置 (1-0.368=0.632, 0.562)
crop_detect("mine_008 真实气孔群", f"{R}/mine_008.jpg", 0.368, 0.562, 0.24, 0.22, f"{O}/crop008_pore.jpg")
crop_detect("mine_008 镜像位置",   f"{R}/mine_008.jpg", 0.632, 0.562, 0.24, 0.22, f"{O}/crop008_mir.jpg")
# mine_018: 真实焊瘤 (0.833,0.636) vs 镜像位置 (0.167, 0.636)
crop_detect("mine_018 真实焊瘤",   f"{R}/mine_018.jpg", 0.833, 0.636, 0.30, 0.28, f"{O}/crop018_ovl.jpg")
crop_detect("mine_018 镜像位置",   f"{R}/mine_018.jpg", 0.167, 0.636, 0.30, 0.28, f"{O}/crop018_mir.jpg")
