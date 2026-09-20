#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prepare_dataset.py — 把公开焊缝表面缺陷数据集转换为 Create ML 实例分割(Instance Segmentation)训练格式。

================================================================================
为什么需要它
================================================================================
WeldFatigueChecker 阶段1 计划用 Create ML 训练一个实例分割模型，替换阶段0 的
纯 CV 启发式检测（尤其解决「弧坑裂纹」漏报/误报问题）。Create ML 实例分割要求数据
满足统一的目录与 JSON 结构，而公开数据集多是 YOLO（检测框）或 COCO 格式，本脚本
把它们转换为 Create ML 可直接读取的格式，并把类别名映射到 App 内部的缺陷 type
（undercut / porosity / excess_weld_metal / crack / overlap / linear_misalignment），
这样训练出的模型推理结果能直接喂给 ISO5817Grader.swift 做等级判定。

================================================================================
支持输入
================================================================================
1) YOLO 检测格式（最常见，如 Kaggle surface weld defect 集）
   <root>/images/<split>/xxx.jpg
   <root>/labels/<split>/xxx.txt        # 每行: class_id cx cy w h（归一化 0~1）
   <root>/<names>.txt                   # 每行一个类名，顺序对应 class_id
   或自动在 root 下找 obj.names / classes.txt / data.yaml 的 names

2) COCO 实例分割格式
   <root>/annotations/instances_*.json  # 含 segmentation 多边形（绝对像素坐标）

================================================================================
输出（Create ML Instance Segmentation, Unified JSON）
================================================================================
<out>/
  images/train/*.jpg
  images/valid/*.jpg
  annotations/train/*.json     # 每图一个 unified JSON
  annotations/valid/*.json
  class_labels.txt             # 模型标签（= App 缺陷 type 名），训练时原样填入 .mlmodel

每个 annotations/<img>.json 结构：
{
  "images": [
    {
      "file_name": "xxx.jpg",
      "height": 800, "width": 800, "id": 1,
      "annotations": [
        {"label": "crack", "type": "polygon", "isbbox": false,
         "points": [[x1,y1],[x2,y2],...], "keypoints": []}
      ]
    }
  ]
}

================================================================================
类别映射（数据集类名 → App type）
================================================================================
默认映射见 DEFAULT_MAP（不区分大小写）。未映射的类（如 Good Welding / background）
默认跳过。可用 --map "Crack:crack,Porosity:porosity" 覆盖或补充。
注意：Spatter/Spatters（飞溅）暂映射到 excess_weld_metal；如需独立类别请在 --map 指定。

================================================================================
用法示例
================================================================================
# YOLO 表面集（800x800，已知尺寸时可直接给 --img-size 免去读图）
python3 prepare_dataset.py --source yolo \
    --root ~/datasets/surface-weld-defect-dataset-crak-porosityspatter \
    --names obj.names --img-size 800 800 \
    --out ./createml_weld --splits train valid test

# COCO 实例分割集
python3 prepare_dataset.py --source coco \
    --root ~/datasets/weld-quality-inspection-instance-segmentation \
    --out ./createml_weld --splits train valid

# 自定义映射
python3 prepare_dataset.py --source yolo --root ... --names names.txt \
    --map "Crater Crack:crack,Bad Welding:undercut" --out ./createml_weld
"""

import argparse
import json
import os
import shutil
import sys
import glob

# ---------------------------------------------------------------------------
# 默认类别映射：公开数据集常见类名(小写) -> App 缺陷 type
# 与 WeldFatigueChecker/ISO5817Grader.swift 的 type 字符串保持一致
# ---------------------------------------------------------------------------
DEFAULT_MAP = {
    "crack": "crack",
    "crater crack": "crack",
    "crater_crack": "crack",
    "porosity": "porosity",
    "pore": "porosity",
    "pores": "porosity",
    "spatter": "excess_weld_metal",
    "spatters": "excess_weld_metal",
    "splatter": "excess_weld_metal",
    "excess reinforcement": "excess_weld_metal",
    "excess weld metal": "excess_weld_metal",
    "excess weld": "excess_weld_metal",
    "over reinforcement": "excess_weld_metal",
    "undercut": "undercut",
    "under cut": "undercut",
    "overlap": "overlap",
    "over lap": "overlap",
    "linear misalignment": "linear_misalignment",
    "misalignment": "linear_misalignment",
}

# 这些类视为背景/合格，默认不进入训练目标（可经 --map 强制纳入）
SKIP_DEFAULT = {"good welding", "good", "background", "ok", "none", "no defect", "合格"}


def norm(s: str) -> str:
    return s.strip().lower().replace("_", " ")


def parse_map_arg(s: str):
    """解析 --map "A:crack,B:porosity" -> {norm(a): b}"""
    m = {}
    if not s:
        return m
    for pair in s.split(","):
        if ":" not in pair:
            sys.exit(f"[错误] --map 格式应为 '源类名:目标type'，收到: {pair}")
        a, b = pair.split(":", 1)
        m[norm(a)] = b.strip()
    return m


def resolve_names(root: str, names_arg: str):
    """找到 YOLO 的 names 文件并读为 [类名,...]"""
    if names_arg:
        p = names_arg if os.path.isabs(names_arg) else os.path.join(root, names_arg)
        if not os.path.exists(p):
            sys.exit(f"[错误] names 文件不存在: {p}")
        with open(p, encoding="utf-8") as f:
            return [ln.strip() for ln in f if ln.strip()]
    # 自动探测
    for cand in ["obj.names", "classes.txt", "names.txt"]:
        p = os.path.join(root, cand)
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                return [ln.strip() for ln in f if ln.strip()]
    # data.yaml 里的 names:
    yamls = glob.glob(os.path.join(root, "*.yaml")) + glob.glob(os.path.join(root, "*.yml"))
    for yp in yamls:
        try:
            txt = open(yp, encoding="utf-8").read()
        except Exception:
            continue
        if "names:" in txt:
            # 简易解析 names: [a, b, c] 或 names:\n  - a\n  - b
            import re
            block = txt[txt.index("names:"):]
            items = re.findall(r"[\"']?([A-Za-z][A-Za-z0-9 _\-]*)[\"']?", block)
            # 去掉 names 自身与后续非类字段
            if items:
                return [i for i in items if i.lower() not in ("names", "nc")]
    sys.exit("[错误] 未找到 names 文件，请用 --names 指定（每行一个类名）。")


def get_image_size(path: str, fallback):
    """读取图像尺寸；失败则用 fallback (w,h) 或报错。"""
    try:
        from PIL import Image
        with Image.open(path) as im:
            return im.width, im.height
    except Exception:
        if fallback:
            return fallback
        sys.exit(f"[错误] 无法读取图像尺寸且未提供 --img-size: {path}\n"
                 f"       请安装 Pillow (pip install pillow) 或用 --img-size W H。")


def box_to_polygon(x1, y1, x2, y2):
    """把矩形框转 4 点多边形（顺时针）。坐标已为绝对像素。"""
    return [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]


def polygon_from_yolo_line(parts, w, h):
    """YOLO 行: class cx cy bw bh(归一化) -> (type_or_None, polygon绝对像素)"""
    cid = int(float(parts[0]))
    cx, cy, bw, bh = (float(v) for v in parts[1:5])
    x1 = (cx - bw / 2) * w
    y1 = (cy - bh / 2) * h
    x2 = (cx + bw / 2) * w
    y2 = (cy + bh / 2) * h
    return x1, y1, x2, y2


def convert_yolo(args, names, cls_map):
    """返回 (per_image_annotations, used_labels_set)
    per_image_annotations: {split: [(img_file, w, h, [ann_dict])]}
    """
    splits = args.splits
    result = {s: [] for s in splits}
    used_labels = set()
    label_count = {}

    for split in splits:
        img_dir = os.path.join(args.root, "images", split)
        lbl_dir = os.path.join(args.root, "labels", split)
        if not os.path.isdir(img_dir):
            print(f"  [提示] split={split} 无 images 目录，跳过: {img_dir}")
            continue
        img_files = sorted(glob.glob(os.path.join(img_dir, "*.*")))
        if not img_files:
            print(f"  [提示] split={split} 无图像文件，跳过。")
            continue
        for ip in img_files:
            base = os.path.splitext(os.path.basename(ip))[0]
            lp = os.path.join(lbl_dir, base + ".txt")
            w, h = get_image_size(ip, args.img_size)
            anns = []
            if os.path.exists(lp):
                with open(lp, encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        parts = line.split()
                        if len(parts) < 5:
                            continue
                        cid = int(float(parts[0]))
                        if cid < 0 or cid >= len(names):
                            print(f"  [警告] {lp} 类别id {cid} 超出 names 范围，跳过该行")
                            continue
                        src_name = names[cid]
                        key = norm(src_name)
                        # 解析目标 type
                        tgt = cls_map.get(key)
                        if tgt is None:
                            tgt = DEFAULT_MAP.get(key)
                        if tgt is None:
                            if key in SKIP_DEFAULT:
                                continue
                            # 未映射也未在跳过列表 -> 仍保留为原始名，避免丢数据
                            print(f"  [警告] 类 '{src_name}' 未映射，按原名保留为标签 '{key}'")
                            tgt = key
                        x1, y1, x2, y2 = polygon_from_yolo_line(parts, w, h)
                        x1, y1, x2, y2 = max(0.0, x1), max(0.0, y1), min(float(w), x2), min(float(h), y2)
                        anns.append({
                            "label": tgt,
                            "type": "polygon",
                            "isbbox": False,
                            "points": box_to_polygon(x1, y1, x2, y2),
                            "keypoints": [],
                        })
                        used_labels.add(tgt)
                        label_count[tgt] = label_count.get(tgt, 0) + 1
            result[split].append((ip, base, w, h, anns))
    return result, used_labels, label_count


def convert_coco(args, cls_map):
    """COCO instances_*.json -> 同上结构（多边形已是绝对像素）。"""
    result = {s: [] for s in args.splits}
    used_labels = set()
    label_count = {}
    ann_files = sorted(glob.glob(os.path.join(args.root, "annotations", "instances_*.json")))
    if not ann_files:
        ann_files = sorted(glob.glob(os.path.join(args.root, "**", "instances_*.json"), recursive=True))
    if not ann_files:
        sys.exit("[错误] COCO 模式未找到 annotations/instances_*.json")
    # 图像 id -> 文件名/尺寸
    for af in ann_files:
        data = json.load(open(af, encoding="utf-8"))
        cat_map = {c["id"]: c["name"] for c in data.get("categories", [])}
        img_map = {im["id"]: im for im in data.get("images", [])}
        split = os.path.basename(af).replace("instances_", "").replace(".json", "")
        if split not in result:
            split = args.splits[0] if args.splits else "train"
        # 收集该文件内 annotations
        by_img = {}
        for a in data.get("annotations", []):
            by_img.setdefault(a["image_id"], []).append(a)
        for im in data.get("images", []):
            iid = im["id"]
            fn = im["file_name"]
            w = im.get("width", 0)
            h = im.get("height", 0)
            base_name = os.path.splitext(fn)[0]
            # 找源图
            src = None
            for cand in [os.path.join(args.root, "images", split, fn),
                         os.path.join(args.root, "images", fn),
                         os.path.join(args.root, fn)]:
                if os.path.exists(cand):
                    src = cand
                    break
            anns = []
            for a in by_img.get(iid, []):
                src_name = cat_map.get(a["category_id"], "unknown")
                key = norm(src_name)
                tgt = cls_map.get(key) or DEFAULT_MAP.get(key)
                if tgt is None:
                    if key in SKIP_DEFAULT:
                        continue
                    tgt = key
                seg = a.get("segmentation")
                pts = None
                if isinstance(seg, list) and seg and isinstance(seg[0], list):
                    # 多边形列表 [[x1,y1,x2,y2,...]]
                    flat = seg[0]
                    pts = [[flat[i], flat[i + 1]] for i in range(0, len(flat) - 1, 2)]
                elif isinstance(seg, list) and seg and isinstance(seg[0], (int, float)):
                    flat = seg[0] if isinstance(seg[0], list) else seg
                    pts = [[flat[i], flat[i + 1]] for i in range(0, len(flat) - 1, 2)]
                if not pts:
                    # 退化为 bbox
                    bb = a.get("bbox", [0, 0, 0, 0])
                    pts = box_to_polygon(bb[0], bb[1], bb[0] + bb[2], bb[1] + bb[3])
                anns.append({
                    "label": tgt, "type": "polygon", "isbbox": False,
                    "points": pts, "keypoints": [],
                })
                used_labels.add(tgt)
                label_count[tgt] = label_count.get(tgt, 0) + 1
            result[split].append((src, base_name, w, h, anns))
    return result, used_labels, label_count


def write_outputs(out, per_split, used_labels, args):
    os.makedirs(out, exist_ok=True)
    img_out = os.path.join(out, "images")
    ann_out = os.path.join(out, "annotations")
    os.makedirs(img_out, exist_ok=True)
    os.makedirs(ann_out, exist_ok=True)
    total = 0
    for split, items in per_split.items():
        s_img = os.path.join(img_out, split)
        s_ann = os.path.join(ann_out, split)
        os.makedirs(s_img, exist_ok=True)
        os.makedirs(s_ann, exist_ok=True)
        for src, base_name, w, h, anns in items:
            # 复制图像（若源图存在）
            if src and os.path.exists(src):
                shutil.copy2(src, os.path.join(s_img, os.path.basename(src)))
                img_name = os.path.basename(src)
            else:
                img_name = base_name + ".jpg"  # 占位（无源图时）
            js = {
                "images": [{
                    "file_name": img_name,
                    "height": int(h), "width": int(w), "id": total + 1,
                    "annotations": anns,
                }]
            }
            with open(os.path.join(s_ann, base_name + ".json"), "w", encoding="utf-8") as f:
                json.dump(js, f, ensure_ascii=False, indent=2)
            total += 1
    # 写 class_labels.txt（排序，稳定）
    labels_sorted = sorted(used_labels)
    with open(os.path.join(out, "class_labels.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(labels_sorted) + "\n")
    return total, labels_sorted


def main():
    ap = argparse.ArgumentParser(description="焊缝表面缺陷数据集 -> Create ML 实例分割格式")
    ap.add_argument("--source", choices=["yolo", "coco"], required=True)
    ap.add_argument("--root", required=True, help="数据集根目录")
    ap.add_argument("--names", default=None, help="YOLO names 文件路径")
    ap.add_argument("--img-size", nargs=2, type=int, default=None,
                    metavar=("W", "H"), help="YOLO 全图同尺寸时直接给定(免读图)")
    ap.add_argument("--out", required=True, help="输出目录")
    ap.add_argument("--splits", nargs="+", default=["train", "valid", "test"])
    ap.add_argument("--map", default=None, help="附加映射 '源类:type,源类:type'")
    args = ap.parse_args()

    cls_map = parse_map_arg(args.map or "")

    print(f"[信息] 源格式={args.source}  根={args.root}  输出={args.out}")
    if args.source == "yolo":
        names = resolve_names(args.root, args.names)
        print(f"[信息] 类别({len(names)}): {names}")
        per_split, used, counts = convert_yolo(args, names, cls_map)
    else:
        per_split, used, counts = convert_coco(args, cls_map)

    total, labels = write_outputs(args.out, per_split, used, args)
    print(f"[完成] 共写出 {total} 张图像标注")
    print(f"[完成] 使用标签({len(labels)}): {labels}")
    print("[统计] 各类实例数:")
    for k in sorted(counts):
        print(f"        {k:<22} {counts[k]}")
    print(f"[完成] class_labels.txt 已写入 {args.out}")
    print("[下一步] 用 Xcode 的 Create ML app 新建 Instance Segmentation 项目，")
    print("         Training/Validation 各选 images+annotations 目录，标签用 class_labels.txt。")


if __name__ == "__main__":
    main()
