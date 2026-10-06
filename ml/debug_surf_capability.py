# -*- coding: utf-8 -*-
"""金标准能力测试：ultralytics model.predict（letterbox，标准预处理）vs GT。
 目的：确认模型本身在正确预处理下能否定位（区分「模型差」vs「App预处理错」）。"""
import os, glob
from collections import defaultdict
from ultralytics import YOLO
import numpy as np

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
NC = len(CLASS_NAMES)
BEST = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/last_surface_best.pt"

DATASETS = [
    ("raw_mine", r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images",
                  r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels"),
    ("zenodo",   r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test/images",
                  r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test/labels"),
]

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    inter = ix*iy
    uni = a[2]*a[3] + b[2]*b[3] - inter
    return inter/uni if uni > 0 else 0.0

def load_gt(lab):
    gt = []
    if os.path.exists(lab):
        for line in open(lab):
            p = line.split()
            if len(p) >= 5:
                c = int(float(p[0])); cx, cy, w, h = map(float, p[1:5])
                gt.append((c, (cx - w/2, cy - h/2, w, h)))
    return gt

model = YOLO(BEST)
TH = 0.25
gt_count = defaultdict(int)
tp = defaultdict(int); fp = defaultdict(int); fn = defaultdict(int)
per_img_tp = 0; per_img_total = 0
n_total = 0
for dname, idir, ldir in DATASETS:
    for ip in sorted(glob.glob(os.path.join(idir, "*"))):
        if not ip.lower().endswith((".jpg",".jpeg",".png",".bmp")): continue
        base = os.path.splitext(os.path.basename(ip))[0]
        lab = os.path.join(ldir, base + ".txt")
        gt = load_gt(lab)
        res = model.predict(ip, imgsz=640, conf=TH, iou=0.6, verbose=False)[0]
        dets = []
        if res.boxes is not None:
            for i in range(len(res.boxes)):
                c = int(res.boxes.cls[i]); s = float(res.boxes.conf[i])
                xc,yc,w,h = res.boxes.xywhn[i].tolist()
                dets.append((s, c, (xc-w/2, yc-h/2, w, h)))
        n_total += 1
        # 匹配
        for c, box in gt:
            gt_count[c] += 1
            best_v, best_det = 0.0, None
            for s, dc, dbox in dets:
                if dc != c: continue
                v = iou(box, dbox)
                if v > best_v: best_v = v; best_det = dbox
            if best_v >= 0.5:
                tp[c] += 1
            else:
                fn[c] += 1
        for s, dc, dbox in dets:
            # 是否匹配到任意该类GT
            matched = any(dc == gc and iou(dbox, gbox) >= 0.5 for gc, gbox in gt)
            if not matched:
                fp[dc] += 1

print(f"金标准(letterbox) @ conf={TH} | 处理 {n_total} 张")
print(f"{'cls':<10}{'GT':>5}{'TP':>5}{'FP':>6}{'FN':>5}{'Recall':>9}{'Prec':>9}")
for c in range(NC):
    if gt_count[c]==0:
        print(f"{CLASS_NAMES[c]:<10}{0:>5}{'-':>5}{'-':>6}{'-':>5}  (无GT)")
        continue
    r = tp[c]/(tp[c]+fn[c]) if (tp[c]+fn[c]) else 0
    p = tp[c]/(tp[c]+fp[c]) if (tp[c]+fp[c]) else 0
    print(f"{CLASS_NAMES[c]:<10}{gt_count[c]:>5}{tp[c]:>5}{fp[c]:>6}{fn[c]:>5}{r*100:>8.1f}%{p*100:>8.1f}%")
