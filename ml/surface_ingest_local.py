# -*- coding: utf-8 -*-
"""
surface_ingest_local.py
本地验证版：把已下载的 9929(CSDN) + Zenodo 表面数据集，重映射成 6 类表面模型训练集。
- 自动发现数据集根目录（在 DATA_ROOT 下递归搜索标记目录）
- 9929: JPEGImages/*.jpg + labels/*.txt + labels/classes.txt
- Zenodo: images/ + labels/ + dataset_test.yaml
- 输出 merged/ 与 dataset/data.yaml，并打印每类框数
此脚本逻辑与 modelscope_train_surface.ipynb 内嵌的吸收逻辑一致（先本地验证，再上云训练）。
"""
import os, glob, shutil, random, collections, yaml, argparse

# 目标 6 类（顺序固定，iOS 端按此索引接线）
TARGET_CLASSES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut"]

def discover_9929(root):
    """搜索含 JPEGImages + labels/classes.txt 的目录"""
    for dirpath, _, files in os.walk(root):
        if "JPEGImages" in os.listdir(dirpath) if os.path.isdir(os.path.join(dirpath, "JPEGImages")) else False:
            if os.path.exists(os.path.join(dirpath, "labels", "classes.txt")):
                return dirpath
    return None

def discover_zenodo(root):
    """搜索含 dataset_test.yaml 的目录"""
    for dirpath, _, files in os.walk(root):
        if "dataset_test.yaml" in files:
            return dirpath
    return None

def ingest_9929(src_root, out_img, out_lbl, counter):
    """9929 CSDN: classes.txt 顺序 = [bad_welding,crack,defect,excess_reinforcement,good_welding,porosity,spatter,welding_line]"""
    remap = {5: 0, 1: 1, 3: 2, 6: 3, 4: 4}  # 源idx -> 目标idx
    img_dir = os.path.join(src_root, "JPEGImages")
    lbl_dir = os.path.join(src_root, "labels")
    n_img = n_lbl = 0
    for img in os.listdir(img_dir):
        if not img.lower().endswith((".jpg", ".jpeg", ".png", ".bmp")):
            continue
        base = os.path.splitext(img)[0]
        src_lbl = os.path.join(lbl_dir, base + ".txt")
        if not os.path.exists(src_lbl):
            continue
        out_lines = []
        for ln in open(src_lbl, encoding="utf-8", errors="ignore"):
            p = ln.split()
            if len(p) < 5:
                continue
            try:
                ci = int(p[0])
            except ValueError:
                continue
            if ci not in remap:
                continue  # 丢弃 bad_welding/defect/welding_line
            out_lines.append(f"{remap[ci]} {' '.join(p[1:])}\n")
            counter[remap[ci]] += 1
        if not out_lines:
            continue  # 该图所有框都被丢弃，不收
        shutil.copy(os.path.join(img_dir, img), os.path.join(out_img, img))
        with open(os.path.join(out_lbl, base + ".txt"), "w") as f:
            f.writelines(out_lines)
        n_img += 1; n_lbl += 1
    print(f"[9929] 吸收 {n_img} 图 / {n_lbl} 标注")
    return n_img

def ingest_zenodo(src_root, out_img, out_lbl, counter):
    """Zenodo: dataset_test.yaml names=[weld-defect-det, slag inclusion, spatter, undercut] -> idx 0,1,2,3"""
    remap = {3: 5, 2: 3}  # undercut->5, spatter->3（slag inclusion/ weld-defect-det 丢弃）
    img_dir = os.path.join(src_root, "images")
    lbl_dir = os.path.join(src_root, "labels")
    n_img = n_lbl = 0
    for lbl in os.listdir(lbl_dir):
        if not lbl.lower().endswith(".txt") or lbl.startswith("._"):
            continue
        base = os.path.splitext(lbl)[0]
        src_img = None
        for ext in (".jpg", ".jpeg", ".png", ".bmp"):
            cand = os.path.join(img_dir, base + ext)
            if os.path.exists(cand):
                src_img = cand; break
        if src_img is None:
            continue
        out_lines = []
        for ln in open(os.path.join(lbl_dir, lbl), encoding="utf-8", errors="ignore"):
            p = ln.split()
            if len(p) < 5:
                continue
            try:
                ci = int(p[0])
            except ValueError:
                continue
            if ci not in remap:
                continue
            out_lines.append(f"{remap[ci]} {' '.join(p[1:])}\n")
            counter[remap[ci]] += 1
        if not out_lines:
            continue
        shutil.copy(src_img, os.path.join(out_img, os.path.basename(src_img)))
        with open(os.path.join(out_lbl, base + ".txt"), "w") as f:
            f.writelines(out_lines)
        n_img += 1; n_lbl += 1
    print(f"[Zenodo] 吸收 {n_img} 图 / {n_lbl} 标注")
    return n_img

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=r"D:\workbuddy\workbuddy学习\surfacedetecttrain")
    ap.add_argument("--out", default=r"D:\workbuddy\workbuddy学习\surfacedetecttrain\merged")
    args = ap.parse_args()

    r9929 = discover_9929(args.root)
    rzen = discover_zenodo(args.root)
    print("9929 root:", r9929)
    print("Zenodo root:", rzen)
    if not r9929 and not rzen:
        print("ERROR: 未找到任何数据集"); return

    out_img = os.path.join(args.out, "images")
    out_lbl = os.path.join(args.out, "labels")
    shutil.rmtree(args.out, ignore_errors=True)
    os.makedirs(out_img, exist_ok=True); os.makedirs(out_lbl, exist_ok=True)

    counter = collections.Counter()
    total = 0
    if r9929:
        total += ingest_9929(r9929, out_img, out_lbl, counter)
    if rzen:
        total += ingest_zenodo(rzen, out_img, out_lbl, counter)

    # 切分 90/10
    imgs = [f for f in os.listdir(out_img) if f.lower().endswith((".jpg", ".jpeg", ".png", ".bmp"))]
    random.seed(42); random.shuffle(imgs)
    n_val = max(1, int(len(imgs) * 0.1))
    val, train = imgs[:n_val], imgs[n_val:]
    for split, lst in (("train", train), ("val", val)):
        di = os.path.join(args.out, "..", "dataset", split, "images")
        dl = os.path.join(args.out, "..", "dataset", split, "labels")
        os.makedirs(di, exist_ok=True); os.makedirs(dl, exist_ok=True)
        for f in lst:
            shutil.copy(os.path.join(out_img, f), os.path.join(di, f))
            lb = os.path.splitext(f)[0] + ".txt"
            if os.path.exists(os.path.join(out_lbl, lb)):
                shutil.copy(os.path.join(out_lbl, lb), os.path.join(dl, lb))
    print(f"\n总图数: {len(imgs)}  train={len(train)} val={len(val)}")
    print("每类框数:")
    for i, name in enumerate(TARGET_CLASSES):
        print(f"  {i} {name}: {counter.get(i,0)}")

    data = {"path": os.path.abspath(os.path.join(args.out, "..", "dataset")),
            "train": "train/images", "val": "val/images",
            "nc": len(TARGET_CLASSES), "names": TARGET_CLASSES}
    with open(os.path.join(args.out, "..", "dataset", "data.yaml"), "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
    print("\ndata.yaml 已写: ", os.path.join(args.out, "..", "dataset", "data.yaml"))

if __name__ == "__main__":
    main()
