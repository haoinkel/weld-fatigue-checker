# 单图测试（通用版）：复刻 App 解码逻辑，真跑 last.onnx 验证检出
# 用法: python test_single.py <图片文件名，不带路径>
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageDraw
from local_onnx_verify import (sess, iname, preprocess, decode, load_gt,
                               CLASSES, THRESH, IMG_DIR, LBL_DIR)

# 原始数据集 8 类 → App 5 类映射（对齐 weld_train.py 'huangyebiaoke' 映射）
RAW8 = ["air-hole", "bite-edge", "broken-arc", "crack",
        "hollow-bead", "overlap", "slag-inclusion", "unfused"]
MAP8TO5 = {"air-hole": "porosity", "hollow-bead": "porosity", "crack": "crack",
           "bite-edge": "undercut", "overlap": "overlap", "unfused": "unfused",
           "broken-arc": "(丢弃)", "slag-inclusion": "(丢弃)"}

name = sys.argv[1] if len(sys.argv) > 1 else "unfused4-20.jpg"
path = os.path.join(IMG_DIR, name)
assert os.path.exists(path), f"找不到 {path}"
base = os.path.splitext(name)[0]

x, geo, orig = preprocess(path)
out = sess.run(None, {iname: x})[0]
kept, raw = decode(out, geo, orig)
gt = load_gt(os.path.join(LBL_DIR, base + ".txt"))

print(f"图片: {path}")
print(f"原图尺寸: {orig[0]}x{orig[1]}")
print(f"\n=== 真值标注（原始8类 → App5类）===")
for c, gr in gt:
    print(f"  {RAW8[c]} → {MAP8TO5[RAW8[c]]}  box={gr}")

print(f"\n=== 检测结果（App 标准档阈值，NMS 0.6）===")
if not kept:
    print("  无框通过阈值")
for rect, cls, sc in kept:
    print(f"  {cls}: 分数 {sc:.3f}（阈值 {THRESH[cls]}）  box={rect}")

print(f"\n=== 前 10 个最高分原始候选（诊断）===")
for cls, sc in raw[:10]:
    print(f"  {cls}: {sc:.3f}")

# 真值匹配判定
used = [False] * len(gt)
hits = []
for rect, cls, sc in kept:
    ci = CLASSES.index(cls)
    for gi, (gc, gr) in enumerate(gt):
        if not used[gi] and gc == ci:
            from local_onnx_verify import iou
            if iou(rect, gr) >= 0.5:
                used[gi] = True
                hits.append((cls, sc, gr))
                break
print(f"\n=== 判定 ===")
print(f"真值 {len(gt)} 个 | 检出匹配(IoU>=0.5且类对) {len(hits)} 个")
print("PASS ✅" if len(hits) == len(gt) and len(kept) == len(hits) else
      "PARTIAL ⚠️（有检出但未全匹配/有冗余框）" if hits else "FAIL ❌")

# 画标注图：红=检测框 绿=真值框
im = Image.open(path).convert("RGB")
W, H = im.size
d = ImageDraw.Draw(im)
for c, gr in gt:
    d.rectangle([gr[0]*W, gr[1]*H, gr[2]*W, gr[3]*H], outline=(0, 160, 0), width=4)
for rect, cls, sc in kept:
    d.rectangle([rect[0]*W, rect[1]*H, rect[2]*W, rect[3]*H], outline=(220, 0, 0), width=4)
    d.text((rect[0]*W+6, max(4, rect[1]*H-20)), f"{cls} {sc:.2f}", fill=(220, 0, 0))
d.text((4, 4), "red=detect  green=GT", fill=(0, 100, 200))
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), base + "_result.jpg")
im.save(out_path, quality=92)
print(f"\n标注图已保存: {out_path}")
