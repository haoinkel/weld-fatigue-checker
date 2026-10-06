# -*- coding: utf-8 -*-
"""本地 dry-run：验证表面模型 notebook 的数据准备链路（下载+重映射+动态类目）。
不跑训练（本机无 GPU）。用真实本地 steel-tube-dataset-all（= steel-pipe 源）+ 下载 Zenodo。
跑通即证明 notebook cell 1-7 在魔搭也能跑。
"""
import os, shutil, glob, random, zipfile, subprocess, hashlib, sys

SURFACE_ROOT = os.path.abspath("surface_dryrun")
os.makedirs(SURFACE_ROOT, exist_ok=True)

TARGET_CLASSES = ["porosity", "crack", "undercut", "overlap", "spatters", "good_weld", "burn_through"]
STEELPIPE_NAMES = ["air-hole", "broken-arc", "bite-edge", "crack",
                   "hollow-bead", "overlap", "slag-inclusion", "unfused"]
REMAP = {
    "porosity": 0, "qikong": 0, "气孔": 0, "air-hole": 0, "air_hole": 0, "pores": 0, "pore": 0,
    "crack": 1, "裂纹": 1, "crazing": 1, "broken-arc": 1, "broken_arc": 1, "crater crack": 1,
    "undercut": 2, "yaobian": 2, "咬边": 2, "bite-edge": 2, "bite_edge": 2,
    "overlap": 3, "excess reinforcement": 3, "余高": 3, "焊瘤": 3,
    "deposits": 3, "hollow-bead": 3, "hollow_bead": 3, "geometric defect": 3, "geometric": 3,
    "spatters": 4, "spatter": 4, "飞溅": 4,
    "good weld": 5, "good welding": 5, "good": 5, "合格": 5, "合格焊道": 5,
    "burn-through": 6, "burn through": 6, "烧穿": 6,
    "slag inclusion": None, "slag-inclusion": None, "slag": None,
    "unfused": None, "lack of fusion": None, "lack-of-fusion": None,
    "discontinuities": None, "stains": None, "improper_fusion": None,
}

def unzip_if_needed(zip_path, out_dir):
    if os.path.exists(out_dir):
        return
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(out_dir)
    print("解压 ->", out_dir)

# ---- 1) Zenodo（下载 + md5） ----
zenodo_url = "https://zenodo.org/records/17402020/files/Final_Dataset_YOLO_Test.zip?download=1"
zenodo_zip = os.path.join(SURFACE_ROOT, "zenodo.zip")
ZENODO_MD5 = "d38507e847924cbda9fb007d89a6643e"
if not os.path.exists(zenodo_zip):
    print("下载 Zenodo ...")
    subprocess.run(["wget", "-q", "-O", zenodo_zip, zenodo_url], check=False)
def md5_of(p):
    h = hashlib.md5()
    with open(p, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''): h.update(c)
    return h.hexdigest()
if os.path.exists(zenodo_zip):
    print("Zenodo md5", md5_of(zenodo_zip), "期望", ZENODO_MD5,
          "OK" if md5_of(zenodo_zip) == ZENODO_MD5 else "MISMATCH!")
unzip_if_needed(zenodo_zip, os.path.join(SURFACE_ROOT, "zenodo"))

# ---- 2) steel-pipe：用本地真实集 ----
LOCAL_SP = r"C:\Users\Administrator\Desktop\log\steel-tube-dataset-all\steel-tube-dataset-all"
sp_dir = os.path.join(SURFACE_ROOT, "steelpipe")
if not os.path.isdir(sp_dir):
    print("软链本地 steel-pipe 集 ->", sp_dir)
    # 复制 yolo 子目录（含 images/labels）即可，体积小
    src_yolo = os.path.join(LOCAL_SP, "yolo")
    if os.path.isdir(src_yolo):
        shutil.copytree(src_yolo, sp_dir, dirs_exist_ok=True)
    else:
        shutil.copytree(LOCAL_SP, sp_dir, dirs_exist_ok=True)
print("steelpipe 内容：", os.listdir(sp_dir)[:10])

# ---- 3) ingest（复制 notebook cell-6 逻辑） ----
import xml.etree.ElementTree as ET
def read_source_class_names(folder):
    for name in ("data.yaml", "dataset.yaml", "data.yml", "classes.txt"):
        p = os.path.join(folder, name)
        if os.path.exists(p):
            with open(p) as f:
                return [l.strip() for l in f if l.strip()]
    return None
def voc_to_yolo(xml_path, img_w, img_h):
    out = []
    try:
        tree = ET.parse(xml_path); root = tree.getroot()
        for obj in root.findall("object"):
            nm = obj.find("name").text.strip().lower()
            bb = obj.find("bndbox")
            xmin = float(bb.find("xmin").text); ymin = float(bb.find("ymin").text)
            xmax = float(bb.find("xmax").text); ymax = float(bb.find("ymax").text)
            out.append((nm, ((xmin+xmax)/2)/img_w, ((ymin+ymax)/2)/img_h,
                        (xmax-xmin)/img_w, (ymax-ymin)/img_h))
    except Exception as e:
        print("  VOC 解析失败", xml_path, e)
    return out
def ingest(source_name, root_dir, class_names):
    stat = {"mapped": 0, "dropped": 0, "raw_classes": {}, "images": 0}
    cand_txt, cand_xml = [], []
    for base in ("labels", "Label", "Annotations", "XML"):
        d = os.path.join(root_dir, base)
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith(".txt"): cand_txt.append(os.path.join(d, f))
                elif f.endswith(".xml"): cand_xml.append(os.path.join(d, f))
    if not cand_txt:
        for f in glob.glob(os.path.join(root_dir, "**", "*.txt"), recursive=True):
            if os.path.basename(f) not in ("classes.txt",): cand_txt.append(f)
    img_dir = None
    for base in ("images", "JPEGImages", "Image", "img"):
        d = os.path.join(root_dir, base)
        if os.path.isdir(d): img_dir = d; break
    if img_dir is None: img_dir = root_dir
    targets_img = os.path.join(SURFACE_ROOT, "merged", "images")
    targets_lbl = os.path.join(SURFACE_ROOT, "merged", "labels")
    os.makedirs(targets_img, exist_ok=True); os.makedirs(targets_lbl, exist_ok=True)
    def handle(items):
        new_lines = []
        for raw, xc, yc, w, h in items:
            stat["raw_classes"][raw] = stat["raw_classes"].get(raw, 0) + 1
            idx = REMAP.get(raw.lower())
            if idx is None:
                stat["dropped"] += 1; continue
            new_lines.append(f"{idx} {xc:.6f} {yc:.6f} {w:.6f} {h:.6f}")
            stat["mapped"] += 1
        return new_lines
    def find_img(label_path):
        stem = os.path.splitext(os.path.basename(label_path))[0]
        for ext in (".jpg", ".jpeg", ".png", ".bmp"):
            p = os.path.join(img_dir, stem + ext)
            if os.path.exists(p): return p
        hits = glob.glob(os.path.join(img_dir, "**", stem + ".*"), recursive=True)
        for h in hits:
            if h.lower().endswith((".jpg", ".jpeg", ".png", ".bmp")): return h
        return None
    for txt in cand_txt:
        items = []
        with open(txt) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 5: continue
                try: cid = int(parts[0])
                except:
                    raw = parts[0].lower(); cid = -1
                if cid >= 0 and class_names is not None and cid < len(class_names):
                    raw = class_names[cid].lower()
                elif cid >= 0:
                    raw = str(cid)
                else:
                    raw = parts[0].lower()
                items.append((raw, float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4])))
        new_lines = handle(items)
        if new_lines:
            ip = find_img(txt)
            if ip:
                shutil.copy(ip, os.path.join(targets_img, os.path.basename(ip)))
                with open(os.path.join(targets_lbl, os.path.splitext(os.path.basename(ip))[0] + ".txt"), "w") as o:
                    o.write("\n".join(new_lines) + "\n")
                stat["images"] += 1
    for xml in cand_xml:
        try:
            tree = ET.parse(xml); root = tree.getroot()
            sz = root.find("size")
            iw = float(sz.find("width").text); ih = float(sz.find("height").text)
            items = voc_to_yolo(xml, iw, ih)
        except Exception:
            items = []
        new_lines = handle(items)
        if new_lines:
            ip = find_img(xml)
            if ip:
                shutil.copy(ip, os.path.join(targets_img, os.path.basename(ip)))
                with open(os.path.join(targets_lbl, os.path.splitext(os.path.basename(ip))[0] + ".txt"), "w") as o:
                    o.write("\n".join(new_lines) + "\n")
                stat["images"] += 1
    print(f"[{source_name}] 图={stat['images']} 映射框={stat['mapped']} 丢弃框={stat['dropped']}")
    print(f"   原始类名: {sorted(stat['raw_classes'])}")
    return stat

for src_name, src_root in [("zenodo", os.path.join(SURFACE_ROOT, "zenodo")),
                           ("steelpipe", sp_dir)]:
    if not os.path.isdir(src_root):
        print(f"[{src_name}] 跳过"); continue
    cn = STEELPIPE_NAMES if src_name == "steelpipe" else read_source_class_names(src_root)
    ingest(src_name, src_root, cn)

# ---- 4) 动态类目统计 ----
merged_lbl = os.path.join(SURFACE_ROOT, "merged", "labels")
present = set()
for lb in glob.glob(os.path.join(merged_lbl, "*.txt")):
    for line in open(lb):
        p = line.split()
        if p: present.add(int(p[0]))
present = sorted(present)
print("\n=== 动态类目 ===")
print("实际出现 idx：", present)
print("对应类：", [TARGET_CLASSES[i] for i in present])
from collections import Counter
cnt = Counter()
for lb in glob.glob(os.path.join(merged_lbl, "*.txt")):
    for line in open(lb):
        p = line.split()
        if p: cnt[int(p[0])] += 1
print("每类框数：", {TARGET_CLASSES[i]: cnt.get(i, 0) for i in present})
print("\nDRY-RUN OK -> 表面模型数据链路可跑（免费源覆盖:", [TARGET_CLASSES[i] for i in present], "）")
