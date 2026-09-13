# -*- coding: utf-8 -*-
"""build_packs_js.py —— 把 knowledge/packs/ 下的标准包同步给 PWA（离线内嵌）。

保证三端（Python / PWA / Swift）用的是同一份标准数据：
    knowledge/packs/*.pack.json  --(本脚本)-->  app_ios/pwa/js/packs.js

用法：
    python tools/build_packs_js.py
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PACKS = os.path.join(ROOT, "knowledge", "packs")
OUT = os.path.join(ROOT, "app_ios", "pwa", "js", "packs.js")


def main():
    if not os.path.isdir(PACKS):
        print("未找到 knowledge/packs/，请先运行 tools/build_packs.py")
        return 1

    index_path = os.path.join(PACKS, "_index.json")
    index = {}
    if os.path.exists(index_path):
        with open(index_path, "r", encoding="utf-8") as fh:
            index = json.load(fh)

    packs = {}
    for path in sorted(glob.glob(os.path.join(PACKS, "*.pack.json"))):
        with open(path, "r", encoding="utf-8") as fh:
            pack = json.load(fh)
        pid = pack.get("pack_id")
        if pid:
            packs[pid] = pack

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("/* 自动生成，请勿手改。\n")
        fh.write(" * 数据源：knowledge/packs/*.pack.json\n")
        fh.write(" * 生成命令：python tools/build_packs_js.py\n")
        fh.write(" * 标准包数量：%d\n */\n" % len(packs))
        fh.write("window.WF = window.WF || {};\n")
        fh.write("WF.PACKS = ")
        json.dump({"index": index, "packs": packs}, fh, ensure_ascii=False, indent=2)
        fh.write(";\n")

    print("written: %s" % OUT)
    for pid, p in packs.items():
        n = len(p.get("detail_categories", p.get("imperfections", [])))
        print("  - %-16s %-14s %s (%d 条)" % (pid, p.get("kind"), p.get("code"), n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
