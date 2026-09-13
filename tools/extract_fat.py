"""
从 EN1993-1-9 OCR 中抽取疑似 FAT 数值及其上下文，辅助人工校核知识库。
FAT 取值通常在 25~160 区间；本工具扫描该范围内孤立整数并列出上下文行。
用法:
  python tools/extract_fat.py
  python tools/extract_fat.py --ocr "..\\EN1993-1-9_ocr.txt" --min 50 --max 160
"""
import argparse
import os
import re

DEFAULT_OCR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "..", "EN1993-1-9_ocr.txt")


def extract(ocr_path, lo, hi):
    with open(ocr_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    pat = re.compile(r"(?<!\d)(\d{2,3})(?!\d)")
    out = []
    for i, line in enumerate(lines, 1):
        for m in pat.finditer(line):
            v = int(m.group(1))
            if lo <= v <= hi:
                out.append((i, v, line.strip()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ocr", default=DEFAULT_OCR)
    ap.add_argument("--min", type=int, default=50)
    ap.add_argument("--max", type=int, default=160)
    args = ap.parse_args()
    rows = extract(args.ocr, args.min, args.max)
    print(f"在 {args.ocr} 中找到 {len(rows)} 个疑似 FAT 候选：")
    for ln, v, txt in rows:
        print(f"  L{ln}: FAT≈{v}  | {txt[:80]}")


if __name__ == "__main__":
    main()
