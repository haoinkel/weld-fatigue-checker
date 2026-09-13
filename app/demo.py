"""
焊缝疲劳检查 - 命令行演示 (Python 3, 标准库)
支持双通道输入：
  1) 3D 设计 (--design-json)：审查接头细节合理性 -> 决定 FAT
  2) 照片识别 (--vision-json)：表面缺陷验收
两者结合做疲劳校核。识别模型未接入时可用内置示例。

用法:
  python app/demo.py --demo-design --delta-sigma 70 --n 2000000
  python app/demo.py --design-json d.json --vision-json v.json --delta-sigma 60 --n 2000000 --level C
  python app/demo.py                         # 仅照片通道(内置示例)
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine import fatigue
from engine import design_review
from engine import geometry_adapter
from engine.vision_adapter import VisionAdapter, demo_input


def print_report(rep):
    print("=" * 56)
    print("焊缝疲劳评估报表（双通道）")
    print("=" * 56)

    if "design" in rep:  # 综合（含 3D 设计）
        d = rep["design"]
        print(f"【3D 设计审查】细节: {d['detail_name']} (FAT={d['base_fat']})")
        for w in d["warnings"]:
            tag = {"high": "严重", "medium": "建议", "low": "可优化"}.get(w["severity"], w["severity"])
            print(f"   [{tag}] {w['id']} {w['title']}")
            print(f"       不合理处: {w['finding']}")
            for s in w["suggestions"]:
                tgt = f"（目标FAT≈{s['raises_fat_to']}）" if s.get("raises_fat_to") else ""
                print(f"       改善: {s['action']} {tgt}（{s['effort']}）")

    f = rep["fatigue"]
    print("-" * 56)
    print("【疲劳强度】")
    print(f"  细节类别      : {f['detail_name']} ({f['detail_id']})")
    print(f"  基准 FAT       : {f['base_fat']}")
    if f["improvements"]:
        for im in f["improvements"]:
            print(f"  改善措施       : {im['label']} ×{im['factor']} -> FAT {im['fat_after']}")
    print(f"  有效 FAT       : {f['effective_fat']}")
    print(f"  应力幅 Δσ       : {f['delta_sigma']} MPa  (γ_Mf={f['gamma_mf']})")
    print(f"  允许次数       : {f['n_allowable']:.3e}")
    print(f"  需求次数       : {f['n_required']:.3e}")
    print(f"  利用率         : {f['utilization']:.3f}  (>1 不满足)")
    print(f"  结论           : {'满足' if f['pass'] else '不满足'}")
    print("-" * 56)
    print("【表面缺陷 (ISO 5817)】")
    for r in rep["imperfections"]:
        st = "通过" if r["accepted"] is True else ("超差" if r["accepted"] is False else "未判定")
        fr = " [疲劳相关]" if r.get("fatigue_relevant") else ""
        print(f"  - {r['label']}: {st} | {r.get('limit','')}{fr}")
    print("-" * 56)
    if "improvement_plan" in rep:
        print("【改善建议（按优先级）】")
        for i, p in enumerate(rep["improvement_plan"], 1):
            tgt = f"（目标FAT≈{p['raises_fat_to']}）" if p.get("raises_fat_to") else ""
            print(f"  {i}. [{p['priority']}] {p['rule_id']} {p['title']}: {p['action']} {tgt}（{p['effort']}）")
    print("【整改建议】")
    for i, rec in enumerate(rep["recommendations"], 1):
        print(f"  {i}. {rec}")
    print("=" * 56)
    print("免责:", rep["disclaimer"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--design-json", help="3D 设计输入 JSON")
    ap.add_argument("--design-obj", help="3D 模型 OBJ 文件（自动解析几何）")
    ap.add_argument("--design-meta", help="OBJ 配套的接头属性 meta JSON")
    ap.add_argument("--demo-design", action="store_true", help="使用内置示例 3D 设计")
    ap.add_argument("--vision-json", help="照片识别输入 JSON")
    ap.add_argument("--delta-sigma", type=float, default=60.0)
    ap.add_argument("--n", type=float, default=2_000_000)
    ap.add_argument("--level", default="C", choices=["B", "C", "D"])
    ap.add_argument("--thickness", type=float, default=12.0)
    ap.add_argument("--gamma-mf", type=float, default=1.0)
    args = ap.parse_args()

    vision_input = VisionAdapter.from_json(args.vision_json) if args.vision_json else demo_input()
    design_input = None
    if args.design_json:
        with open(args.design_json, "r", encoding="utf-8") as fh:
            design_input = json.load(fh)
    elif args.design_obj:
        meta = None
        if args.design_meta:
            with open(args.design_meta, "r", encoding="utf-8") as fh:
                meta = json.load(fh)
        design_input = geometry_adapter.ObjIngestor().ingest(args.design_obj, meta)
    elif args.demo_design:
        design_input = design_review.demo_design()

    user_params = {
        "delta_sigma": args.delta_sigma,
        "n_required": args.n,
        "quality_level": args.level,
        "thickness": args.thickness,
        "gamma_mf": args.gamma_mf,
    }

    if design_input:
        rep = design_review.combined_assessment(design_input, vision_input, user_params)
    else:
        rep = fatigue.full_assessment(vision_input, user_params)
    print_report(rep)


if __name__ == "__main__":
    main()
