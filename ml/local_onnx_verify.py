# ============================================================================
# 本地自测：用 last.onnx + 训练图，复刻 App decodeRawOutput 逻辑，验证能否检出缺陷
# 完全对齐 MLDefectDetector.swift::decodeRawOutput：
#   - 输入 letterbox 到 640，RGB，/255
#   - 输出 (1,9,8400)：cx,cy,w,h 在 640 空间（/640 得归一化），分数已 sigmoid
#   - argmax 取类 + 阈值过滤 + NMS(iou 0.6)
# 同时与 yolo/labels/val2021 真值比对，算检出率
# ============================================================================
import numpy as np
from PIL import Image
import onnxruntime as ort
import glob, os, json

CLASSES = ["porosity", "crack", "undercut", "overlap", "unfused"]
# App 标准档分级阈值（MLDefectDetector.swift 行51-58）
THRESH = {"porosity": 0.45, "crack": 0.30, "undercut": 0.30, "overlap": 0.30, "unfused": 0.40}
IOU_NMS = 0.6
IMGSZ = 640
LOW = 0.05  # 诊断：低分候选下限（与 App 一致）

ROOT = r"C:/Users/Administrator/Desktop/log/steel-tube-dataset-all/steel-tube-dataset-all/yolo"
IMG_DIR = os.path.join(ROOT, "images", "val2021")
LBL_DIR = os.path.join(ROOT, "labels", "val2021")
ONNX = r"C:/Users/Administrator/Desktop/log/last.onnx"

sess = ort.InferenceSession(ONNX)
iname = sess.get_inputs()[0].name

def letterbox(im, new=640):
    h, w = im.shape[:2]
    r = min(new / h, new / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    im = np.array(Image.fromarray(im).resize((nw, nh), Image.BILINEAR))
    top, bottom = (new - nh) // 2, new - nh - (new - nh) // 2
    left, right = (new - nw) // 2, new - nw - (new - nw) // 2
    pad = np.full((new, new, 3), 114, dtype=np.uint8)
    pad[top:top + nh, left:left + nw] = im
    return pad, (r, left, top)

def preprocess(path):
    im = np.array(Image.open(path).convert("RGB"))          # RGB，对齐训练
    h0, w0 = im.shape[:2]
    x, (r, left, top) = letterbox(im)
    x = x.astype(np.float32) / 255.0
    x = x.transpose(2, 0, 1)[None]                          # NCHW
    return x, (r, left, top), (w0, h0)

def iou(a, b):  # a,b: [x1,y1,x2,y2] 归一化
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    if ix <= 0 or iy <= 0: return 0.0
    inter = ix * iy
    uni = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter
    return inter / uni if uni > 0 else 0.0

def nms(boxes, iou_t):
    boxes = sorted(boxes, key=lambda b: b[2], reverse=True)
    kept = []
    for b in boxes:
        if all(iou(b[0], k[0]) < iou_t for k in kept):
            kept.append(b)
    return kept

def decode(out, geo, orig):
    scale, L, T = geo            # preprocess 返回 (scale,left,top)
    W0, H0 = orig               # 原图 (w0, h0)
    out = np.ascontiguousarray(out).reshape(9, 8400)   # (9,8400) 通道优先
    A = 8400
    cands = []
    raw = []
    for a in range(A):
        best, bs = -1, 0.0
        for c in range(5):
            s = float(out[4 + c, a])   # 类分数在通道 4..8
            if s > bs: bs, best = s, c
        if bs <= 0.01: continue
        cls = CLASSES[best]
        raw.append((cls, bs))
        if bs < LOW: continue
        cx, cy, w, h = (float(out[0, a])/IMGSZ, float(out[1, a])/IMGSZ,
                        float(out[2, a])/IMGSZ, float(out[3, a])/IMGSZ)
        # 反 letterbox：640空间 → 减pad → /scale → 原图像素 → 归一化
        cx_px = (cx*IMGSZ - L)/scale; cy_px = (cy*IMGSZ - T)/scale
        w_px = (w*IMGSZ)/scale;        h_px = (h*IMGSZ)/scale
        x1, y1 = cx_px - w_px/2, cy_px - h_px/2
        x2, y2 = cx_px + w_px/2, cy_px + h_px/2
        nx1, ny1, nx2, ny2 = x1/W0, y1/H0, x2/W0, y2/H0
        rect = [max(0,min(1,nx1)), max(0,min(1,ny1)), max(0,min(1,nx2)), max(0,min(1,ny2))]
        if rect[2]-rect[0] <= 0 or rect[3]-rect[1] <= 0: continue
        if bs >= THRESH[cls]:
            cands.append((rect, cls, bs))
        else:
            raw.append((cls, bs))  # 低分也计入诊断
    kept = nms(cands, IOU_NMS)
    return kept, sorted(raw, key=lambda t: -t[1])

def load_gt(lbl):
    if not os.path.exists(lbl): return []
    g = []
    for line in open(lbl):
        p = line.split()
        if len(p) < 5: continue
        c = int(float(p[0])); cx, cy, w, h = map(float, p[1:5])
        g.append((c, [cx-w/2, cy-h/2, cx+w/2, cy+h/2]))
    return g

def main():
    imgs = sorted(glob.glob(os.path.join(IMG_DIR, "*.jpg")) +
                  glob.glob(os.path.join(IMG_DIR, "*.png")))
    print(f"val2021 图片: {len(imgs)} 张，跑前 50 张做自测\n")
    total_gt = matched = fp = 0
    for path in imgs[:50]:
        base = os.path.splitext(os.path.basename(path))[0]
        x, geo, orig = preprocess(path)
        out = sess.run(None, {iname: x})[0]
        kept, raw = decode(out, geo, orig)
        gt = load_gt(os.path.join(LBL_DIR, base + ".txt"))
        total_gt += len(gt)
        # 匹配：真值框被某检测框 IoU>=0.5 且类对
        used = [False]*len(gt)
        for rect, cls, sc in kept:
            ci = CLASSES.index(cls)
            for gi, (gc, gr) in enumerate(gt):
                if not used[gi] and gc == ci and iou(rect, gr) >= 0.5:
                    used[gi] = True; matched += 1; break
        fp += sum(1 for rect, cls, sc in kept
                  if not any(gc == CLASSES.index(cls) and iou(rect, gr) >= 0.5 for gc, gr in gt))
        det_s = " | ".join(f"{c}:{s:.2f}" for _, c, s in kept) or "无"
        gt_s = " | ".join(CLASSES[c] for c, _ in gt) or "无"
        print(f"[{base}] 真值={gt_s}  检出({len(kept)})={det_s}")
    print(f"\n=== 汇总（前50张）===")
    print(f"真值框总数: {total_gt} | 匹配检出: {matched} | 检出率: {matched/total_gt*100:.1f}%" if total_gt else "无真值")
    print(f"误检(背景/错类框): {fp}")

if __name__ == "__main__":
    main()
