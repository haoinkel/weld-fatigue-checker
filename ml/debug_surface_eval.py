# -*- coding: utf-8 -*-
"""诊断：金标准 predict 评估 + ONNX 原始输出诊断 + 单图对比。"""
import os, glob, sys
import numpy as np
from PIL import Image, ImageOps
from ultralytics import YOLO

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
BEST = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/last_surface_best.pt"
DATASETS = [
    ("raw_mine", r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine"),
    ("zenodo",   r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test"),
]

def iou(b1, b2):
    ix = max(0.0, min(b1[0]+b1[2], b2[0]+b2[2]) - max(b1[0], b2[0]))
    iy = max(0.0, min(b1[1]+b1[3], b2[1]+b2[3]) - max(b1[1], b2[1]))
    inter = ix*iy; uni = b1[2]*b1[3] + b2[2]*b2[3] - inter
    return inter/uni if uni > 0 else 0.0

def parse_gt(lbl):
    out = []
    if not os.path.exists(lbl): return out
    for line in open(lbl):
        p = line.split()
        if len(p) < 5: continue
        idx = int(p[0])
        if 0 <= idx < len(CLASS_NAMES):
            xc,yc,w,h = map(float, p[1:5])
            out.append(((xc-w/2, yc-h/2, w, h), CLASS_NAMES[idx]))
    return out

def main():
    model = YOLO(BEST)
    print("model.names =", model.names)
    agg = {c: {"tp":0,"fp":0,"fn":0} for c in CLASS_NAMES}
    n_imgs = 0
    for ds_name, root in DATASETS:
        img_dir = os.path.join(root, "images")
        lbl_dir = os.path.join(root, "labels")
        for ip in sorted(glob.glob(os.path.join(img_dir, "*"))):
            base = os.path.splitext(os.path.basename(ip))[0]
            gts = parse_gt(os.path.join(lbl_dir, base+".txt"))
            if not gts: continue
            n_imgs += 1
            res = model.predict(ip, imgsz=640, conf=0.001, iou=0.6, verbose=False)[0]
            preds = []  # (rect, cls)
            if res.boxes is not None:
                for b, c, s in zip(res.boxes.xywhn, res.boxes.cls, res.boxes.conf):
                    ci = int(c)
                    if 0 <= ci < len(CLASS_NAMES):
                        xc,yc,w,h = b.tolist()
                        preds.append(((xc-w/2, yc-h/2, w, h), CLASS_NAMES[ci]))
            for cls in CLASS_NAMES:
                gt_c = [g for g in gts if g[1]==cls]
                pr_c = [p for p in preds if p[1]==cls]
                used = set()
                for p in sorted(pr_c, key=lambda x: -1):
                    mt = -1; bi = 0.5
                    for gi,g in enumerate(gt_c):
                        if gi in used: continue
                        v = iou(g[0], p[0])
                        if v >= bi: bi = v; mt = gi
                    if mt >= 0: used.add(mt); agg[cls]["tp"] += 1
                    else: agg[cls]["fp"] += 1
                agg[cls]["fn"] += len(gt_c) - len(used)
    print(f"\n=== 金标准 predict 评估（{n_imgs} 图）===")
    print(f"{'类':<12}{'TP':>4}{'FP':>4}{'FN':>4}{'精确':>8}{'召回':>8}")
    for c in CLASS_NAMES:
        tp,fp,fn = agg[c]["tp"],agg[c]["fp"],agg[c]["fn"]
        if tp+fp==0 and fn==0:
            print(f"{c:<12}{tp:>4}{fp:>4}{fn:>4}{'-':>8}{'-':>8}"); continue
        pr = tp/(tp+fp) if tp+fp else 0; rc = tp/(tp+fn) if tp+fn else 0
        print(f"{c:<12}{tp:>4}{fp:>4}{fn:>4}{pr:>8.2f}{rc:>8.2f}")

if __name__ == "__main__":
    main()
