# -*- coding: utf-8 -*-
"""生成表面焊接缺陷训练 notebook（ModelScope / 魔搭 形态）。
运行：python ml/build_surface_notebook.py
产物：ml/modelscope_train_surface.ipynb

设计要点（2026-10-05 改造：通用 drop-in 开口）：
  - 由「写死三源 + 源索引→目标索引映射」改为「按类名映射 + 多文件夹自动发现」。
  - 每个数据集自带 classes.txt（或 Zenodo 的 dataset_test.yaml names），
    管道读其「源 idx→名字」，再用 CLASS_ALIASES 把名字映射到 7 个标准类。
  - 自动发现 surfacedetecttrain/ 下「所有」满足结构的数据集根目录
    （images/+labels/+classes.txt 的通用型、JPEGImages+labels/classes.txt 的 9929 型、
     含 dataset_test.yaml 的 Zenodo 型），不再只取第一个。
  - 以后上传新采集批次：丢进 surfacedetecttrain/collected/<批次名>/，放好
    images/ labels/ classes.txt（类名用标准 7 类或别名），直接重跑 notebook，零改代码。
  - 唯一硬性边界：新增第 8 类缺陷需改 TARGET_CLASSES 并联动 iOS 端接线（不在此管道内）。
"""
import json, os

ROOT = os.path.dirname(os.path.abspath(__file__))
NB = os.path.join(ROOT, "modelscope_train_surface.ipynb")

cells = []

def md(text):
    cells.append({"cell_type": "markdown", "metadata": {}, "source": text.splitlines(keepends=True)})

def code(text):
    cells.append({"cell_type": "code", "metadata": {}, "execution_count": None,
                  "outputs": [], "source": text.splitlines(keepends=True)})

# ---------------------------------------------------------------- markdown
md(
"""# 表面焊接缺陷 YOLOv8 训练（可见光 / ModelScope 魔搭）

> 运行环境：ModelScope（魔搭）Notebook，PyTorch 预装、36h 免费 GPU。
> 训练一个**全新的可见光表面缺陷模型**，与原 X 光模型（120 轮，5 类内部缺陷）互不干扰、独立部署。

## 目标 7 类（顺序固定，iOS 端按此索引接线）
| idx | 类 | 说明 | 主力数据源 |
|---|---|---|---|
| 0 | porosity | 气孔（表面开口） | 9929 + raw_mine + 后续采集 |
| 1 | crack | 裂纹 | 9929 + raw_mine + 后续采集 |
| 2 | overlap | 余高/焊瘤（= excess_reinforcement） | 9929 + raw_mine + 后续采集 |
| 3 | spatters | 飞溅 | 9929 + Zenodo + 后续采集 |
| 4 | good_weld | 合格焊道（负类，压误报） | 9929 |
| 5 | undercut | 咬边 | Zenodo(34框) + raw_mine(10框)，已复制增广 |
| 6 | unfused | 未熔合（表面可见缺口） | 仅 raw_mine（10框，已随域增广） |

> **为什么是 7 类**：9929 CSDN 集（9929 图）提供 porosity/crack/overlap/spatters/good_weld 五类大样本；Zenodo 提供 undercut/spatter；**raw_mine（40 张现场实拍）提供 porosity/crack/undercut/overlap/unfused，其中 unfused 仅它有——用户拍板加为第 7 类（安全优先，宁可弱学不可漏报）**。`burn_through` 无免费源，暂不纳入。`bad_welding/defect/welding_line/slag inclusion/weld-defect-det` 为泛类或焊缝线或无关类，丢弃。

## 关于 raw_mine / 后续采集（现场自采域锚点）
40 张手持实拍可见光表面图（raw_mine），**与 App 真机部署输入域最接近**。相对 9929（棚拍）占比极小（~0.4%），
故对其做 **×5 离线复制增广**（原/水平翻转/垂直翻转/双向翻转，共 200 张），把现场域权重提到 ~2%。
⚠️ 切分采用**组感知**（同一原图的所有增广副本进同一 split），防止增广泄漏导致 val 虚高。
**后续任何同 7 类的新采集批次**，只要结构一致（见下），会被同样自动发现并采用同套 ×5 域增广。

## 数据准备（你已上传，本 notebook 不联网）
把本地 `surfacedetecttrain/` 整目录上传到魔搭 Notebook 工作区。Notebook 会**自动递归发现所有数据集根目录**，无需逐个登记。

### 支持的数据集结构（三选一）
1. **通用 YOLO（推荐用于自采/后续批次）**：
   ```
   <根目录>/
   ├── images/        # *.jpg/*.png
   ├── labels/        # 与图同名的 *.txt（标准 YOLO：class_id cx cy w h）
   └── classes.txt    # 每行一个类名（顺序任意，按名字映射到 7 类）
   ```
2. **9929 CSDN 型（VOC+YOLO）**：含 `JPEGImages/` + `labels/classes.txt`。
3. **Zenodo 型**：含 `dataset_test.yaml`（用其 `names` 字段）。

> 想新增一批采集数据：**在 `surfacedetecttrain/` 下新建任意名字的子目录（如 `collected/2026_11_batch1/`），
> 按上面的「通用 YOLO」结构放好 `images/ labels/ classes.txt`，类名用标准 7 类或别名（见 cell 2 的 CLASS_ALIASES），
> 直接重跑 notebook 即可，零改代码。** 不要放进 `_merge_check` 或 `merged/dataset/runs`（会被自动排除）。
> 管道会对**内容完全相同的副本自动去重**（如解压残留的嵌套同名目录），无需手动清理。

## 类名别名表（CLASS_ALIASES）
源数据集里叫别的名字也能正确归到 7 类；映射为 `None` 表示丢弃：
- porosity→porosity, crack→crack, overlap→overlap, unfused→unfused, undercut→undercut
- excess_reinforcement→overlap, good_welding→good_weld
- spatter→spatters, spatters→spatters
- bad_welding→丢弃, defect→丢弃, welding_line→丢弃, slag inclusion→丢弃, weld-defect-det→丢弃

## 你要做的
1. 上传 `surfacedetecttrain/` 到魔搭工作区当前目录（含 9929 / zenodo / raw_mine，以及任何后续 collected 批次）。
2. 跑通后导出 `WeldDefectSurfaceModel.mlpackage`（nms=False，w8a16），与 X 光模型分开，iOS 端按图源分流。
"""
)

# ---------------------------------------------------------------- cell 1
code(
"""# 1) 环境 + 依赖
!pip install -q ultralytics pyyaml
import os, shutil, glob, random, collections, yaml
import torch
print("torch", torch.__version__, "| cuda", torch.cuda.is_available())

# 数据根目录：当前目录下的 surfacedetecttrain（你上传的文件夹名）
DATA_ROOT = os.path.abspath("surfacedetecttrain")
assert os.path.isdir(DATA_ROOT), f"未找到 {DATA_ROOT}，请先上传 surfacedetecttrain/ 到工作区"
print("DATA_ROOT =", DATA_ROOT)
"""
)

# ---------------------------------------------------------------- cell 2
code(
"""# 2) 目标类目 + 类名别名映射（按「名字」映射，与源数据集类别顺序解耦）
TARGET_CLASSES = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]

# 源类名 -> 目标类名（None = 丢弃）
CLASS_ALIASES = {
    "porosity": "porosity",
    "crack": "crack",
    "overlap": "overlap",
    "excess_reinforcement": "overlap",
    "unfused": "unfused",
    "undercut": "undercut",
    "good_weld": "good_weld",
    "good_welding": "good_weld",
    "spatter": "spatters",
    "spatters": "spatters",
    # 丢弃的泛类/无关类
    "bad_welding": None,
    "defect": None,
    "welding_line": None,
    "slag inclusion": None,
    "weld-defect-det": None,
}

# 增广强度（可改）：通用型/自采小批次做 ×(1+DOMAIN_AUG)=5 域增广；Zenodo 仅 undercut 复制 UNDERCUT_AUG 倍
DOMAIN_AUG = 4
UNDERCUT_AUG = 8

print("目标类目:", TARGET_CLASSES)
print("别名表条目数:", len(CLASS_ALIASES))
"""
)

# ---------------------------------------------------------------- cell 3
code(
"""# 3) 自动发现「所有」数据集根目录（多文件夹，不再只取第一个）
EXCLUDE_SEGMENTS = ("_merge_check", "merged", "dataset", "runs")

def find_dataset_roots(root):
    \"\"\"返回所有满足结构的数据集根目录（绝对路径）。\"\"\"
    found = []
    for dp, dns, fns in os.walk(root):
        # 跳过输出/中间目录及其子树
        if any(seg in EXCLUDE_SEGMENTS for seg in dp.split(os.sep)):
            dns[:] = []; continue
        # (a) 通用 YOLO：images/ + labels/ + 根 classes.txt
        if (os.path.isdir(os.path.join(dp, "images"))
                and os.path.isdir(os.path.join(dp, "labels"))
                and "classes.txt" in fns):
            found.append(dp); continue
        # (b) 9929 VOC+YOLO：JPEGImages/ + labels/classes.txt
        if (os.path.isdir(os.path.join(dp, "JPEGImages"))
                and os.path.exists(os.path.join(dp, "labels", "classes.txt"))):
            found.append(dp); continue
        # (c) Zenodo：dataset_test.yaml
        if "dataset_test.yaml" in fns:
            found.append(dp); continue
    return found

def classify(root):
    \"\"\"判定数据集类型：voc9929 / zenodo / generic\"\"\"
    if os.path.isdir(os.path.join(root, "JPEGImages")):
        return "voc9929"
    if "dataset_test.yaml" in os.listdir(root):
        return "zenodo"
    return "generic"

def _label_dir(root, kind):
    if kind == "voc9929":
        return os.path.join(root, "labels")
    if kind == "zenodo":
        return os.path.join(root, "labels")
    return os.path.join(root, "labels")

def dedupe_roots(roots):
    \"\"\"去掉内容完全相同的重复根目录（如解压残留的嵌套同名副本）。
    判定：两目录的标注文件名集合完全相同 -> 视为同一数据集，仅保留路径最短的一个。\"\"\"
    info = []
    for r in roots:
        d = _label_dir(r, classify(r))
        names = set(os.listdir(d)) if os.path.isdir(d) else set()
        info.append((r, names))
    kept = []
    for r, names in info:
        is_dup = False
        for kr, knames in kept:
            if names and knames and names == knames:
                is_dup = True
                break
        if not is_dup:
            kept.append((r, names))
    dropped = [r for r, _ in info if r not in [k for k, _ in kept]]
    if dropped:
        print("去重丢弃的重复根目录:")
        for d in dropped:
            print("  -", d)
    return [r for r, _ in kept]

def read_names(root, kind):
    \"\"\"返回源类别名列表（按源 idx 顺序）\"\"\"
    if kind == "voc9929":
        with open(os.path.join(root, "labels", "classes.txt"), encoding="utf-8", errors="ignore") as f:
            return [l.strip() for l in f if l.strip()]
    if kind == "zenodo":
        with open(os.path.join(root, "dataset_test.yaml"), encoding="utf-8", errors="ignore") as f:
            data = yaml.safe_load(f)
        return list(data["names"])
    # generic
    with open(os.path.join(root, "classes.txt"), encoding="utf-8", errors="ignore") as f:
        return [l.strip() for l in f if l.strip()]

ROOTS = find_dataset_roots(DATA_ROOT)
ROOTS = dedupe_roots(ROOTS)
print(f"去重后保留 {len(ROOTS)} 个数据集根目录:")
for r in ROOTS:
    print("  ", classify(r), "->", r)
assert ROOTS, "没有发现任何数据集，检查上传路径/目录结构"
"""
)

# ---------------------------------------------------------------- cell 4
code(
"""# 4) 合并 + 按类名映射 + 各类增广
merged_img = os.path.join(DATA_ROOT, "merged", "images")
merged_lbl = os.path.join(DATA_ROOT, "merged", "labels")
shutil.rmtree(os.path.join(DATA_ROOT, "merged"), ignore_errors=True)
os.makedirs(merged_img, exist_ok=True); os.makedirs(merged_lbl, exist_ok=True)

counter = collections.Counter()

def map_line(line, src_names):
    \"\"\"一行 YOLO 标注 -> (映射后行, 目标idx) 或 None（丢弃/非法）\"\"\"
    p = line.split()
    if len(p) < 5:
        return None
    try:
        ci = int(p[0])
    except ValueError:
        return None
    if ci >= len(src_names):
        return None
    name = src_names[ci].strip()
    tname = CLASS_ALIASES.get(name)
    if tname is None:
        return None
    tidx = TARGET_CLASSES.index(tname)
    return f"{tidx} {' '.join(p[1:])}", tidx

def img_ext(path):
    return os.path.splitext(path)[1].lower()

def find_image(img_dir, base):
    for ext in (".jpg", ".jpeg", ".png", ".bmp"):
        c = os.path.join(img_dir, base + ext)
        if os.path.exists(c):
            return c
    return None

def ingest_voc(root, src_names):
    img_dir = os.path.join(root, "JPEGImages")
    lbl_dir = os.path.join(root, "labels")
    n = 0
    for img in os.listdir(img_dir):
        if not img.lower().endswith((".jpg", ".jpeg", ".png", ".bmp")):
            continue
        base = os.path.splitext(img)[0]
        src_lbl = os.path.join(lbl_dir, base + ".txt")
        if not os.path.exists(src_lbl):
            continue
        out = []
        for ln in open(src_lbl, encoding="utf-8", errors="ignore"):
            m = map_line(ln, src_names)
            if m is None:
                continue
            out.append(m[0]); counter[m[1]] += 1
        if not out:
            continue
        shutil.copy(os.path.join(img_dir, img), os.path.join(merged_img, img))
        with open(os.path.join(merged_lbl, base + ".txt"), "w") as f:
            f.writelines(l + "\\n" for l in out)
        n += 1
    print(f"[voc9929] {n} 图")
    return n

def ingest_zenodo(root, src_names, undercut_aug=UNDERCUT_AUG):
    \"\"\"Zenodo 仅 undercut(34框) 弱势，复制增广 undercut 图 undercut_aug 倍（带flip）缓解失衡。\"\"\"
    img_dir = os.path.join(root, "images")
    lbl_dir = os.path.join(root, "labels")
    n = 0
    for lbl in os.listdir(lbl_dir):
        if not lbl.lower().endswith(".txt") or lbl.startswith("._"):
            continue
        base = os.path.splitext(lbl)[0]
        src_img = find_image(img_dir, base)
        if src_img is None:
            continue
        out = []
        for ln in open(os.path.join(lbl_dir, lbl), encoding="utf-8", errors="ignore"):
            m = map_line(ln, src_names)
            if m is None:
                continue
            out.append(m[0]); counter[m[1]] += 1
        if not out:
            continue
        shutil.copy(src_img, os.path.join(merged_img, os.path.basename(src_img)))
        with open(os.path.join(merged_lbl, base + ".txt"), "w") as f:
            f.writelines(l + "\\n" for l in out)
        n += 1
        if any(l.split()[0] == "5" for l in out):   # 含 undercut(idx5) 才增广
            for k in range(undercut_aug):
                nb = f"{base}_aug{k}{img_ext(src_img)}"
                shutil.copy(src_img, os.path.join(merged_img, nb))
                aug = []
                for l in out:
                    pp = l.split(); pp[1] = f"{1.0 - float(pp[1]):.6f}"; aug.append(" ".join(pp))
                with open(os.path.join(merged_lbl, os.path.splitext(nb)[0] + ".txt"), "w") as f:
                    f.writelines(l + "\\n" for l in aug)
                n += 1
    print(f"[zenodo] {n} 图（含 undercut 增广）")
    return n

def ingest_generic(root, src_names, domain_aug=DOMAIN_AUG):
    \"\"\"通用 YOLO / 自采域锚点：整图复制增广 ×(1+domain_aug)=5 倍。
    增广副本文件名带 _augK，切分时按组归属同一 split（见 cell 5）。含 unfused(idx6)。\"\"\"
    img_dir = os.path.join(root, "images")
    lbl_dir = os.path.join(root, "labels")
    n = 0
    variants = [("o", False, False)] + [(f"aug{i}", True, False) for i in range(domain_aug)]
    for img in os.listdir(img_dir):
        if not img.lower().endswith((".jpg", ".jpeg", ".png", ".bmp")):
            continue
        base = os.path.splitext(img)[0]
        src_lbl = os.path.join(lbl_dir, base + ".txt")
        if not os.path.exists(src_lbl):
            continue
        out = []
        for ln in open(src_lbl, encoding="utf-8", errors="ignore"):
            m = map_line(ln, src_names)
            if m is None:
                continue
            out.append(m[0]); counter[m[1]] += 1
        if not out:
            continue
        ext = img_ext(img)
        for suffix, fl, fu in variants:
            nb = base if suffix == "o" else f"{base}_{suffix}"
            shutil.copy(os.path.join(img_dir, img), os.path.join(merged_img, nb + ext))
            lines = []
            for l in out:
                pp = l.split()
                xc, yc = float(pp[1]), float(pp[2])
                if fl: xc = 1.0 - xc
                if fu: yc = 1.0 - yc
                pp[1] = f"{xc:.6f}"; pp[2] = f"{yc:.6f}"
                lines.append(" ".join(pp))
            with open(os.path.join(merged_lbl, nb + ".txt"), "w") as f:
                f.writelines(l + "\\n" for l in lines)
            n += 1
    print(f"[generic:{os.path.basename(root)}] {n} 图（含 ×{1+domain_aug} 域增广）")
    return n

# 遍历所有发现的数据集
for r in ROOTS:
    kind = classify(r)
    names = read_names(r, kind)
    if kind == "voc9929":
        ingest_voc(r, names)
    elif kind == "zenodo":
        ingest_zenodo(r, names)
    else:
        ingest_generic(r, names)

print("\\n合并后每类框数:")
for i, name in enumerate(TARGET_CLASSES):
    print(f"  {i} {name}: {counter.get(i, 0)}")
"""
)

# ---------------------------------------------------------------- cell 5
code(
"""# 5) 切分 train/val + 生成 data.yaml（组感知：同一原图的增广副本同 split，防泄漏）
import re
def group_of(fname):
    \"\"\"去掉 _augK 后缀得到原图组名\"\"\"
    return re.sub(r"_aug\\d+$", "", os.path.splitext(fname)[0])

imgs = [f for f in os.listdir(merged_img) if f.lower().endswith((".jpg", ".jpeg", ".png", ".bmp"))]
groups = sorted({group_of(f) for f in imgs})
random.seed(42); random.shuffle(groups)
n_val_g = max(1, int(len(groups) * 0.1))
val_groups = set(groups[:n_val_g])

train, val = [], []
for f in imgs:
    (val if group_of(f) in val_groups else train).append(f)
print(f"原图组={len(groups)} val组={n_val_g} -> train={len(train)} val={len(val)}")
for split, lst in (("train", train), ("val", val)):
    di = os.path.join(DATA_ROOT, "dataset", split, "images")
    dl = os.path.join(DATA_ROOT, "dataset", split, "labels")
    os.makedirs(di, exist_ok=True); os.makedirs(dl, exist_ok=True)
    for f in lst:
        shutil.copy(os.path.join(merged_img, f), os.path.join(di, f))
        lb = os.path.splitext(f)[0] + ".txt"
        if os.path.exists(os.path.join(merged_lbl, lb)):
            shutil.copy(os.path.join(merged_lbl, lb), os.path.join(dl, lb))

data = {"path": os.path.abspath(os.path.join(DATA_ROOT, "dataset")),
        "train": "train/images", "val": "val/images",
        "nc": len(TARGET_CLASSES), "names": TARGET_CLASSES}
with open(os.path.join(DATA_ROOT, "dataset", "data.yaml"), "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
print(open(os.path.join(DATA_ROOT, "dataset", "data.yaml")).read())

cnt = collections.Counter()
for split in ("train", "val"):
    for lb in glob.glob(os.path.join(DATA_ROOT, "dataset", split, "labels", "*.txt")):
        for line in open(lb):
            p = line.split()
            if p: cnt[int(p[0])] += 1
print("每类框数:", {TARGET_CLASSES[i]: cnt.get(i, 0) for i in range(len(TARGET_CLASSES))})
"""
)

# ---------------------------------------------------------------- cell 6
code(
"""# 6) 训练（YOLOv8n，120 轮；少数类靠 copy_paste+mixup+翻转提召回）
from ultralytics import YOLO

# ===== 续训开关（新增样本后重跑时使用）=====
# 机制：仍喂【全量数据】（旧+新一起），只是初始化权重不同 —— 安全，不触发灾难性遗忘。
#   AUTO_RESUME = True  → 若工作区存在 last_surface_best.pt（上次自动缓存）则自动续训，否则从头
#   PREV_MODEL  手动路径 → 优先级最高（设了就强制用它，忽略 AUTO_RESUME）
# ⚠️ 硬约束：若本次数据集的类别数/顺序(nc/names)与上次不同（如新增第 8 类），
#           必须 AUTO_RESUME=False 且 PREV_MODEL=None，强制从头训，否则权重与类别对不上会报错。
AUTO_RESUME = True
PREV_MODEL  = None   # 例："/path/to/last_surface_best.pt" 或 "runs/surface_weld_yolov8n/weights/best.pt"

LAST_BEST = os.path.join(DATA_ROOT, "last_surface_best.pt")
if PREV_MODEL and os.path.exists(PREV_MODEL):
    init_weights = PREV_MODEL
    print("使用手动指定权重续训：", init_weights)
elif AUTO_RESUME and os.path.exists(LAST_BEST):
    init_weights = LAST_BEST
    print("检测到上次权重，自动续训：", init_weights)
else:
    init_weights = "yolov8n.pt"
    print("从头全量训练（yolov8n.pt 预训练权重）")
print("本次初始化权重:", init_weights)

model = YOLO(init_weights)
results = model.train(
    data=os.path.join(DATA_ROOT, "dataset", "data.yaml"),
    imgsz=640, batch=16, epochs=120, patience=30,
    name="surface_weld_yolov8n",
    copy_paste=0.4, mixup=0.1, fliplr=0.5, flipud=0.1,
    degrees=5.0, scale=0.5, shear=1.0, perspective=0.0005,
    hsv_s=0.9, hsv_v=0.5,
    project=os.path.join(DATA_ROOT, "runs"),
    exist_ok=True,
)
print("训练完成 ->", os.path.join(DATA_ROOT, "runs", "surface_weld_yolov8n", "weights", "best.pt"))
"""
)

# ---------------------------------------------------------------- cell 7
code(
"""# 7) 导出 CoreML（nms=False + w8a16，与已验证的 X 光模型管线一致；真机用路径 A 裸输出解码）
best = os.path.join(DATA_ROOT, "runs", "surface_weld_yolov8n", "weights", "best.pt")
m = YOLO(best)
exp = m.export(format="coreml", nms=False, quantize="w8a16", imgsz=640)
print("导出原始产物：", exp)

src_pkg = exp if str(exp).endswith(".mlpackage") else str(exp)
dst_pkg = os.path.join(DATA_ROOT, "WeldDefectSurfaceModel.mlpackage")
if os.path.isdir(dst_pkg):
    shutil.rmtree(dst_pkg)
if os.path.isdir(src_pkg):
    shutil.move(src_pkg, dst_pkg)
print("表面模型包 ->", dst_pkg)

with open(os.path.join(dst_pkg, "surface_classes.txt"), "w") as f:
    f.write("\\n".join(TARGET_CLASSES))
print("类目已记录（按顺序）：", TARGET_CLASSES)

# 缓存一份固定名权重副本，供下次续训开关（AUTO_RESUME=True）自动读取
import shutil as _sh
_last_best = os.path.join(DATA_ROOT, "last_surface_best.pt")
if os.path.exists(best):
    _sh.copy(best, _last_best)
    print("已缓存上次权重供续训：", _last_best)
"""
)

# ---------------------------------------------------------------- cell 8
code(
"""# 8) 收尾：打包 + 提示
import zipfile
pkg_zip = os.path.join(DATA_ROOT, "WeldDefectSurfaceModel.zip")
if os.path.isdir(dst_pkg):
    with zipfile.ZipFile(pkg_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(dst_pkg):
            for fn in files:
                fp = os.path.join(root, fn)
                z.write(fp, os.path.relpath(fp, dst_pkg))
    print("已打包：", pkg_zip, "大小(字节)=", os.path.getsize(pkg_zip))
print("下一步：把 WeldDefectSurfaceModel.mlpackage 接入 iOS 工程，"
      "App 端按图源（X光片→X光模型 / 可见光照片→表面模型）分流。")
"""
)

nb = {
    "cells": cells,
    "metadata": {
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {"name": "python", "version": "3.10"},
    },
    "nbformat": 4, "nbformat_minor": 5,
}
with open(NB, "w", encoding="utf-8") as f:
    json.dump(nb, f, ensure_ascii=False, indent=1)
print("生成 ->", NB, "| cells =", len(cells))
