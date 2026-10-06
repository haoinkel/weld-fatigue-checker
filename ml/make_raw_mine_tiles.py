# -*- coding: utf-8 -*-
"""raw_mine 切图预处理：把大图按原始分辨率切成 640x640 tile，解决
1) 尺度问题：全图 letterbox 到 640 后缺陷只有 56px（棚拍域是 137px），模型学不到；
2) 样本量问题：40 张 / 57 框只占训练集 0.11%，切图后样本量 x10，叠加 notebook 的 x5 域增广达 ~18%。

输出 surfacedetecttrain/raw_mine_tiles/（images/ + labels/ + classes.txt 七类序），
build_surface_notebook 的 find_dataset_roots 会自动发现并合并，无需改 notebook。

用法: python make_raw_mine_tiles.py [--src .../raw_mine] [--out .../raw_mine_tiles]
"""
import os, random, argparse
from PIL import Image, ImageOps

IMGSZ = 640          # tile 尺寸（=推理输入尺寸）
STRIDE = 512         # 步长（重叠 128px，避免缺陷被切断丢失）
MIN_KEEP_FRAC = 0.30 # 框被切边后剩余面积 <30% 则丢弃
EMPTY_KEEP = 0.12    # 空白 tile 保留概率（硬负例：干净漆面/照亮区，压误报）
SEED = 42

# 7 类目标序（与 build_surface_notebook.py TARGET_CLASSES 一致）
TARGET = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]
# raw_mine 5 类序 -> 7 类目标序
RAW5 = ["porosity", "crack", "undercut", "overlap", "unfused"]
CMAP = {RAW5.index(n): TARGET.index(n) for n in RAW5}

ap = argparse.ArgumentParser()
ap.add_argument("--src", default=r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine")
ap.add_argument("--out", default=r"D:/workbuddy/workbuddy学习/surfacedetecttrain/raw_mine_tiles")
args = ap.parse_args()

img_dir = os.path.join(args.src, "images")
lbl_dir = os.path.join(args.src, "labels")
out_img = os.path.join(args.out, "images")
out_lbl = os.path.join(args.out, "labels")
os.makedirs(out_img, exist_ok=True); os.makedirs(out_lbl, exist_ok=True)
random.seed(SEED)

def tile_positions(total, size, stride):
    """生成 x/y 起点，末尾对齐图像边界保证覆盖。"""
    if total <= size:
        return [0]
    pos = list(range(0, total - size + 1, stride))
    if pos[-1] != total - size:
        pos.append(total - size)
    return pos

n_tiles = n_with = n_empty = 0
cls_count = {i: 0 for i in range(7)}
for fname in sorted(os.listdir(img_dir)):
    if not fname.lower().endswith((".jpg", ".jpeg", ".png")):
        continue
    base = os.path.splitext(fname)[0]
    lbl_path = os.path.join(lbl_dir, base + ".txt")
    boxes = []  # (cls, cx, cy, w, h) 归一化
    if os.path.exists(lbl_path):
        for ln in open(lbl_path):
            p = ln.split()
            if len(p) >= 5:
                boxes.append((CMAP[int(float(p[0]))], *map(float, p[1:5])))

    img = ImageOps.exif_transpose(Image.open(os.path.join(img_dir, fname))).convert("RGB")
    W, H = img.size
    # 短边不足 640 的图：整体放大到 640（本数据集不存在，保险处理）
    if min(W, H) < IMGSZ:
        s = IMGSZ / min(W, H)
        img = img.resize((max(IMGSZ, int(W*s)), max(IMGSZ, int(H*s))), Image.BILINEAR)
        W, H = img.size
        boxes = [(c, cx*W/W, cy*H/H, w, h) for c, cx, cy, w, h in boxes]  # 尺寸未变时不变

    # 归一化 -> 像素
    pboxes = [(c, (cx-w/2)*W, (cy-h/2)*H, w*W, h*H) for c, cx, cy, w, h in boxes]

    for ty in tile_positions(H, IMGSZ, STRIDE):
        for tx in tile_positions(W, IMGSZ, STRIDE):
            tile = img.crop((tx, ty, tx+IMGSZ, ty+IMGSZ))
            out_lines = []
            for c, bx, by, bw, bh in pboxes:
                # 与 tile 求交
                ix0, iy0 = max(bx, tx), max(by, ty)
                ix1, iy1 = min(bx+bw, tx+IMGSZ), min(by+bh, ty+IMGSZ)
                if ix1 <= ix0 or iy1 <= iy0:
                    continue
                cx, cy = (bx+bw/2), (by+bh/2)
                if not (tx <= cx < tx+IMGSZ and ty <= cy < ty+IMGSZ):
                    continue  # 中心不在本 tile
                if (ix1-ix0)*(iy1-iy0) < MIN_KEEP_FRAC * bw * bh:
                    continue  # 被切太多
                ncx = (cx-tx)/IMGSZ; ncy = (cy-ty)/IMGSZ
                nw = min(bw, IMGSZ)/IMGSZ; nh = min(bh, IMGSZ)/IMGSZ
                out_lines.append(f"{c} {ncx:.6f} {ncy:.6f} {nw:.6f} {nh:.6f}")
                cls_count[c] += 1
            keep = bool(out_lines) or random.random() < EMPTY_KEEP
            if not keep:
                continue
            tname = f"{base}_t{tx//STRIDE}_{ty//STRIDE}.jpg"
            tile.save(os.path.join(out_img, tname), quality=92)
            with open(os.path.join(out_lbl, base.replace(".txt","") + f"_t{tx//STRIDE}_{ty//STRIDE}.txt"), "w") as f:
                f.write("\n".join(out_lines) + ("\n" if out_lines else ""))
            n_tiles += 1
            n_with += bool(out_lines); n_empty += not out_lines

with open(os.path.join(args.out, "classes.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(TARGET) + "\n")

print(f"完成: 共 {n_tiles} tiles（含框 {n_with} + 硬负例 {n_empty}），来自 40 张原图")
print("各类框数:", {TARGET[k]: v for k, v in cls_count.items() if v})
print(f"输出: {args.out}")
