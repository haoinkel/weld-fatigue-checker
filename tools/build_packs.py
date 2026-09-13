# -*- coding: utf-8 -*-
"""build_packs.py —— 把 knowledge/*.json 迁移为「标准包 Standard Pack」格式。

标准包 = 一个自描述的 JSON 文件。后续要新增标准（GB 50017 / IIW / AWS D1.1 / BS 7608 / DNV 等），
只要按同一 schema 放一个 .pack.json 进来，注册表即可发现并启用，无需改动引擎代码。

用法：
    python tools/build_packs.py            # 生成/重建 knowledge/packs/
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KNOWLEDGE = os.path.join(ROOT, "knowledge")
PACKS = os.path.join(KNOWLEDGE, "packs")

SCHEMA_VERSION = "1.0"


def _load(name):
    with open(os.path.join(KNOWLEDGE, name), "r", encoding="utf-8") as fh:
        return json.load(fh)


def build_fatigue_pack():
    src = _load("en1993_1_9.json")
    return {
        "schema_version": SCHEMA_VERSION,
        "pack_id": "en1993-1-9",
        "kind": "fatigue",
        "code": "EN 1993-1-9:2005",
        "title": "钢结构设计 第1-9部分：疲劳",
        "region": "EU",
        "version": "2005",
        "language": "zh-CN",
        "verified": True,
        "verification_note": "FAT 值取自工作区 EN1993-1-9_ocr.txt（表 8.1/8.2），已用 tools/extract_fat.py 校核；"
                             "标注 verified=false 的条目须以原文复核。",
        "defaults": {
            "ref_N": 2000000,
            "gamma_mf_default": src.get("gamma_mf_default", 1.0),
            "sn_m": 3,
        },
        "sn_curve": src.get("sn_curve", {}),
        "detail_categories": [
            {
                "id": d["id"],
                "fat": d["fat"],
                "name": d["name"],
                "verified": bool(d.get("verified_from_ocr", False)),
                "note": d.get("note", ""),
            }
            for d in src["detail_categories"]
        ],
        "improvement_methods": [
            {
                "method": m["method"],
                "label": m["label"],
                "factor": m["factor"],
                "max_fat": m["max_fat"],
                "note": m.get("note", ""),
            }
            for m in src["improvement_methods"]
        ],
    }


def build_acceptance_pack():
    src = _load("iso5817.json")
    return {
        "schema_version": SCHEMA_VERSION,
        "pack_id": "iso5817",
        "kind": "acceptance",
        "code": "ISO 5817:2023",
        "title": "焊接 钢、镍及镍合金熔焊焊缝缺陷的质量等级",
        "region": "INT",
        "version": "2023",
        "language": "zh-CN",
        "verified": False,
        "verification_note": "⚠ 数值为示例，须以 ISO 5817:2023 PDF 原文逐条校核后方可用于工程判定。",
        "levels": src.get("levels", {}),
        "imperfections": src["imperfections"],
    }


def main():
    os.makedirs(PACKS, exist_ok=True)

    fatigue = build_fatigue_pack()
    acceptance = build_acceptance_pack()

    for pack, fname in ((fatigue, "en1993_1_9.pack.json"), (acceptance, "iso5817.pack.json")):
        path = os.path.join(PACKS, fname)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(pack, fh, ensure_ascii=False, indent=2)
        print("written: {} ({} 条{})".format(
            fname,
            len(pack.get("detail_categories", pack.get("imperfections", []))),
            "细节" if pack["kind"] == "fatigue" else "缺陷"))

    # 索引：若已存在则保留用户当前的 active 选择
    index_path = os.path.join(PACKS, "_index.json")
    active = {"fatigue": "en1993-1-9", "acceptance": "iso5817"}
    if os.path.exists(index_path):
        try:
            with open(index_path, "r", encoding="utf-8") as fh:
                old = json.load(fh)
            active = old.get("active", active)
        except Exception:
            pass

    index = {
        "schema_version": SCHEMA_VERSION,
        "active": active,
        "packs": [
            {"pack_id": p["pack_id"], "kind": p["kind"], "code": p["code"], "title": p["title"],
             "region": p["region"], "version": p["version"], "verified": p["verified"],
             "file": f}
            for p, f in ((fatigue, "en1993_1_9.pack.json"), (acceptance, "iso5817.pack.json"))
        ],
    }
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
    print("written: _index.json (active = {})".format(active))
    return 0


if __name__ == "__main__":
    sys.exit(main())
