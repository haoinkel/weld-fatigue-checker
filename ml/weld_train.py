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
#   源5 raw_mine/   <- 用户实拍焊缝现场图，已按 5 类顺序手标（classes.txt 序=目标序），随仓库上传即启用，
#                     无需任何外部网络；作为"自采真实域"补强，重点补 undercut/现场光照鲁棒性。
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
# 工作目录保持调用方所在目录（AI Studio / 魔搭 ModelScope / Kaggle / Jupyter 通用），
# 不再硬编码 AI Studio 路径：检测到 /home/aistudio/work 才切过去，否则沿用当前目录。
_WS = '/home/aistudio/work'
if os.path.isdir(_WS):
    os.chdir(_WS)
    os.makedirs(_WS, exist_ok=True)
else:
    print(f'[提示] 未检测到 AI Studio 工作目录 {_WS}，沿用当前目录: {os.getcwd()}')
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
    # —— 源5 自采现场 raw_mine（用户实拍焊缝图, 已按 5 类顺序手标, 标签序号即目标序号）——
    'porosity': 'porosity',
    'crack':    'crack',
    'undercut': 'undercut',
    'overlap':  'overlap',
    'unfused':  'unfused',
}

# 各数据源的兜底类别顺序（数据源自带 data.yaml/classes.txt 不存在时按此映射索引 0..n）
SOURCE_NAMES = {
    'huangyebiaoke': ['air-hole', 'bite-edge', 'broken-arc', 'crack', 'hollow-bead', 'overlap', 'slag-inclusion', 'unfused'],
    'jian_song':     ['咬bian', '咬边', '气孔', '焊瘤', '裂纹'],
    'lohi':          ['pores', 'deposits', 'discontinuities', 'stains'],
    'kunkun':        ['Crack', 'Lack Of Fusion', 'Lack Of Penetration', 'Porosity', 'Slag Inclusion'],
    'synth':         TARGET_CLASSES,   # 合成粘贴增强产物（raw_synth/），标签直接用目标类序号 0-4
    'raw_mine':      TARGET_CLASSES,   # 源5 自采现场图：classes.txt 序=目标序，标签直接用目标类序号 0-4
}
print('目标类别:', TARGET_CLASSES)
print('REMAP 命中目标类数:', sum(1 for v in REMAP.values() if v))


# ============ 步骤 3/7 ============

# ===== 3. 下载源1（huangyebiaoke, GitHub Release, ghproxy 回退）=====
import os, sys, zipfile, subprocess

# 早期解析 --finetune（完整解析见下方 line 336）：finetune 模式仅用自采 raw_mine，
# 跳过源1~4 下载/解压（避免无代理环境下拉 810MB 数据集卡死，也契合"不重训历史"诉求）。
_FINETUNE_EARLY = '--finetune' in sys.argv

if _FINETUNE_EARLY:
    print('[finetune] 跳过源1~4 下载/解压，仅用 raw_mine 自采数据训练')
else:
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
    {'root': 'raw_mine',   'key': 'raw_mine',      'needs': None},   # 源5 自采现场图（随仓库，自动启用）
]

# ===== 省时微调模式（--finetune）：仅用自采 raw_mine，不重训 120 原始数据 =====
FINETUNE = '--finetune' in sys.argv
if FINETUNE:
    print('[finetune] 启用：仅用 raw_mine 自采数据，不重训源1~4历史数据（AI Studio 数十分钟级）')
    if '--incremental' not in sys.argv:
        shutil.rmtree('dataset', ignore_errors=True)   # 清空旧合并集，避免残留源1~4图片（incremental 时保留 manifest 不删）
_ACTIVE_SOURCES = [s for s in SOURCES if (not FINETUNE or s['key'] == 'raw_mine')]

# ===== 持续学习模式（--incremental）：只训新增图，历史不重跑 =====
# 解决"每次加数据都把 120 原始数据 + 之前自采全部重训"的算力浪费。
# 机制：维护 dataset/.trained_manifest.txt 记录已训图；本轮只把【新增图】进训练，
#       并从【历史图】随机抽一小批(REPLAY_CAP)做回放防灾难性遗忘；权重起点用上次 last.pt。
INCREMENTAL = '--incremental' in sys.argv
REPLAY_CAP = 200
new_bases, replay_pool = [], []
if INCREMENTAL:
    import random
    _MANIFEST = 'dataset/.trained_manifest.txt'
    trained_manifest = set()
    if os.path.isfile(_MANIFEST):
        with open(_MANIFEST, encoding='utf-8') as _mf:
            trained_manifest = set(l.strip() for l in _mf if l.strip())
        print(f'[incremental] 已训历史图 {len(trained_manifest)} 张（本轮不重跑，仅回放防遗忘）')
    else:
        print('[incremental] 首次运行无 manifest：本轮将把全部图当新增全量训一次（仅此一次），之后增量。')

for sp in ('train', 'val'):
    os.makedirs(f'dataset/images/{sp}', exist_ok=True)
    os.makedirs(f'dataset/labels/{sp}', exist_ok=True)
kept = {c: 0 for c in TARGET_CLASSES}

for src in _ACTIVE_SOURCES:
    root = src['root']
    # 兼容两种上传布局：用户把数据集放 work/ 根（raw_mine），或整库上传为 work/（ml/raw_mine）
    if not os.path.isdir(root) and os.path.isdir('ml/' + root):
        root = 'ml/' + root
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
        if INCREMENTAL and base in trained_manifest:
            replay_pool.append((base, ip, boxes))   # 历史图：仅进回放池，不重跑全量
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
        if INCREMENTAL:
            new_bases.append(base)
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

if INCREMENTAL:
    if not new_bases:
        print('[incremental] 未检测到新增数据（所有源均无新图），无需训练。退出。')
        raise SystemExit(0)
    random.shuffle(replay_pool)
    replay = replay_pool[:REPLAY_CAP]
    for (base, ip, boxes) in replay:
        f = os.path.basename(ip)
        dst_img = os.path.join('dataset/images/train', f)
        if os.path.exists(dst_img):
            f = f'replay_{f}'; dst_img = os.path.join('dataset/images/train', f)
        shutil.copy(ip, dst_img)
        with open(os.path.join('dataset/labels/train', os.path.splitext(f)[0] + '.txt'), 'w') as wf:
            wf.write('\n'.join(boxes) + '\n')
        for b in boxes:
            kept[TARGET_CLASSES[int(b.split()[0])]] += 1
    _MANIFEST = 'dataset/.trained_manifest.txt'
    with open(_MANIFEST, 'w', encoding='utf-8') as _mf:
        _mf.write('\n'.join(sorted(trained_manifest | set(new_bases))) + '\n')
    print(f'[incremental] 新增 {len(new_bases)} 张进训练；回放 {len(replay)} 张历史图防遗忘；历史共 {len(trained_manifest)} 张不重跑')
    print(f'[incremental] 已更新 manifest -> {_MANIFEST}')

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

# ===== 续训 / 继续训练支持（解决「AI Studio 被杀」+「加数据后想接着训」两类需求）=====
# 关键事实：AI Studio 被杀的只是 Python 进程，/home/aistudio/work 目录（含 runs/ 下的
# last.pt 与训练状态文件）在环境重置后仍存活（09-26→09-27 实测 last.pt 仍在）。
#
# ⚠️ 三条入口（务必看清区别，直接关系到"raw_mine 40 张 + 以后新增数据"能否进训练）：
#   ① --init-from <ckpt.pt>（【推荐】）：用指定检查点当【权重初始化】，但强制在【本脚本本次
#      重新合并的数据集】（含 raw_mine 及以后新增数据）上从 0 轮训到 TOTAL_EPOCHS。
#      -> 满足「基于 120 权重 + 把 40 张自采 + 后续补充数据全部并进训练」，且不被旧 data 路径绑架。
#   ② 默认自动续训（无 --fresh/--init-from/--resume 且检测到 last.pt）：同样【借 last.pt 权重，
#      但在当前新合并数据集上从 0 轮训】。用于「加数据后重跑即自动吃到新数据」，无需手动指定。
#   ③ --resume（仅同份数据中途被踢的原样续跑）：沿用旧 run 的 args.yaml（含旧 data 路径）。
#      ⚠️ 若上次 run 是在 raw_mine 接入【之前】跑的，--resume 会【漏掉 raw_mine】——此时务必用 ①②。
# 只有 train() 真正跑满 TOTAL_EPOCHS 正常返回后，下方步骤6/7 的 val + export 才会执行。
TRAIN_NAME = 'weld_defect_5cls'
TOTAL_EPOCHS = 120  # 路线A: 小样本需更多轮次收敛


def _find_last_pt():
    cands = sorted(_glob.glob(f'runs/detect/{TRAIN_NAME}*/weights/last.pt'))
    return cands[-1] if cands else None


# ===== 自动备份断点（加固「被踢后重跑」链路，针对此前 120 轮被回收中断的坑）=====
# 背景：AI Studio 免费环境会杀进程；work/ 通常存活，但极端情况下可能被清。
# 为解决「被踢且无险可守 → 只能从头跑 120 轮」，每个 epoch 末把 last.pt 复制一份到
# 固定备份路径，用户可随时从 Notebook 侧边「下载文件」存到本机兜底；万一 work/ 被清，
# 重新上传该备份为 runs/detect/<name>/weights/last.pt 再跑本脚本即无缝续训。
import shutil as _shutil

BACKUP_PT = os.path.join(os.getcwd(), 'weld_defect_5cls_last_backup.pt')  # 动态指向当前工作目录（魔搭/AI Studio 通用）


def _on_train_epoch_end(trainer):
    lp = _find_last_pt()
    if lp and os.path.isfile(lp):
        try:
            _shutil.copy(lp, BACKUP_PT)
            ep = getattr(trainer, 'epoch', None)
            if ep is not None and ep % 10 == 0:
                print(f'[备份] epoch {ep} 末已备份 last.pt -> {BACKUP_PT}')
        except Exception:
            pass


def _attach_backup(model):
    try:
        model.add_callback('on_train_epoch_end', _on_train_epoch_end)
    except Exception:
        pass
    return model


# ===== 训练入口选择（见上方说明：--init-from 推荐 / 默认自动续训权重 / --resume 同run / --fresh 全新）=====
def _get_arg(name):
    """从 sys.argv 取 --key <value> 的值（无则 None）。"""
    try:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    except ValueError:
        pass
    return None

INIT_FROM = _get_arg('--init-from')                       # 推荐：权重起点 = 指定检查点
FRESH = '--fresh' in sys.argv or '--fresh-start' in sys.argv
RESUME = '--resume' in sys.argv                          # 仅同份数据中途被踢的原样续跑

last_pt = _find_last_pt()

if FRESH:
    for d in _glob.glob(f'runs/detect/{TRAIN_NAME}*'):
        print('[--fresh] 删除旧训练目录:', d)
        shutil.rmtree(d, ignore_errors=True)
    last_pt = None

# 训练超参（集中定义，三条入口共用，保证产物参数一致）
TRAIN_KWARGS = dict(
    data='dataset/data.yaml',        # 永远以本脚本【本次新合并】的数据集为准（含 raw_mine + 新增数据）
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
    amp=False,            # 禁用 AMP 自检(fp16 校验需从 GitHub 下载 yolo26n.pt；CN 云环境拉不动，关掉后自动用 FP32 训练，对 yolov8n 无影响)
)

# —— 省时入口：--epochs N 覆盖轮数；--finetune 降学习率保护 120 权重 ——
_epochs_override = _get_arg('--epochs')
if _epochs_override:
    try:
        TRAIN_KWARGS['epochs'] = int(_epochs_override)
        print(f'[epochs] 覆盖训练轮数 = {TRAIN_KWARGS["epochs"]}')
    except ValueError:
        print(f'[epochs] 无法解析 {_epochs_override}，沿用默认 {TOTAL_EPOCHS}')
if FINETUNE:
    TRAIN_KWARGS['lr0'] = 1e-3   # 低学习率，避免摧毁 120 预训练特征
    print(f'[finetune] 学习率 lr0 降至 {TRAIN_KWARGS["lr0"]}（保护 120 权重）')
if INCREMENTAL and not _epochs_override:
    TRAIN_KWARGS['epochs'] = 30
    print(f'[incremental] 默认训练轮数降至 {TRAIN_KWARGS["epochs"]}（只训新增+回放，无需全量120轮）')

if INIT_FROM:
    # 【推荐】借 120（或任意）检查点权重，但在【含 raw_mine + 新增数据的当前数据集】上从 0 轮训
    print(f'[init-from] 权重起点 = {INIT_FROM}')
    if FINETUNE:
        print(f'           -> 【仅 raw_mine 自采数据】微调，不重训源1~4，训到 {TRAIN_KWARGS["epochs"]} 轮（lr0={TRAIN_KWARGS.get("lr0")}）')
        print(f'           （最快：基于 120 权重 + 40 张自采，数十分钟级；后续补数据可重跑 --finetune 或转全量）')
    else:
        print(f'           -> 在【本次新合并数据集】(含源1~4 + raw_mine 40张 + 以后新增数据) 上训到 {TRAIN_KWARGS["epochs"]} 轮')
        print(f'           （满足：基于 120 权重 + 40 张自采 + 后续补充数据全部并进训练）')
    model = YOLO(INIT_FROM)
    _attach_backup(model)
    try:
        results = model.train(**TRAIN_KWARGS)
    except KeyboardInterrupt:
        print('[中断] 训练被手动终止。重跑同一条 --init-from 命令即可在最新数据上续训。')
        raise SystemExit(0)
elif RESUME and last_pt:
    # 仅同份数据中途被踢：原样续跑（沿用旧 run 的 epochs/优化器/数据路径）
    print('[resume] 沿用', last_pt, '及其原 run 数据集/优化器状态，从断点继续（同一份数据用）')
    model = YOLO(last_pt)
    _attach_backup(model)
    try:
        results = model.train(resume=True)
    except KeyboardInterrupt:
        print('[中断] 训练被手动终止。重新运行本脚本即可续训。')
        raise SystemExit(0)
elif last_pt:
    # 默认自动续训：【借 last.pt 权重】，但在【当前新合并数据集】上从 0 轮训（避免 resume 漏掉 raw_mine/新数据）
    print(f'[续训-权重] 检测到 {last_pt} 作为权重初始化')
    if FINETUNE:
        print(f'           -> 【仅 raw_mine 自采数据】微调，不重训源1~4，训到 {TRAIN_KWARGS["epochs"]} 轮（lr0={TRAIN_KWARGS.get("lr0")}）')
    else:
        print(f'           -> 在【本次新合并数据集】(含 raw_mine 40张 + 以后新增数据) 上训到 {TRAIN_KWARGS["epochs"]} 轮')
        print(f'           （加数据后重跑即走此分支，自动吃到新数据，无需 --init-from）')
    model = YOLO(last_pt)
    _attach_backup(model)
    try:
        results = model.train(**TRAIN_KWARGS)
    except KeyboardInterrupt:
        print('[中断] 训练被手动终止。重新运行本脚本即可在最新数据上续训。')
        raise SystemExit(0)
else:
    # 无历史权重：从 yolov8n.pt COCO 预训练起点全新训（数据仍含全部源 + raw_mine）
    print('[新训] 未找到历史权重，从 yolov8n.pt COCO 预训练起点开始（数据集已含 raw_mine + 全部源）')
    model = YOLO('yolov8n.pt')   # 自动从 Ultralytics 服务器下载 COCO 预训练权重
    _attach_backup(model)
    try:
        results = model.train(**TRAIN_KWARGS)
    except KeyboardInterrupt:
        print('[中断] 训练被手动终止。')
        raise SystemExit(0)
print('训练完成')

# 安全提示：本脚本已在每个 epoch 末自动把 last.pt 备份到：
#   /home/aistudio/work/weld_defect_5cls_last_backup.pt
# 用 Notebook 侧边「下载文件」把它存到本机兜底；万一 work/ 被清，
# 重新上传该备份为 runs/detect/<name>/weights/last.pt 再跑本脚本即无缝续训。
print('[提醒] 断点已自动备份至', BACKUP_PT, '（也可手动下载到本机：侧边「下载文件」）')


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
