# -*- coding: utf-8 -*-
# 焊缝缺陷 YOLOv8 云端训练脚本（由 colab_train_weld.ipynb 转换）
# 用法（AI Studio Notebook 任一 cell 里运行）:
#   %run /home/aistudio/work/weld_train.py
# 或终端: cd /home/aistudio/work && python weld_train.py
#
# 多源合并说明（本次训练聚焦 MAG 焊接工艺）:
#   源1 raw/        <- huangyebiaoke/steel-pipe-weld-defect-detection（脚本自动 ghproxy 下载, 基础源）
#   源2 raw_jian/   <- JIAN SONG「焊接缺陷」Roboflow 导出(Public Domain), 手动上传
#   源3 raw_lohi/   <- LoHi-WELD【MAG 聚焦首选补充源】(IEEE Access 2024, GMAW/MAG 机器人焊道可见光,
#                      3022张, 4类 pores/deposits/discontinuities/stains -> porosity/overlap/unfused/丢弃; 免费可商用, 需引用)
#   源4 raw_kunkun/ <- kunkun-vhmx2/weld（Roboflow, CC BY 4.0, 2200图, 精细5类: Crack/Lack Of Fusion/...）
#
# ⚠️ CN 网络现实（2026-09-26 核实）: 仅 GitHub 可达；Roboflow / Google Drive / HuggingFace 全被墙。
#   - Roboflow(源2/源4) 国内打不开, 下载端点 403 -> 无代理/VPN 不可下; 脚本保留支持, 有代理即生效。
#   - LoHi-WELD(源3) 数据在 Google Drive, 本地与沙箱均 502 隧道失败 -> 但可在【训练环境 AI Studio 内】
#      用 gdown 直接拉(云端出网通常不受限), 见步骤 3.5。文件ID: 1pXeEnREfV_MYcL5MY2vkd9njBm_blPUK (图像集)。
#   - HuggingFace(502 墙) / Kaggle 焊接集: HF 不可达; Kaggle 多为 Severstal(钢板表面, RLE分割, 非焊道)
#      或粗类(Defect/Good/Bad Weld), 无法细分到5类 -> 均不采用。
#   - firc-dataset 等"免费"集实为付费网盘(mbd.pub/CSDN)引流 -> 不可用。
#   - X 射线/RT 数据集一律排除（与 App 表面可见光路线冲突）。
#   - 当前无代理时唯一确定可用补强 = 内置增强(路线A: copy_paste=0.45 + crack/undercut 过采样×1.5 + mixup/几何增广, 见步骤4/5), 直接 %run 生效。
#   已排除: weld-defects-mlopr(粗类); Welding Data Set v3(语义分割); graylin2025/QQ767172261(索引页/无数据)
#   各源缺失即跳过, 保证单源也能训练。

import os
os.chdir('/home/aistudio/work')  # 保证产物落 work/ (环境重置不丢)
os.makedirs('/home/aistudio/work', exist_ok=True)
print('工作目录:', os.getcwd())


# ============ 步骤 1/7 ============

# ===== 1. 安装依赖 =====
# AI Studio 的 pip 实际把包装在 external-libraries/lib/python3.10/site-packages
# （bin/lib/share 结构，pip show torch 的 Location 字段已证实），
# 必须把这个真正的 site-packages 路径 insert(0) 进 sys.path，
# 根目录没用；且 AI Studio 经典环境会拦截格子里的 "import torch" 字面量，
# Notebook 里验证时请用 importlib.import_module('torch') 绕过。
import sys, subprocess

EXTLIB_SITE = '/home/aistudio/external-libraries/lib/python3.10/site-packages'
if EXTLIB_SITE not in sys.path:
    sys.path.insert(0, EXTLIB_SITE)

def pip_(*args):
    subprocess.check_call([sys.executable, '-m', 'pip', *args])

# 诊断：看 'torch' 名字解析到哪个文件（external-libraries=真，site-packages=假）
import importlib.util
_spec = importlib.util.find_spec('torch')
print('torch 解析到:', _spec.origin if _spec else '(未找到)')

try:
    import torch
    print('torch 已就绪', torch.__version__)
except Exception as e:
    print('torch 导入失败 -> 重装（约2GB，几分钟）... 原因:', e)
    pip_('uninstall', '-y', 'torch', 'torchvision', 'torchaudio')
    pip_('install', 'ultralytics', 'coremltools')
    import torch

print('torch', torch.__version__, '| GPU', torch.cuda.is_available())
assert torch.cuda.is_available(), 'GPU 不可用！请检查是否选了 V100 GPU 环境'
from ultralytics import YOLO
print('ultralytics 导入成功')


# ============ 步骤 2/7 ============

# ===== 2. 配置 =====
# 目标 5 类: porosity/crack/undercut/overlap/unfused（余高由 App 内 LiDAR 几何计算）。
TARGET_CLASSES = ['porosity', 'crack', 'undercut', 'overlap', 'unfused']

# 源数据集类别名 -> 目标类别（None 表示该框丢弃，不计入 5 类）
REMAP = {
    # —— 源1 huangyebiaoke/steel-pipe-weld-defect-detection（现有, GitHub Release, ghproxy 可下）——
    'air-hole': 'porosity',     # 气孔
    'crack':    'crack',        # 裂纹
    'bite-edge': 'undercut',    # 咬边（原仅35张, 少数类, 重点盯 recall）
    'overlap':   'overlap',     # 焊瘤
    'unfused':   'unfused',     # 未融合
    # —— 源2 JIAN SONG「焊接缺陷」Roboflow（Public Domain, 手动上传 raw_jian/）——
    '咬bian': 'undercut',       # 咬边（罗马音拼写变体）
    '咬边':  'undercut',        # 咬边
    '气孔':  'porosity',        # 气孔
    '焊瘤':  'overlap',         # 焊瘤
    '裂纹':  'crack',           # 裂纹
    # —— 源3 LoHi-WELD（IEEE Access 2024, MAG 焊道可见光, 手动上传 raw_lohi/, Google Drive 易墙）——
    'pores':          'porosity',   # 气孔
    'pore':           'porosity',
    'deposits':       'overlap',    # 焊瘤（多余焊材）
    'discontinuities':'unfused',    # 未熔合（局部缺材）
    'stains':         None,         # 表面色变, 无法干净映射到5类 -> 丢弃
    # —— 源4 kunkun-vhmx2/weld（Roboflow, CC BY 4.0, 2200图, 精细5类; 手动上传 raw_kunkun/）——
    'Crack':               'crack',       # 裂纹（直接补最缺的少数类）
    'crack':               'crack',
    'Lack Of Fusion':      'unfused',     # 未熔合
    'lack of fusion':      'unfused',
    'Lack Of Penetration':'unfused',     # 未焊透（最佳映射: 熔合不全类）
    'lack of penetration':'unfused',
    'Porosity':            'porosity',    # 气孔
    'porosity':            'porosity',
    'Slag Inclusion':      None,          # 夹渣（不在5类内, 丢弃）
    'slag inclusion':      None,
    # —— 其它常见英文/变体（firc、论文集等, 遇到即映射, 未出现不影响）——
    'porosities':     'porosity',
    'lack of fusion': 'unfused', 'lack-of-fusion': 'unfused', 'improper_fusion': 'unfused',
    'cracks':         'crack',
    'excess reinforcement': 'overlap', 'excess_reinforcement': 'overlap',
    'spatter': None, 'spatters': None,
    'welding line': None, 'welding_line': None,
    'bad welding': None, 'good welding': None, 'bad weld': None, 'good weld': None,
}

# 各数据源的兜底类别顺序（数据源自带 data.yaml/classes.txt 不存在时按此映射索引 0..n）
SOURCE_NAMES = {
    'huangyebiaoke': ['air-hole', 'bite-edge', 'broken-arc', 'crack', 'hollow-bead', 'overlap', 'slag-inclusion', 'unfused'],
    'jian_song':     ['咬bian', '咬边', '气孔', '焊瘤', '裂纹'],
    'lohi':          ['pores', 'deposits', 'discontinuities', 'stains'],
    'kunkun':        ['Crack', 'Lack Of Fusion', 'Lack Of Penetration', 'Porosity', 'Slag Inclusion'],
    'synth':         TARGET_CLASSES,   # 合成粘贴增强产物（raw_synth/），标签直接用目标类序号 0-4
}
print('目标类别:', TARGET_CLASSES)
print('REMAP 命中目标类数:', sum(1 for v in REMAP.values() if v))


# ============ 步骤 3/7 ============

# ===== 3. 下载源1（huangyebiaoke, GitHub Release, ghproxy 回退）=====
import os, sys, zipfile, subprocess

URL = "https://github.com/huangyebiaoke/steel-pipe-weld-defect-detection/releases/download/1.0/steel-tube-dataset-all.zip"
# AI Studio 等 CN 云环境直连 github.com 会超时，依次尝试常见 ghproxy 镜像回退。
MIRRORS = [
    'https://ghproxy.net/' + URL,
    'https://mirror.ghproxy.com/' + URL,
    'https://gh.api.99988866.xyz/' + URL,
    URL,
]
os.makedirs('raw', exist_ok=True)
zip_path = 'raw/steel-tube-dataset-all.zip'

if not os.path.exists(zip_path) or os.path.getsize(zip_path) < 1_000_000:
    for u in MIRRORS:
        print('下载数据集:', u)
        r = subprocess.run(['curl', '-L', '--max-time', '180', '-o', zip_path, u],
                           capture_output=True, text=True)
        if r.returncode == 0 and os.path.getsize(zip_path) > 1_000_000:
            print('下载完成:', os.path.getsize(zip_path), 'bytes')
            break
        else:
            print('该镜像失败:', (r.stderr or '')[-150:])
    else:
        raise SystemExit('所有镜像均下载失败，请手动下载数据集放到 ' + zip_path)
else:
    print('已存在，跳过下载')

print('解压...')
with zipfile.ZipFile(zip_path) as z:
    z.extractall('raw')
print('解压完成')
print('提示: 源2 JIAN SONG 解压到 raw_jian/; 源3 LoHi-WELD 放到 raw_lohi/ (或见步骤3.5用 gdown 在云端拉); 源4 kunkun 解压到 raw_kunkun/（缺失则自动跳过）')

# ===== 3.5 可选：在 AI Studio 云端用 gdown 拉取 LoHi-WELD（MAG 聚焦首选源；本地/沙箱被墙时绕道）=====
# 数据在 Google Drive（文件ID: 1pXeEnREfV_MYcL5MY2vkd9njBm_blPUK = 图像集 weld_dataset(含 low/high 焊道 + json标注 + kfolds)）。
# 仅当训练环境(AI Studio)出网不受限时可用；本地/沙箱均 502 墙死，请勿在本地跑。
# 也可直接在 AI Studio Notebook 里执行注释命令（效果相同）：
#   !pip install gdown -q
#   !gdown 1pXeEnREfV_MYcL5MY2vkd9njBm_blPUK -O raw_lohi.zip
#   !unzip -o raw_lohi.zip -d raw_lohi
# 下面这段仅在显式设置环境变量 LOHI_GDOWN=1 时自动执行（默认关闭，避免无网环境报错）。
if os.environ.get('LOHI_GDOWN') == '1':
    print('[LoHi-WELD] LOHI_GDOWN=1，尝试 gdown 拉取（需训练环境可访问 Google Drive）...')
    subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', 'gdown'], capture_output=True)
    _r = subprocess.run(['gdown', '1pXeEnREfV_MYcL5MY2vkd9njBm_blPUK', '-O', 'raw_lohi.zip'], capture_output=True, text=True)
    if _r.returncode == 0 and os.path.exists('raw_lohi.zip'):
        with zipfile.ZipFile('raw_lohi.zip') as z:
            z.extractall('raw_lohi')
        print('[LoHi-WELD] 解压完成 -> raw_lohi/')
    else:
        print('[LoHi-WELD] gdown 失败（环境无法访问 Google Drive？）：', (_r.stderr or '')[-200:])


# ============ 步骤 4/7 ============

# ===== 4. 多源合并 -> 统一 5 类 YOLO，全局 md5 切分 train/val =====
import os, yaml, shutil, hashlib, xml.etree.ElementTree as ET, json

name2newid = {n: i for i, n in enumerate(TARGET_CLASSES)}
IMG_EXTS = ('.jpg', '.jpeg', '.png', '.bmp', '.JPG', '.PNG')

def resolve_src_names(root, fallback):
    """读数据源自带 data.yaml/classes.txt 确定 索引->源类名；否则用兜底。
    兼容 Roboflow 导出的 names 既可能是 list 也可能是 dict({0:'Crack',...})。"""
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(('.yaml', '.yml')):
                try:
                    cfg = yaml.safe_load(open(os.path.join(r, f)))
                    names = cfg.get('names') if isinstance(cfg, dict) else None
                    if names is not None:
                        if isinstance(names, list) and len(names) >= 2:
                            print(f'  [{root}] 发现 data.yaml(list)，源类别:', names)
                            return {i: str(n) for i, n in enumerate(names)}
                        if isinstance(names, dict) and len(names) >= 2:   # Roboflow 常见形式
                            print(f'  [{root}] 发现 data.yaml(dict)，源类别:', names)
                            return {int(k): str(v) for k, v in names.items()}
                except Exception:
                    pass
            if f == 'classes.txt':
                try:
                    names = [l.strip() for l in open(os.path.join(r, f)) if l.strip()]
                    if names:
                        return {i: n for i, n in enumerate(names)}
                except Exception:
                    pass
    return {i: n for i, n in enumerate(fallback)}

def parse_yolo_line(line, src_names):
    p = line.split()
    if len(p) < 5:
        return None
    try:
        cid = int(p[0])
    except ValueError:
        return None
    sname = src_names.get(cid)
    if sname is None:
        return None
    tgt = REMAP.get(sname)
    if not tgt:
        return None
    return f"{name2newid[tgt]} {' '.join(p[1:])}"

def parse_voc(xml_path):
    out = []
    try:
        tree = ET.parse(xml_path); root = tree.getroot()
        sz = root.find('size')
        w = float(sz.find('width').text); h = float(sz.find('height').text)
        for obj in root.findall('object'):
            sname = (obj.find('name').text or '').strip()
            tgt = REMAP.get(sname)
            if not tgt:
                continue
            bb = obj.find('bndbox')
            xmin = float(bb.find('xmin').text); ymin = float(bb.find('ymin').text)
            xmax = float(bb.find('xmax').text); ymax = float(bb.find('ymax').text)
            cx = ((xmin + xmax) / 2) / w; cy = ((ymin + ymax) / 2) / h
            bw = (xmax - xmin) / w; bh = (ymax - ymin) / h
            out.append(f"{name2newid[tgt]} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}")
    except Exception:
        return []
    return out

def convert_lohi_json(root):
    """LoHi-WELD: best-effort 把 COCO 风格 json 标注转 YOLO txt（需手动上传 raw_lohi/）。
    结构不匹配则抛错由调用方跳过。"""
    marker = os.path.join(root, '.converted')
    if os.path.exists(marker):
        return
    js = None
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.json'):
                try:
                    d = json.load(open(os.path.join(r, f), encoding='utf-8'))
                except Exception:
                    continue
                if isinstance(d, dict) and 'images' in d and 'annotations' in d:
                    js = (r, d); break
        if js:
            break
    if js is None:
        raise RuntimeError('raw_lohi 未找到 COCO 风格 json，跳过（如需启用请检查标注格式）')
    base, d = js
    cat = {c['id']: str(c['name']) for c in d.get('categories', [])}
    img_w, img_h, img_file = {}, {}, {}
    for im in d['images']:
        img_w[im['id']] = im.get('width', 0); img_h[im['id']] = im.get('height', 0)
        img_file[im['id']] = im.get('file_name', '')
    by_img = {}
    for a in d['annotations']:
        by_img.setdefault(a['image_id'], []).append(a)
    for imid, anns in by_img.items():
        fn = img_file.get(imid, '')
        if not fn:
            continue
        w = img_w.get(imid) or 0; h = img_h.get(imid) or 0
        if not w or not h:
            continue
        lines = []
        for a in anns:
            sname = cat.get(a.get('category_id'))
            tgt = REMAP.get(sname) if sname else None
            if not tgt:
                continue
            x, y, bw, bh = a['bbox']  # COCO: 绝对值 x,y,w,h
            cx = (x + bw / 2) / w; cy = (y + bh / 2) / h; nw = bw / w; nh = bh / h
            if not (0 < nw < 1 and 0 < nh < 1):
                continue
            lines.append(f"{name2newid[tgt]} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
        if lines:
            lp = os.path.join(base, os.path.splitext(fn)[0] + '.txt')
            with open(lp, 'w') as wf:
                wf.write('\n'.join(lines) + '\n')
    open(marker, 'w').close()
    print('  LoHi-WELD json -> YOLO txt 转换完成')

# 数据源清单：缺失即跳过（保证单源也能训）
SOURCES = [
    {'root': 'raw',        'key': 'huangyebiaoke', 'needs': None},
    {'root': 'raw_jian',   'key': 'jian_song',     'needs': None},   # 手动上传 Roboflow 导出
    {'root': 'raw_lohi',   'key': 'lohi',          'needs': 'json'}, # 手动上传（Google Drive 易墙）
    {'root': 'raw_kunkun', 'key': 'kunkun',        'needs': None},   # 手动上传 Roboflow 导出（CC BY 4.0, 精细类）
]

for sp in ('train', 'val'):
    os.makedirs(f'dataset/images/{sp}', exist_ok=True)
    os.makedirs(f'dataset/labels/{sp}', exist_ok=True)
kept = {c: 0 for c in TARGET_CLASSES}

for src in SOURCES:
    root = src['root']
    if not os.path.isdir(root):
        print(f'[跳过] 数据源 {src["key"]} 目录 {root} 不存在（如需启用请上传数据集到此目录）')
        continue
    if src['needs'] == 'json':
        try:
            convert_lohi_json(root)
        except Exception as e:
            print(f'[跳过] LoHi-WELD 转换失败: {e}')
            continue
    src_names = resolve_src_names(root, SOURCE_NAMES[src['key']])
    img_map, yolo_map, voc_map = {}, {}, {}
    for r, _, fs in os.walk(root):
        for f in fs:
            fl = f.lower(); base = os.path.splitext(f)[0]
            if fl.endswith(IMG_EXTS):
                img_map[base] = os.path.join(r, f)
            elif fl.endswith('.txt'):
                yolo_map.setdefault(base, os.path.join(r, f))
            elif fl.endswith('.xml'):
                voc_map.setdefault(base, os.path.join(r, f))
    cnt = 0
    for base, ip in img_map.items():
        boxes = []
        ann = yolo_map.get(base)
        if ann:
            for line in open(ann, encoding='utf-8', errors='ignore'):
                r2 = parse_yolo_line(line.strip(), src_names)
                if r2:
                    boxes.append(r2)
        else:
            ann = voc_map.get(base)
            if ann:
                boxes = parse_voc(ann)
        if not boxes:
            continue
        f = os.path.basename(ip)
        split = 'val' if (int(hashlib.md5(base.encode()).hexdigest(), 16) % 5 == 0) else 'train'
        dst_img = os.path.join('dataset/images', split, f)
        if os.path.exists(dst_img):           # 跨源重名冲突 -> 加源前缀
            f = f'{src["key"]}_{f}'
            dst_img = os.path.join('dataset/images', split, f)
        shutil.copy(ip, dst_img)
        with open(os.path.join('dataset/labels', split, os.path.splitext(f)[0] + '.txt'), 'w') as wf:
            wf.write('\n'.join(boxes) + '\n')
        cnt += 1
        for b in boxes:
            kept[TARGET_CLASSES[int(b.split()[0])]] += 1
    print(f'[合并] {src["key"]}: 保留图-标对 {cnt}')

print('各类框数:', kept)
with open('dataset/data.yaml', 'w') as f:
    yaml.safe_dump({
        'path': 'dataset',
        'train': 'images/train',
        'val': 'images/val',
        'nc': len(TARGET_CLASSES),
        'names': TARGET_CLASSES,
    }, f)
print('已生成 dataset/data.yaml ->', TARGET_CLASSES)

# 少数类过采样（仅 train, 路线A核心补强）：复制 crack/undercut 训练图，
# 使其达到「中位类数量 × OVER_SAMPLE_MULT」，缓解样本不均衡。
# ⚠️ 整图复制仅提升该图出现频率；真正的"新缺陷实例"主要依靠下方训练时的 copy_paste 增广。
MINORITY = ['crack', 'undercut']
OVER_SAMPLE_MULT = 1.5   # 过采样目标 = 中位类数量 × 1.5（路线A小样本友好, 比默认1.0更激进）
train_img_dir = 'dataset/images/train'; train_lbl_dir = 'dataset/labels/train'

def count_class_imgs(cls):
    n = 0
    for lt in os.listdir(train_lbl_dir):
        if not lt.endswith('.txt'):
            continue
        for line in open(os.path.join(train_lbl_dir, lt)):
            if line.split() and int(line.split()[0]) == name2newid[cls]:
                n += 1; break
    return n

counts = {c: count_class_imgs(c) for c in TARGET_CLASSES}
median = sorted(counts.values())[len(counts) // 2]
print('过采样前各类训练图数:', counts, ' 中位:', median)
for c in MINORITY:
    have = counts[c]
    target = int(median * OVER_SAMPLE_MULT)
    need = target - have
    if need <= 0:
        print(f'  {c} 已 >= 目标({target}), 跳过过采样')
        continue
    imgs = []
    for lt in os.listdir(train_lbl_dir):
        if not lt.endswith('.txt'):
            continue
        with open(os.path.join(train_lbl_dir, lt)) as lf:
            for line in lf:
                if line.split() and int(line.split()[0]) == name2newid[c]:
                    imgs.append(os.path.splitext(lt)[0]); break
    if not imgs:
        continue
    i = 0; added = 0
    while added < need and imgs:
        base = imgs[i % len(imgs)]; i += 1
        ext = next((e for e in IMG_EXTS if os.path.exists(os.path.join(train_img_dir, base + e))), None)
        if not ext:
            continue
        newbase = f'{base}__os{added}'
        shutil.copy(os.path.join(train_img_dir, base + ext), os.path.join(train_img_dir, newbase + ext))
        shutil.copy(os.path.join(train_lbl_dir, base + '.txt'), os.path.join(train_lbl_dir, newbase + '.txt'))
        added += 1
    print(f'  过采样 {c}: {have} -> {have + added}')


# ============ 步骤 5/7 ============

from ultralytics import YOLO
import glob as _glob

# ===== 断点续训支持（解决「AI Studio 免费环境回收/杀进程 → 长训练跑不到头」）=====
# 关键事实：AI Studio 被杀的只是 Python 进程，/home/aistudio/work 目录（含 runs/ 下的
# last.pt 与训练状态文件）在环境重置后仍存活（09-26→09-27 实测 last.pt 仍在）。
# 因此：每次被踢，重新跑本脚本即可自动从上一个 last.pt 续训，epoch 累加直到 TOTAL_EPOCHS。
# 只有 train() 真正跑满 TOTAL_EPOCHS 正常返回后，下方步骤6/7 的 val + export 才会执行。
TRAIN_NAME = 'weld_defect_5cls'
TOTAL_EPOCHS = 120  # 路线A: 小样本需更多轮次收敛


def _find_last_pt():
    cands = sorted(_glob.glob(f'runs/detect/{TRAIN_NAME}*/weights/last.pt'))
    return cands[-1] if cands else None


# --fresh / --fresh-start：清掉旧训练目录，强制从 yolov8n.pt 全新跑 120 轮增强版，
# 用本脚本显式锁定的增强参数（不依赖任何历史保存的 args.yaml），保证产物 100% 确定。
FRESH = '--fresh' in sys.argv or '--fresh-start' in sys.argv

last_pt = None if FRESH else _find_last_pt()
if FRESH:
    for d in _glob.glob(f'runs/detect/{TRAIN_NAME}*'):
        print('[--fresh] 删除旧训练目录:', d)
        shutil.rmtree(d, ignore_errors=True)
if last_pt:
    print('[续训] 检测到', last_pt, '-> 从上次中断处继续训练到', TOTAL_EPOCHS, '轮')
    print('        （被踢后重新运行本脚本即可自动续训，无需任何额外操作）')
    model = YOLO(last_pt)
    try:
        results = model.train(resume=True)  # resume 沿用上次保存的 epochs/优化器/调度器状态
    except KeyboardInterrupt:
        print('[中断] 训练被手动终止。重新运行本脚本即可自动续训。')
        raise SystemExit(0)
else:
    print('[新训] 未找到历史权重，从 yolov8n.pt COCO 预训练起点开始')
    model = YOLO('yolov8n.pt')   # 自动从 Ultralytics 服务器下载 COCO 预训练权重
    results = model.train(
        data='dataset/data.yaml',
        task='detect',
        epochs=TOTAL_EPOCHS, imgsz=640, batch=16,
        name=TRAIN_NAME,
        patience=30,          # 更宽松早停, 给少数类(crack/undercut)更多学习机会
        augment=True,         # 小数据集防过拟合
        hsv_h=0.015, hsv_s=0.9, hsv_v=0.5,  # 提升色彩抖动, 增强对光照/焊渣色变鲁棒性
        fliplr=0.5, mosaic=1.0,
        mixup=0.1,            # 轻度 mixup, 提升泛化、抑制过拟合
        degrees=5.0, scale=0.5, shear=1.0, perspective=0.0005,  # 几何增广: 焊缝朝向/尺度多样
        copy_paste=0.45,      # 路线A核心: 少数类(crack/undercut)最有效增广, 0.2->0.45 更激进
        seed=42,
    )
print('训练完成')

# 安全提示：每次会话结束前，建议把最新断点下载到本地兜底（防极端情况下目录被清）：
#   !cp runs/detect/%s*/weights/last.pt /home/aistudio/work/last_backup.pt
#   （用 Notebook 侧边「下载文件」把 last_backup.pt 存到本机；下次被清就重新上传再续训）
print('[提醒] 若担心环境清空 work/，请现在下载 runs/detect/%s*/weights/last.pt 到本地兜底' % TRAIN_NAME)


# ============ 步骤 6/7 ============

# 验证 mAP（气孔类别目标 map50 >= 0.85 再上机；裂纹样本少，关注其 recall）
metrics = model.val()
print('mAP50   :', round(metrics.box.map50, 4))
print('mAP50-95:', round(metrics.box.map, 4))


# ============ 步骤 7/7 ============

# 直接导出本次训练的最新权重：model 在 train() 后已指向 weld_defect_5cls-N/weights/best.pt
# 切勿再写 YOLO('runs/detect/weld_defect_5cls/weights/best.pt') 这种硬编码无编号路径，
# 否则会拿到旧编号目录里被早停中断的权重（实测 -2 才是完整 80 epoch 结果，mAP50=0.978）。
# ⚠️ CoreML 导出要点（Ultralytics 8.4.x 实测）：
#   1) `data=` 对 format='coreml' 不支持（会 AssertionError），CoreML 量化不走 data= 校准。
#   2) 旧 `int8=True` 已废弃，且映射到 quantize=8(全 INT8 需校准) → 因 CoreML 不收 data，静默回退 FP32(5.9MB)。
#   3) CoreML 真正可用的量化是 quantize='w8a16'（INT8 权重 + 16-bit 激活，权重-only，无需校准，体积 ~1.5-2MB，跑 Neural Engine）。
exported = model.export(format='coreml', nms=True, quantize='w8a16', imgsz=640)  # 权重 INT8 量化：~1.5-2MB，跑 Neural Engine，推理快
pkg_name = 'WeldDefectModel.mlpackage' if os.path.isdir(exported) else 'WeldDefectModel.mlmodel'
if os.path.exists(exported):
    if os.path.exists(pkg_name):
        shutil.rmtree(pkg_name) if os.path.isdir(pkg_name) else os.remove(pkg_name)
    shutil.move(exported, pkg_name)
    print('已导出', pkg_name)
