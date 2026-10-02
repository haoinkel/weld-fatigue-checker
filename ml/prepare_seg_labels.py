#!/usr/bin/env python3
# prepare_seg_labels.py
# 优化点 B(v2) 准备脚本：把现有 YOLO *检测* 标签（class cx cy w h 归一化）转换为
# *实例分割* 标签（class x1 y1 x2 y2 x3 y3 x4 y4 归一化多边形）。
#
# 思路：以 bbox 四角作为多边形（矩形 mask）。这是 bootsrap 实例分割的实用技巧——
# 无需人工标注 polygon 即可立即训练 yolov8-seg；后续用模型自预测 mask 伪标签或人工精修提升。
#
# 用法：
#   python ml/prepare_seg_labels.py \
#       --src ml/raw_mine/labels \
#       --dst ml/dataset_weld/labels_seg
#
# 输出：与 src 同名 .txt，每行 9 个浮点数：class + 4 角点(归一化)。

import argparse
import os


def bbox_to_polygon(cx, cy, w, h):
    x1 = max(0.0, min(1.0, cx - w / 2.0))
    y1 = max(0.0, min(1.0, cy - h / 2.0))
    x2 = max(0.0, min(1.0, cx + w / 2.0))
    y2 = max(0.0, min(1.0, cy + h / 2.0))
    return [x1, y1, x2, y1, x2, y2, x1, y2]


def convert_file(src_path, dst_path):
    with open(src_path, "r", encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    out = []
    for ln in lines:
        parts = ln.split()
        if len(parts) < 5:
            continue
        cls, cx, cy, w, h = parts[0], float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4])
        poly = bbox_to_polygon(cx, cy, w, h)
        out.append(" ".join([str(cls)] + [f"{p:.6f}" for p in poly]))
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + ("\n" if out else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="源检测标签目录(.txt, 每行 class cx cy w h)")
    ap.add_argument("--dst", required=True, help="输出分割标签目录")
    args = ap.parse_args()
    files = [f for f in os.listdir(args.src) if f.endswith(".txt")]
    n = 0
    for f in files:
        convert_file(os.path.join(args.src, f), os.path.join(args.dst, f))
        n += 1
    print(f"已转换 {n} 个标签 -> {args.dst}")


if __name__ == "__main__":
    main()
