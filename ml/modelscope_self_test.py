# ============================================================================
# 自测脚本：用 120 轮训练权重 (last.pt) 对训练/验证图片推理，验证模型能否识别缺陷
# 运行环境：魔搭 ModelScope Notebook（需有 last.pt + 解压好的数据集）
# 用法：把本文件内容复制到魔搭 notebook 直接跑；先改下面两个路径
#   LAST_PT   —— 你的 120 轮训练产物 last.pt
#   IMG_DIR   —— 解压后的训练/验证图片目录（或某张具体图路径）
# ============================================================================
from ultralytics import YOLO
from pathlib import Path
import glob

# ---------- ① 改这两个路径 ----------
LAST_PT = '/mnt/workspace/last.pt'                 # ← 120 轮权重
IMG_DIR = '/mnt/workspace/weld_data/images'        # ← 图片目录；也可填单张图路径如 '/mnt/workspace/src1.jpg'
# --------------------------------

model = YOLO(LAST_PT)
NAMES = model.names
print('模型类别:', NAMES)

# 收集图片
p = Path(IMG_DIR)
if p.is_file():
    imgs = [str(p)]
else:
    imgs = sorted(glob.glob(f'{IMG_DIR}/**/*.jpg', recursive=True) +
                  glob.glob(f'{IMG_DIR}/**/*.png', recursive=True))
print(f'待测图片: {len(imgs)} 张\n')

# 全局统计：每类最高分（看模型在训练域整体能到多高）
best_per_class = {c: 0.0 for c in NAMES.values()}

for im in imgs[:60]:                      # 先跑前 60 张看趋势（全量把 60 改成 len(imgs)）
    r = model.predict(source=im, imgsz=640, conf=0.01, verbose=False)[0]
    boxes = r.boxes
    name = Path(im).name
    if len(boxes) == 0:
        print(f'[无检测] {name}')
        continue
    cls  = boxes.cls.cpu().numpy().astype(int)
    conf = boxes.conf.cpu().numpy()
    out = {}
    for c, cf in zip(cls, conf):
        cf = float(cf)
        out.setdefault(c, []).append(cf)
        if cf > best_per_class[NAMES[c]]:
            best_per_class[NAMES[c]] = cf
    summary = ' | '.join(f'{NAMES[c]}:{max(v):.3f}(n={len(v)})' for c, v in out.items())
    print(f'[OK] {name:28s} {summary}')

print('\n=== 每类在训练域的最高分（应普遍 0.5~0.95，证明模型能识别）===')
for c, v in best_per_class.items():
    print(f'  {c:12s} max={v:.3f}')

# 若想单独验证"源1未熔合图"，把 IMG_DIR 改成该图路径重跑即可，重点看 unfused 行分数
