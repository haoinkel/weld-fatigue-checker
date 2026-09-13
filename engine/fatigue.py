"""
焊缝疲劳校核引擎（纯标准库，可整体移植到 Swift / Core ML 端）
依据：默认 EN 1993-1-9:2005 (S-N 曲线, FAT 细节类别, 改善系数)
      + ISO 5817:2023      (焊缝表面缺陷质量等级验收)

★ 标准是可插拔的：本引擎通过 engine/standard_registry.py 读取「当前启用的标准包」，
  新增/升级标准（GB 50017、IIW、AWS、BS 7608、DNV …）只需放入标准包并切换 active，
  无需改动本文件。详见 knowledge/packs/README.md。

仅做等幅/变幅（Miner）疲劳验算与表面缺陷验收判定。
⚠ 非认证检测工具，结论须由持证人员复核。
"""
import json
import os
import math
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KNOWLEDGE_DIR = os.path.join(HERE, "..", "knowledge")
if os.path.dirname(HERE) not in sys.path:
    sys.path.insert(0, os.path.dirname(HERE))

_REF_N = 2_000_000  # 默认参考循环次数（当前启用的标准包可覆盖）

# 标准包注册表（开放接口）：新增/升级标准无需改动本文件
try:
    from engine import standard_registry as SR
except Exception:      # 允许 engine/fatigue.py 作为脚本直接运行
    try:
        import standard_registry as SR
    except Exception:
        SR = None


def _load(name):
    with open(os.path.join(KNOWLEDGE_DIR, name), "r", encoding="utf-8") as f:
        return json.load(f)


def _fatigue_kb():
    """当前启用的疲劳标准（标准包优先，失败回退旧 JSON）。"""
    if SR is not None:
        try:
            return SR.fatigue_view()
        except Exception:
            pass
    kb = _load("en1993_1_9.json")
    return {"code": kb.get("standard"), "version": "2005", "ref_N": _REF_N,
            "detail_categories": kb["detail_categories"],
            "improvement_methods": kb["improvement_methods"]}


def _acceptance_kb():
    """当前启用的验收标准（标准包优先，失败回退旧 JSON）。"""
    if SR is not None:
        try:
            return SR.acceptance_view()
        except Exception:
            pass
    return _load("iso5817.json")


def active_standards():
    """返回当前生效的标准，便于在报告/界面中标注判定依据。"""
    f, a = _fatigue_kb(), _acceptance_kb()
    return {"fatigue": f.get("code"), "fatigue_version": f.get("version"),
            "acceptance": a.get("code"), "acceptance_version": a.get("version")}


def find_detail(detail_id):
    """按 id 在当前启用的疲劳标准包中查找细节类别。"""
    kb = _fatigue_kb()
    for d in kb["detail_categories"]:
        if d["id"] == detail_id:
            return d
    return None


def effective_fat(detail_id, improvements_applied=None):
    """
    计算考虑改善措施后的有效 FAT。
    detail_id: 细节类别 id
    improvements_applied: 已实施的改善方法 method 列表，如 ['toe_grinding']
    返回 (fat_eff, details)
    """
    improvements_applied = improvements_applied or []
    d = find_detail(detail_id)
    if d is None:
        raise ValueError(f"未知细节类别: {detail_id}")
    base = d["fat"]
    kb = _fatigue_kb()
    fat_eff = float(base)
    applied = []
    for imp in kb["improvement_methods"]:
        if imp["method"] in improvements_applied:
            capped = min(fat_eff * imp["factor"], imp["max_fat"])
            applied.append({
                "method": imp["method"],
                "label": imp["label"],
                "factor": imp["factor"],
                "fat_before": fat_eff,
                "fat_after": capped,
            })
            fat_eff = capped
    return fat_eff, applied


def allowable_cycles(fat, delta_sigma, gamma_mf=1.0):
    """
    等幅荷载下允许循环次数（设计 S-N 曲线，斜率 m=3）。
    Δσ_eff = γ_Mf · Δσ；N = ref_N · (FAT / Δσ_eff)^3
    返回允许次数（float）。
    """
    delta_eff = gamma_mf * float(delta_sigma)
    if delta_eff <= 0:
        return float("inf")
    return _fatigue_kb().get("ref_N", _REF_N) * (fat / delta_eff) ** 3


def constant_amplitude_check(detail_id, delta_sigma, n_required,
                             improvements_applied=None, gamma_mf=1.0):
    """
    单一等幅应力幅的疲劳验算。
    返回报告字典：FAT、有效FAT、允许次数、需求次数、利用率、结论。
    """
    fat_eff, applied = effective_fat(detail_id, improvements_applied)
    n_allow = allowable_cycles(fat_eff, delta_sigma, gamma_mf)
    util = n_required / n_allow if n_allow > 0 else float("inf")
    d = find_detail(detail_id)
    return {
        "detail_id": detail_id,
        "detail_name": d["name"],
        "base_fat": d["fat"],
        "improvements": applied,
        "effective_fat": fat_eff,
        "delta_sigma": float(delta_sigma),
        "gamma_mf": gamma_mf,
        "n_required": n_required,
        "n_allowable": n_allow,
        "utilization": util,            # >1 表示不满足
        "pass": util <= 1.0,
    }


def miner_check(detail_id, spectrum, improvements_applied=None, gamma_mf=1.0):
    """
    变幅荷载（Miner 线性累积损伤）。
    spectrum: [(delta_sigma_i, n_i), ...]
    返回 {damage, pass, blocks:[...]}
    """
    fat_eff, applied = effective_fat(detail_id, improvements_applied)
    blocks = []
    damage = 0.0
    for ds, n in spectrum:
        n_allow = allowable_cycles(fat_eff, ds, gamma_mf)
        di = n / n_allow if n_allow > 0 else float("inf")
        damage += di
        blocks.append({"delta_sigma": ds, "n": n, "n_allow": n_allow, "d_i": di})
    return {
        "detail_id": detail_id,
        "effective_fat": fat_eff,
        "improvements": applied,
        "gamma_mf": gamma_mf,
        "damage": damage,
        "pass": damage <= 1.0,
        "blocks": blocks,
    }


def evaluate_imperfections(thickness, quality_level, imperfections):
    """
    按 ISO 5817 验收表面缺陷。
    thickness: 母材厚度 mm（用于与 t 成比例的限值）
    quality_level: 'B'|'C'|'D'
    imperfections: [{'type':..., 'size_mm':..., 'pore_mm':...}, ...]
    返回 [{'type','label','accepted','limit','value','fatigue_relevant','note'}]
    """
    iso = _acceptance_kb()
    results = []
    for imp in imperfections:
        spec = next((x for x in iso["imperfections"] if x["type"] == imp["type"]), None)
        if spec is None:
            results.append({"type": imp["type"], "label": imp.get("type"),
                            "accepted": None, "note": "ISO5817 中无此类型定义"})
            continue
        lim = spec["limits"].get(quality_level)
        accepted = None
        limit_txt = lim.get("formula", "") if lim else "无该等级定义"
        if lim and "value" in lim and imp.get("size_mm") is not None:
            ref = lim.get("ref")
            thr = lim["value"] * (thickness if ref == "t" else 1.0)
            if lim.get("max_abs") is not None:
                thr = min(thr, lim["max_abs"])
            accepted = imp["size_mm"] <= thr
            limit_txt = f"阈值≈{thr:.3f}mm, 实测={imp['size_mm']}mm"
        elif lim and imp.get("pore_mm") is not None and "max_pore" in lim:
            accepted = imp["pore_mm"] <= lim["max_pore"]
            limit_txt = f"最大孔径={lim['max_pore']}mm, 实测={imp['pore_mm']}mm"
        results.append({
            "type": imp["type"],
            "label": spec["label"],
            "accepted": accepted,
            "limit": limit_txt,
            "fatigue_relevant": spec.get("fatigue_relevant", False),
            "note": spec.get("note", ""),
        })
    return results


def full_assessment(vision_input, user_params):
    """
    端到端评估：视觉输入 + 用户荷载参数 -> 报告。
    vision_input: 见 engine/vision_adapter.py 的 JSON Schema
    user_params: {'delta_sigma','n_required','gamma_mf','quality_level','thickness'}
    返回综合报告 dict。
    """
    detail_id = vision_input.get("detail_candidate")
    improvements = vision_input.get("improvements_applied", [])
    fatigue = constant_amplitude_check(
        detail_id,
        user_params["delta_sigma"],
        user_params["n_required"],
        improvements_applied=improvements,
        gamma_mf=user_params.get("gamma_mf", 1.0),
    )
    imp_results = evaluate_imperfections(
        user_params.get("thickness", 0),
        user_params.get("quality_level", "C"),
        vision_input.get("imperfections", []),
    )
    # 疲劳相关缺陷未通过 -> 提示需打磨/复检（不改变 FAT，但给出整改建议）
    fatigue_critical = [r for r in imp_results
                        if r.get("fatigue_relevant") and r.get("accepted") is False]
    recommendations = []
    if not fatigue["pass"]:
        recommendations.append("疲劳强度不足：可降低应力幅、增加板厚、或采用焊趾打磨/TIG/锤击提升 FAT。")
    for r in fatigue_critical:
        recommendations.append(f"缺陷「{r['label']}」位于焊趾且超 {user_params.get('quality_level','C')} 级，建议打磨处理以改善疲劳性能。")
    if not recommendations:
        recommendations.append("接头细节与表面质量满足当前输入下的疲劳要求。")

    return {
        "standards": active_standards(),
        "joint_type": vision_input.get("joint_type"),
        "loading_direction": vision_input.get("loading_direction"),
        "fatigue": fatigue,
        "imperfections": imp_results,
        "recommendations": recommendations,
        "disclaimer": "辅助判定，非认证检测；结论须由持证人员复核。",
    }


if __name__ == "__main__":
    print("当前生效标准:", json.dumps(active_standards(), ensure_ascii=False))
    # 自测：横向非承载角焊缝 FAT80，Δσ=60MPa，需求 2e6 次
    fe, ap = effective_fat("W_FILLET_TRANS_NLC", ["toe_grinding"])
    print("有效FAT(焊趾打磨后):", fe)
    rep = constant_amplitude_check("W_FILLET_TRANS_NLC", 60, 2_000_000,
                                   improvements_applied=["toe_grinding"])
    print(json.dumps(rep, ensure_ascii=False, indent=2))
