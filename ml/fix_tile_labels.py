# -*- coding: utf-8 -*-
"""修复 raw_mine_tiles 标签的类索引错乱。
坏映射(生成器写出): {0->0,1->1,2->5,3->2,4->6}
逆映射(本脚本还原): {0->0,1->1,2->3,5->2,6->4}
输入: surfacedetecttrain/raw_mine_tiles/{images,labels}
输出: surfacedetecttrain/raw_mine_tiles_fixed/{images,labels} (标签已修正，图像软链/复制)
"""
import os, shutil
BASE = r"D:/workbuddy/workbuddy学习/surfacedetecttrain"
SRC = os.path.join(BASE, "raw_mine_tiles")
DST = os.path.join(BASE, "raw_mine_tiles_fixed")
INV = {0:0, 1:1, 2:3, 5:2, 6:4}  # tile class -> correct 7-class index

os.makedirs(os.path.join(DST, "images"), exist_ok=True)
os.makedirs(os.path.join(DST, "labels"), exist_ok=True)

lbl_dir = os.path.join(SRC, "labels")
imgs = sorted(os.listdir(os.path.join(SRC, "images")))
fixed = 0; skipped = 0; bad = 0
for im in imgs:
    base = os.path.splitext(im)[0]
    src_lbl = os.path.join(lbl_dir, base + ".txt")
    if not os.path.exists(src_lbl):
        skipped += 1
        continue
    out_lines = []
    with open(src_lbl) as f:
        for line in f:
            p = line.split()
            if len(p) < 5:
                continue
            c = int(float(p[0]))
            if c not in INV:
                bad += 1
                continue
            nc = INV[c]
            out_lines.append(f"{nc} {' '.join(p[1:5])}\n")
    with open(os.path.join(DST, "labels", base + ".txt"), "w") as f:
        f.writelines(out_lines)
    # 复制图像（保持原图，便于并入训练）
    shutil.copy2(os.path.join(SRC, "images", im), os.path.join(DST, "images", im))
    fixed += 1

print(f"修复完成: 处理图 {fixed}, 跳过(无标签) {skipped}, 未知类 {bad}")
print(f"输出目录: {DST}")

# 校验：统计修复后各类分布
from collections import Counter
cnt = Counter()
for fn in os.listdir(os.path.join(DST, "labels")):
    for line in open(os.path.join(DST, "labels", fn)):
        p = line.split()
        if len(p) >= 5:
            cnt[int(float(p[0]))] += 1
NAMES = ["porosity","crack","overlap","spatters","good_weld","undercut","unfused"]
print("修复后切片类分布(class:count):", {NAMES[k]:v for k,v in sorted(cnt.items())})
print("对照 raw_mine 原始类分布(应为 0,1,2,3,4): porosity10 crack10 overlap10 spatters17 good_weld10")
