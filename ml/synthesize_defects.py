#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
synthesize_defects.py — 焊缝缺陷合成粘贴增强（SISD / SIMD）
=====================================================================
针对「少数类样本少（crack / undercut / unfused）」这一核心瓶颈，参考
Eng. Appl. AI 2024 的实例合成粘贴思路：把真实缺陷实例裁下，随机粘贴到
干净焊道背景上，并「自动生成」对应的 YOLO 标注，从而成倍放大少数类样本。

特点：
  - 单实例粘贴（SISD）+ 随机尺度/旋转/亮度抖动（SIMD 多失真），贴近真实。
  - 输出为标准 YOLO 格式，写入 raw_synth/，由 weld_train.py 的
    SOURCES 自动并入训练（目录不存在时自动跳过，不破坏现有流程）。
  - 标签 class id = TARGET_CLASSES 中的序号，与训练 data.yaml 完全一致。

依赖：Pillow（torch/ultralytics 已自带）。无 GPU 要求，笔记本即可跑。

用法：
  python synthesize_defects.py --src raw raw_mine --out raw_synth --num 400 --seed 42
  python synthesize_defects.py --src raw --out raw_synth --num 200 --per-img 2 --min-scale 0.5
"""
import argparse, hashlib, math, os, random, sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageEnhance

TARGET_CLASSES = ['porosity', 'crack', 'undercut', 'overlap', 'unfused']
IMG_EXTS = ('.jpg', '.jpeg', '.png', '.bmp', '.webp')
PAD_RATIO = 0.25          # 裁缺陷时四周留白比例，避免切到边缘
MAX_TRIES = 20            # 单次粘贴避免越界的尝试次数

# ---------------------------------------------------------------------------
# 1. 读取源：图片 + 对应 YOLO 标注，建立「缺陷实例池」与「背景池」
# ---------------------------------------------------------------------------
def load_source(root):
    root = Path(root)
    img_map, lbl_map = {}, {}
    if not root.is_dir():
        return [], []
    for r, _, fs in os.walk(root):
        for f in fs:
            fl = f.lower()
            base = os.path.splitext(f)[0]
            if fl.endswith(IMG_EXTS):
                img_map[base] = os.path.join(r, f)
            elif fl.endswith('.txt'):
                lbl_map[base] = os.path.join(r, f)
    instances, backgrounds = [], []
    for base, ip in img_map.items():
        ann = lbl_map.get(base)
        if not ann or not os.path.exists(ann):
            continue
        img = Image.open(ip).convert('RGB')
        W, H = img.size
        boxes = []
        with open(ann, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                p = line.split()
                if len(p) < 5:
                    continue
                try:
                    cid = int(p[0])
                except ValueError:
                    continue
                if not (0 <= cid < len(TARGET_CLASSES)):
                    continue
                cx, cy, w, h = (float(x) for x in p[1:5])
                boxes.append((cid, cx, cy, w, h))
        if not boxes:
            continue
        backgrounds.append((img, W, H))
        for (cid, cx, cy, w, h) in boxes:
            # 像素坐标 + 留白裁剪
            x0, y0 = cx - w / 2, cy - h / 2
            x1, y1 = cx + w / 2, cy + h / 2
            px0 = max(0, int((x0 - PAD_RATIO * w) * W))
            py0 = max(0, int((y0 - PAD_RATIO * h) * H))
            px1 = min(W, int((x1 + PAD_RATIO * w) * W))
            py1 = min(H, int((y1 + PAD_RATIO * h) * H))
            if px1 - px0 < 8 or py1 - py0 < 8:
                continue
            crop = img.crop((px0, py0, px1, py1))
            bw, bh = crop.size
            # 归一化「原图尺度下」的框（用于缩放后换算）
            norm_box = (w, h)  # 相对原图的比例，粘贴时按新尺寸缩放
            instances.append({'img': crop, 'cls': cid, 'ow': bw, 'oh': bh,
                              'nw': norm_box[0], 'nh': norm_box[1]})
    return instances, backgrounds


# ---------------------------------------------------------------------------
# 2. 粘贴一张合成图
# ---------------------------------------------------------------------------
def paste_one(instances, backgrounds, per_img, min_scale, max_scale):
    bg_img, bgW, bgH = random.choice(backgrounds)
    canvas = bg_img.copy()
    labels = []
    for _ in range(per_img):
        inst = random.choice(instances)
        # 目标尺寸：以背景短边的比例随机缩放，保证不超框
        base = inst['ow'] / bgW  # 原缺陷相对背景宽的比例
        scale = random.uniform(min_scale, max_scale) * (base if base > 0 else 1.0)
        scale = min(scale, 0.6)  # 上限，避免一个缺陷占满整图
        new_w = max(8, int(inst['ow'] * scale * (bgW / inst['ow'])))
        new_w = int(inst['ow'] * min(scale, 0.6))
        new_h = int(inst['oh'] * (new_w / inst['ow'])) if inst['ow'] else new_w
        if new_w < 6 or new_h < 6:
            continue
        try:
            frag = inst['img'].resize((new_w, new_h), Image.LANCZOS)
        except Exception:
            continue
        # 亮度/对比度轻微抖动（SIMD 失真）
        frag = ImageEnhance.Brightness(frag).enhance(random.uniform(0.85, 1.15))
        frag = ImageEnhance.Contrast(frag).enhance(random.uniform(0.9, 1.1))
        # 随机旋转
        angle = random.uniform(-10, 10)
        frag = frag.rotate(angle, expand=True, resample=Image.BICUBIC)
        fw, fh = frag.size
        # 随机落点（保证完整在图内）
        for _ in range(MAX_TRIES):
            x = random.randint(0, max(0, bgW - fw))
            y = random.randint(0, max(0, bgH - fh))
            break
        else:
            continue
        canvas.paste(frag, (x, y))
        # 新框（归一化，以原缺陷相对背景比例 × 缩放，并换算到画布）
        nw = inst['nw'] * min(scale, 0.6)
        nh = inst['nh'] * min(scale, 0.6)
        cx = (x + fw / 2) / bgW
        cy = (y + fh / 2) / bgH
        nw = min(1.0, fw / bgW)
        nh = min(1.0, fh / bgH)
        labels.append(f"{inst['cls']} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
    return canvas, labels


# ---------------------------------------------------------------------------
# 3. 主流程
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', nargs='+', default=['raw'],
                    help='含 images/labels 或平铺图片+txt 的源目录（可多个）')
    ap.add_argument('--out', default='raw_synth', help='输出目录（默认 raw_synth）')
    ap.add_argument('--num', type=int, default=400, help='生成合成图数量')
    ap.add_argument('--per-img', type=int, default=2, help='每张图粘贴缺陷数 1~3')
    ap.add_argument('--min-scale', type=float, default=0.5)
    ap.add_argument('--max-scale', type=float, default=1.6)
    ap.add_argument('--seed', type=int, default=42)
    args = ap.parse_args()
    random.seed(args.seed); np.random.seed(args.seed)

    instances, backgrounds = [], []
    for s in args.src:
        ins, bgs = load_source(s)
        print(f'[源] {s}: {len(ins)} 个缺陷实例, {len(bgs)} 张背景')
        instances += ins; backgrounds += bgs
    if not instances or not backgrounds:
        print('[错误] 未找到可用源数据（需图片+对应 YOLO txt）。')
        sys.exit(1)

    out = Path(args.out)
    (out / 'images').mkdir(parents=True, exist_ok=True)
    (out / 'labels').mkdir(parents=True, exist_ok=True)
    (out / 'classes.txt').write_text('\n'.join(TARGET_CLASSES) + '\n', encoding='utf-8')

    ok = 0
    for i in range(args.num):
        canvas, labels = paste_one(instances, backgrounds,
                                   random.randint(1, args.per_img),
                                   args.min_scale, args.max_scale)
        if not labels:
            continue
        name = f'weld_syn_{i:05d}'
        canvas.save(out / 'images' / f'{name}.jpg', quality=92)
        (out / 'labels' / f'{name}.txt').write_text('\n'.join(labels) + '\n', encoding='utf-8')
        ok += 1

    print(f'[完成] 生成 {ok} 张合成图 → {out}/（images + labels + classes.txt）')
    print('        重新运行 weld_train.py 即自动并入训练（raw_synth 不存在时自动跳过）。')


if __name__ == '__main__':
    main()
