# -*- coding: utf-8 -*-
"""
表面模型本地自检 v2：
 - 用同版 ultralytics 把 best.pt 导出的 ONNX(nms=False, imgsz=640) 推理
 - 逐行复刻 SurfaceDefectDetector.swift 的解码（scaleFill /640 / 不 sigmoid / NMS iou0.6 / good_weld 过滤）
 - 对带标注的 raw_mine + zenodo 测试集做 阈值扫描，输出每类 TP/FP/FN、精确率/召回
 - 目的是：(1) 验证解码管线正确 (2) 找出模型真实可用的阈值（而非拍脑袋的 0.45）
注意：undercut/unfused 在本地测试集 GT 为 0，无法定量评估，仅统计模型是否有输出。
"""
import os, glob, numpy as np
from PIL import Image, ImageOps
import onnxruntime as ort

CLASS_NAMES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
NC = len(CLASS_NAMES)
ONNX = r"D:/workbuddy/workbuddy学习/surfacedetecttrain/WeldDefectSurfaceModel.onnx"
IMGSZ = 640
NMS_IOU = 0.6

DATASETS = [
    # (名, 图目录, 标签目录, 源类序→7类目标的索引映射；None=该源类丢弃)
    ("raw_mine", r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/images",
                  r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine/labels",
                  # raw_mine classes.txt: [porosity,crack,undercut,overlap,unfused] (5类序)
                  {0:0, 1:1, 2:5, 3:2, 4:6}),
    ("zenodo",   r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test/images",
                  r"D:/workbuddy/workbuddy学习/surfacedetecttrain/zenodo/Final_Dataset_YOLO_Test/labels",
                  # zenodo dataset_test.yaml: [weld-defect-det,slag inclusion,spatter,undercut] (4类)
                  {2:3, 3:5}),   # spatter→spatters(idx3), undercut→undercut(idx5)，前2类无目标对应丢弃
]

sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
iname = sess.get_inputs()[0].name

def load_image(path):
    """两种预处理都返回：stretch(=App scaleFill 现状) 与 letterbox(训练标准)。"""
    img = Image.open(path).convert("RGB")
    img = ImageOps.exif_transpose(img)
    W, H = img.size
    # stretch
    arr_s = np.asarray(img.resize((IMGSZ, IMGSZ), Image.BILINEAR), dtype=np.float32) / 255.0
    x_s = np.expand_dims(arr_s.transpose(2,0,1), 0).astype(np.float32)
    # letterbox
    s = min(IMGSZ/W, IMGSZ/H); nw, nh = int(round(W*s)), int(round(H*s))
    rs = img.resize((nw, nh), Image.BILINEAR)
    canvas = Image.new("RGB", (IMGSZ, IMGSZ), (114,114,114))
    canvas.paste(rs, ((IMGSZ-nw)//2, (IMGSZ-nh)//2))
    arr_l = np.asarray(canvas, dtype=np.float32) / 255.0
    x_l = np.expand_dims(arr_l.transpose(2,0,1), 0).astype(np.float32)
    pad_x, pad_y = (IMGSZ-nw)/2.0, (IMGSZ-nh)/2.0
    return x_s, x_l, (s, pad_x, pad_y, W, H)

def to_orig_letterbox(box640, geo):
    """letterbox 640 空间的归一化框 → 原图归一化框（输入已是左上角格式，勿再减 w/2）"""
    s, px, py, W, H = geo
    x, y, w, h = box640
    bx, by, bw, bh = x*IMGSZ, y*IMGSZ, w*IMGSZ, h*IMGSZ
    ox = (bx-px)/s/W; oy = (by-py)/s/H; ow = bw/s/W; oh = bh/s/H
    return (ox, oy, ow, oh)

def decode_all(raw):
    """返回所有 anchor 的候选 (score, cls, box(归一化 x,y,w,h))，score>0.05。score 已是概率(不sigmoid)。"""
    # raw: (11,8400)  行0-3=cx,cy,w,h(像素 0-640)；行4-10=类分数(概率)
    coords = raw[0:4, :]; scores = raw[4:11, :]
    out = []
    for a in range(raw.shape[1]):
        col = scores[:, a]; b = int(np.argmax(col)); bs = float(col[b])
        if bs <= 0.05: continue
        cx, cy, w, h = coords[0,a]/IMGSZ, coords[1,a]/IMGSZ, coords[2,a]/IMGSZ, coords[3,a]/IMGSZ
        if not (np.isfinite(cx) and np.isfinite(cy) and np.isfinite(w) and np.isfinite(h)): continue
        out.append((bs, b, (cx - w/2, cy - h/2, w, h)))
    return out

def nms(cands, iou_thr):
    cands = sorted(cands, key=lambda c: -c[0])
    kept = []
    for det in cands:
        ok = True
        for k in kept:
            ix = max(0.0, min(det[2][0]+det[2][2], k[2][0]+k[2][2]) - max(det[2][0], k[2][0]))
            iy = max(0.0, min(det[2][1]+det[2][3], k[2][1]+k[2][3]) - max(det[2][1], k[2][1]))
            inter = ix*iy
            uni = det[2][2]*det[2][3] + k[2][2]*k[2][3] - inter
            if uni > 0 and inter/uni > iou_thr:
                ok = False; break
        if ok: kept.append(det)
    return kept

def iou(a, b):
    ix = max(0.0, min(a[0]+a[2], b[0]+b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1]+a[3], b[1]+b[3]) - max(a[1], b[1]))
    inter = ix*iy
    uni = a[2]*a[3] + b[2]*b[3] - inter
    return inter/uni if uni > 0 else 0.0

def load_gt(lab, cls_map):
    gt = []
    if os.path.exists(lab):
        for line in open(lab):
            p = line.split()
            if len(p) >= 5:
                c = int(float(p[0]))
                t = cls_map.get(c)
                if t is None: continue   # 该源类不在7类目标内，丢弃
                cx, cy, w, h = map(float, p[1:5])
                gt.append((t, (cx - w/2, cy - h/2, w, h)))
    return gt

# 收集所有 (detections, gt) 配对
all_dets_s = []   # stretch（App 现状）
all_dets_l = []   # letterbox（训练标准）
for dname, idir, ldir, cls_map in DATASETS:
    for ip in sorted(glob.glob(os.path.join(idir, "*"))):
        if not ip.lower().endswith((".jpg", ".jpeg", ".png", ".bmp")): continue
        base = os.path.splitext(os.path.basename(ip))[0]
        lab = os.path.join(ldir, base + ".txt")
        x_s, x_l, geo = load_image(ip)
        raw_s = sess.run(None, {iname: x_s})[0]
        raw_l = sess.run(None, {iname: x_l})[0]
        if raw_s.ndim == 3: raw_s = raw_s[0]
        elif raw_s.ndim == 2 and raw_s.shape[0] == 8400: raw_s = raw_s.T
        if raw_l.ndim == 3: raw_l = raw_l[0]
        elif raw_l.ndim == 2 and raw_l.shape[0] == 8400: raw_l = raw_l.T
        ds = decode_all(raw_s)
        dl = [(s_, b, to_orig_letterbox(box, geo)) for (s_, b, box) in decode_all(raw_l)]
        gt = load_gt(lab, cls_map)
        all_dets_s.append((dname, base, ds, gt))
        all_dets_l.append((dname, base, dl, gt))

def sweep(all_dets, tag):
    from collections import defaultdict
    gt_count = defaultdict(int)
    for dname, base, dets, gt in all_dets:
        for c, box in gt: gt_count[c] += 1
    print(f"\n########## 预处理 = {tag} ##########")
    THRESHOLDS = [0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.45]
    print(f"{'cls':<10}" + "".join(f"{t:>7}" for t in THRESHOLDS) + "   <- 召回率")
    for c in range(NC):
        if CLASS_NAMES[c] == "good_weld": continue
        if gt_count[c] == 0:
            print(f"{CLASS_NAMES[c]:<10} (无GT,跳过)")
            continue
        row = []
        for t in THRESHOLDS:
            tp = fn = 0
            for dname, base, dets, gt in all_dets:
                gt_boxes = [box for (gc, box) in gt if gc == c]
                cd = [d for d in dets if d[1] == c and d[0] >= t]
                cd = nms(cd, NMS_IOU)
                matched = [False]*len(gt_boxes)
                for bs, b, box in cd:
                    best_i, best_v = -1, 0.0
                    for i, gb in enumerate(gt_boxes):
                        v = iou(box, gb)
                        if v > best_v: best_v = v; best_i = i
                    if best_v >= 0.5 and not matched[best_i]:
                        matched[best_i] = True; tp += 1
                fn += sum(1 for m in matched if not m)
            row.append(tp/(tp+fn) if (tp+fn) else 0.0)
        print(f"{CLASS_NAMES[c]:<10}" + "".join(f"{r*100:>6.1f}%" for r in row))
    # 推荐阈值
    print(f"--- {tag} 推荐阈值（F1最优）---")
    for c in range(NC):
        if CLASS_NAMES[c] == "good_weld" or gt_count[c] == 0: continue
        best = (-1, None, 0, 0)
        for t in THRESHOLDS:
            tp = fp = fn = 0
            for dname, base, dets, gt in all_dets:
                gt_boxes = [box for (gc, box) in gt if gc == c]
                cd = [d for d in dets if d[1] == c and d[0] >= t]
                cd = nms(cd, NMS_IOU)
                matched = [False]*len(gt_boxes); used = [False]*len(cd)
                for bi, (bs, b, box) in enumerate(cd):
                    best_i, best_v = -1, 0.0
                    for i, gb in enumerate(gt_boxes):
                        v = iou(box, gb)
                        if v > best_v: best_v = v; best_i = i
                    if best_v >= 0.5 and not matched[best_i]:
                        matched[best_i] = True; used[bi] = True; tp += 1
                fn += sum(1 for m in matched if not m)
                fp += sum(1 for u in used if not u)
            p = tp/(tp+fp) if (tp+fp) else 0.0
            r = tp/(tp+fn) if (tp+fn) else 0.0
            f1 = 2*p*r/(p+r) if (p+r) else 0.0
            if f1 > best[0]: best = (f1, t, p, r)
        print(f"  {CLASS_NAMES[c]:<10} t={best[1]:.2f} P={best[2]*100:.1f}% R={best[3]*100:.1f}% F1={best[0]:.2f} (GT={gt_count[c]})")

sweep(all_dets_s, "stretch (=App scaleFill 现状)")
sweep(all_dets_l, "letterbox (=训练标准, 建议App改用)")
print("\n自检完成。")
