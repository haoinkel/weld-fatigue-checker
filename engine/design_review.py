"""
结构设计合理性审查模块（3D 图 / CAD / LiDAR 扫描 -> 接头细节 + FAT + 不合理处 + 改型建议）
与焊缝外观识别（照片）互补：3D 提供几何与传力路径（决定 FAT），照片提供表面缺陷。

本模块不做"自动通过/不通过"的设计签字，而是把识别出的细节与一组
"抗疲劳良好细部"规则比对，标出不合理/疲劳不利的细部，并给出可落地的改善建议
（含改型后可提升到的目标 FAT 与工作量估算）。

规则 R1~R16 覆盖欧标 EN1993-1-9 / IIW 推荐的良好细部实践。每条含：
  severity   : high(严重/必须改) | medium(建议改) | low(可优化)
  title      : 一句话问题
  finding    : 不合理之处描述
  when       : 触发条件(函数)
  suggestions: [{action, raises_fat_to, effort}]
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import json
from engine import fatigue

DESIGN_SCHEMA = {
    "source": "3D model / CAD drawing / LiDAR scan",
    "joint_type": "butt | fillet | t_joint | corner | lap | cruciform",
    "weld_type": "butt | fillet",
    "loading_direction": "transverse | longitudinal",
    "load_carrying": "bool（荷载是否经焊缝传递；十字接头=true）",
    "full_penetration": "bool",
    "ground_flush": "bool（是否已打磨与母材齐平）",
    "attachment_length_mm": "float | null（附件/加劲肋长度）",
    "plate_thickness_mm": "float",
    "cope_hole": "bool（梁端是否设切孔）",
    "in_tension_zone": "bool（是否位于拉应力区）",
    "stiffener_end": "'square' | 'radius' | 'taper'（加劲肋端部形式）",
    "cover_termination": "'abrupt' | 'taper'（盖板/附件端部终止形式）",
    "misalignment_mm": "float | null（错边量 e）",
    "intermittent": "bool（是否为间断焊缝）",
    "weld_continuous": "bool（焊缝是否连续）",
    "runoff_tabs": "bool（是否使用引/收弧板）",
    "improvements_applied": "list（已实施的焊趾改善措施）",
}


def match_detail(d):
    """由 3D 识别的几何/传力属性映射到 EN1993-1-9 细节 id。"""
    jt = d.get("joint_type")
    wt = d.get("weld_type")
    ld = d.get("loading_direction")
    lc = d.get("load_carrying", False)
    cover = d.get("cover_termination") == "abrupt"
    if wt == "butt":
        return "W_BUTT_GROUND" if d.get("ground_flush") else "W_BUTT_ASWELD"
    if wt == "fillet":
        if ld == "longitudinal":
            return "W_FILLET_LONG"
        return "W_FILLET_TRANS_LC" if lc else "W_FILLET_TRANS_NLC"
    if jt in ("t_joint", "cruciform"):
        return "W_FILLET_TRANS_LC" if lc else "W_FILLET_TRANS_NLC"
    if jt in ("corner", "lap"):
        return "W_FILLET_TRANS_NLC"
    return None


# 抗疲劳良好细部规则（条件 -> 不合理处 + 改型建议）
# severity: high 必须改 / medium 建议改 / low 可优化
DETAILING_RULES = [
    {
        "id": "R1", "severity": "high",
        "title": "承载十字/角接头 FAT 过低",
        "when": lambda d: d.get("load_carrying") and d.get("joint_type") in ("cruciform", "t_joint", "fillet", "corner"),
        "finding": "荷载经角焊缝传递（十字/承载角接头），FAT≈80 为较低等级，疲劳寿命对 Δσ 极敏感。",
        "suggestions": [
            {"action": "改为非承载纵向附件（焊缝平行受力），或改为全熔透对接焊", "raises_fat_to": 125, "effort": "中（需改图）"},
            {"action": "对焊趾施加锤击/针束锤击强化", "raises_fat_to": 112, "effort": "低（焊后处理）"},
            {"action": "对焊趾打磨或 TIG 熔修", "raises_fat_to": 100, "effort": "低（焊后处理）"},
        ],
    },
    {
        "id": "R2", "severity": "medium",
        "title": "对接焊缝未打磨齐平",
        "when": lambda d: d.get("weld_type") == "butt" and not d.get("ground_flush"),
        "finding": "横向对接焊缝焊态 FAT≈100；余高与母材过渡不平滑，焊趾存在应力集中。",
        "suggestions": [
            {"action": "打磨焊缝与母材齐平", "raises_fat_to": 125, "effort": "低（焊后处理）"},
            {"action": "100% 探伤 + 双面打磨齐平 + 无起止点（自动焊）", "raises_fat_to": 140, "effort": "中"},
        ],
    },
    {
        "id": "R3", "severity": "high",
        "title": "拉应力区采用部分熔透",
        "when": lambda d: d.get("in_tension_zone") and not d.get("full_penetration"),
        "finding": "位于拉应力区的接头采用部分熔透，根部为疲劳薄弱面，FAT 显著低于全熔透。",
        "suggestions": [
            {"action": "改为全熔透焊缝（K 型/双面焊，保证根部焊透）", "raises_fat_to": 125, "effort": "中（需改图与工艺）"},
            {"action": "端部加引/收弧板，避免弧坑裂纹后去除打磨", "raises_fat_to": None, "effort": "低"},
        ],
    },
    {
        "id": "R4", "severity": "medium",
        "title": "横向附件长度偏短",
        "when": lambda d: d.get("loading_direction") == "transverse"
                          and d.get("attachment_length_mm") is not None
                          and d.get("attachment_length_mm") < 50,
        "finding": "横向受力附件/加劲肋长度过短，焊趾附近应力集中系数偏高。",
        "suggestions": [
            {"action": "加长附件至 l ≥ 1.5×板宽或端部斜切过渡", "raises_fat_to": 90, "effort": "中（需改图）"},
            {"action": "端部采用斜面/圆弧过渡，降低焊趾应力集中", "raises_fat_to": 90, "effort": "低"},
        ],
    },
    {
        "id": "R5", "severity": "medium",
        "title": "梁端未设切孔(cope hole)",
        "when": lambda d: d.get("joint_type") in ("t_joint",) and not d.get("cope_hole"),
        "finding": "梁端腹板处未设切孔，焊缝收弧于腹板自由边，产生局部应力集中与弧坑裂纹风险。",
        "suggestions": [
            {"action": "增设端部切孔(cope hole)或端部铣切成型", "raises_fat_to": 90, "effort": "中（需改图）"},
            {"action": "采用连续焊并端部打磨圆滑过渡", "raises_fat_to": 80, "effort": "低"},
        ],
    },
    {
        "id": "R6", "severity": "low",
        "title": "纵向角焊缝 FAT 最低",
        "when": lambda d: d.get("weld_type") == "fillet" and d.get("loading_direction") == "longitudinal",
        "finding": "纵向角焊缝 FAT≈71（最低一级），仅适用于非承载且应力水平较低处。",
        "suggestions": [
            {"action": "若实际承载，改为全熔透对接焊", "raises_fat_to": 125, "effort": "中"},
            {"action": "对焊趾施加改善措施（打磨/TIG/锤击）", "raises_fat_to": 100, "effort": "低"},
        ],
    },
    {
        "id": "R7", "severity": "medium",
        "title": "盖板/附件端部 abrupt 终止",
        "when": lambda d: d.get("cover_termination") == "abrupt",
        "finding": "盖板或附件端部 abrupt 终止（直角收尾），端部焊趾应力集中大，FAT≈80。",
        "suggestions": [
            {"action": "端部削薄/斜面过渡(taper)，长度≥5×板厚", "raises_fat_to": 100, "effort": "中（需改图）"},
            {"action": "盖板全长焊接并对端部焊趾打磨", "raises_fat_to": 90, "effort": "低"},
        ],
    },
    {
        "id": "R8", "severity": "medium",
        "title": "焊缝位于受拉自由边",
        "when": lambda d: d.get("in_tension_zone") and d.get("joint_type") in ("lap", "corner", "fillet")
                          and d.get("weld_type") == "fillet",
        "finding": "角焊缝/搭接焊位于板件受拉自由边附近，净截面焊趾受拉，FAT≈80 且易起裂。",
        "suggestions": [
            {"action": "将焊缝移离自由边，或把该边改为轧制/机加工边", "raises_fat_to": 90, "effort": "中"},
            {"action": "对焊趾打磨/TIG 改善并做磁粉探伤", "raises_fat_to": 100, "effort": "低"},
        ],
    },
    {
        "id": "R9", "severity": "medium",
        "title": "厚板尺寸效应未处理 (t>25mm)",
        "when": lambda d: (d.get("plate_thickness_mm") or 0) > 25,
        "finding": "板厚 t>25mm 时 EN1993-1-9 引入尺寸效应，FAT 按 (25/t)^0.25 折减，疲劳等级实际下降。",
        "suggestions": [
            {"action": "对厚板焊趾施加锤击/打磨改善，抵消尺寸效应", "raises_fat_to": 112, "effort": "低（焊后处理）"},
            {"action": "细部设计中避免厚板焊趾位于高 Δσ 区", "raises_fat_to": None, "effort": "中（需改图）"},
        ],
    },
    {
        "id": "R10", "severity": "medium",
        "title": "对接错边(未对齐)",
        "when": lambda d: d.get("misalignment_mm") is not None and d.get("misalignment_mm") > 0,
        "finding": "对接接头存在母材错边 e，产生二阶弯曲应力，按 EN1993-1-9 需乘折减系数 k_m。",
        "suggestions": [
            {"action": "装配对齐，控制错边 e ≤ 0.15t 并局部打磨过渡", "raises_fat_to": None, "effort": "低（装配工艺）"},
            {"action": "对高 Δσ 区改用全熔透+打磨齐平", "raises_fat_to": 125, "effort": "中"},
        ],
    },
    {
        "id": "R11", "severity": "low",
        "title": "焊缝交叉处应力集中",
        "when": lambda d: d.get("joint_type") == "cruciform" and d.get("load_carrying") is False
                          and d.get("crossing", False),
        "finding": "横向焊缝与纵向焊缝交叉处，交叉点焊趾 FAT≈80 且双向应力叠加。",
        "suggestions": [
            {"action": "重新布置焊缝，避免交叉；不可避免时交叉处打磨", "raises_fat_to": 90, "effort": "中（需改图）"},
        ],
    },
    {
        "id": "R12", "severity": "high",
        "title": "受拉区焊缝起止点(弧坑)未处理",
        "when": lambda d: d.get("in_tension_zone") and not d.get("runoff_tabs", True)
                          and d.get("weld_type") == "butt",
        "finding": "对接焊缝起止点位于受拉区且无引/收弧板，弧坑为典型裂纹起源，FAT 显著下降。",
        "suggestions": [
            {"action": "使用引/收弧板(run-off tabs)，焊后去除并打磨", "raises_fat_to": 112, "effort": "低（工艺）"},
            {"action": "起止点移至低应力区并打磨", "raises_fat_to": 100, "effort": "低"},
        ],
    },
    {
        "id": "R13", "severity": "low",
        "title": "高周疲劳未施加焊趾改善",
        "when": lambda d: d.get("high_cycle", False) and not d.get("improvements_applied"),
        "finding": "设计寿命 >5×10^6 次（高周疲劳）的细部未施加焊趾改善，未利用可提升的 FAT 上限。",
        "suggestions": [
            {"action": "对关键焊趾施加 TIG 熔修/锤击，FAT 上限可达 125", "raises_fat_to": 125, "effort": "低"},
        ],
    },
    {
        "id": "R14", "severity": "medium",
        "title": "加劲肋端部为方形",
        "when": lambda d: d.get("stiffener_end") == "square",
        "finding": "加劲肋端部方形收尾，焊趾应力集中明显（FAT≈80），易在端部起裂。",
        "suggestions": [
            {"action": "端部改为圆弧过渡(r≥... )或将端部切成斜面", "raises_fat_to": 90, "effort": "中（需改图）"},
            {"action": "端部焊趾打磨并做无损检测", "raises_fat_to": 90, "effort": "低"},
        ],
    },
    {
        "id": "R15", "severity": "low",
        "title": "间断焊缝参数不利",
        "when": lambda d: d.get("intermittent") and d.get("weld_continuous") is False,
        "finding": "间断角焊缝端部焊趾 FAT≈80；若 g/h>25 则端部效应更不利。",
        "suggestions": [
            {"action": "改为连续焊缝，或控制间距 g/h ≤ 25", "raises_fat_to": None, "effort": "中（需改图）"},
        ],
    },
    {
        "id": "R16", "severity": "low",
        "title": "焊脚尺寸可能不足",
        "when": lambda d: d.get("leg_size_mm") is not None and d.get("required_leg_mm") is not None
                          and d.get("leg_size_mm") < d.get("required_leg_mm"),
        "finding": "实际焊脚尺寸小于所需喉厚对应的焊脚，静强度与疲劳喉部均不足。",
        "suggestions": [
            {"action": "加大焊脚至满足喉厚 a≥0.7×所需焊脚，并重新评估 FAT", "raises_fat_to": None, "effort": "中（工艺）"},
        ],
    },
]


def review_design(design_input):
    """审查 3D 设计输入，返回 {detail_id, detail_name, base_fat, warnings, recommendations}。"""
    detail_id = match_detail(design_input)
    if detail_id is None:
        return {"detail_id": None, "detail_name": None, "base_fat": None,
                "warnings": [{"id": "M0", "severity": "high", "title": "无法映射细节",
                              "finding": "无法由几何映射细节类别。",
                              "suggestions": [{"action": "请在界面确认接头类型/焊缝类型/荷载方向", "raises_fat_to": None, "effort": "—"}]}],
                "recommendations": []}
    d = fatigue.find_detail(detail_id)
    warnings = []
    for r in DETAILING_RULES:
        try:
            if r["when"](design_input):
                warnings.append({"id": r["id"], "severity": r["severity"],
                                 "title": r["title"], "finding": r["finding"],
                                 "suggestions": r["suggestions"]})
        except Exception:
            pass
    # 按严重度排序：high -> medium -> low
    order = {"high": 0, "medium": 1, "low": 2}
    warnings.sort(key=lambda w: order.get(w["severity"], 3))
    recs = []
    for w in warnings:
        for s in w["suggestions"]:
            tgt = f"（目标FAT≈{s['raises_fat_to']}）" if s.get("raises_fat_to") else ""
            recs.append(f"[{w['id']}/{w['severity']}] {w['title']}：{s['action']}{tgt}（{s['effort']}）")
    return {
        "detail_id": detail_id,
        "detail_name": d["name"],
        "base_fat": d["fat"],
        "warnings": warnings,
        "recommendations": recs,
    }


def suggest_improvements(design_input, fatigue_fail=False):
    """
    生成按优先级排序的改型计划（去重、合并）。
    返回 [{'priority','rule_id','title','action','raises_fat_to','effort'}]
    """
    dr = review_design(design_input)
    plan = []
    seen = set()
    for w in dr["warnings"]:
        for s in w["suggestions"]:
            key = (s["action"], s.get("raises_fat_to"))
            if key in seen:
                continue
            seen.add(key)
            plan.append({
                "priority": w["severity"],
                "rule_id": w["id"],
                "title": w["title"],
                "action": s["action"],
                "raises_fat_to": s.get("raises_fat_to"),
                "effort": s["effort"],
            })
    order = {"high": 0, "medium": 1, "low": 2}
    plan.sort(key=lambda p: (order.get(p["priority"], 3), p["rule_id"]))
    if fatigue_fail and plan:
        plan.insert(0, {"priority": "high", "rule_id": "F0", "title": "疲劳强度不足",
                        "action": "优先降低应力幅 Δσ 或提升 FAT（见下方改型），使利用率≤1",
                        "raises_fat_to": None, "effort": "—"})
    return plan


def combined_assessment(design_input, vision_input, user_params):
    """
    双通道综合：3D 定细节(几何权威) + 照片定表面缺陷。
    vision_input 可为空 {}（仅做设计审查时）。
    """
    dr = review_design(design_input)
    detail_id = dr["detail_id"] or vision_input.get("detail_candidate")
    improvements = vision_input.get("improvements_applied", [])
    if design_input.get("ground_flush") and detail_id == "W_BUTT_ASWELD":
        improvements = list(improvements) + ["__ground__"]
    fc = fatigue.constant_amplitude_check(
        detail_id, user_params["delta_sigma"], user_params["n_required"],
        improvements_applied=[i for i in improvements if i != "__ground__"],
        gamma_mf=user_params.get("gamma_mf", 1.0),
    )
    imp_results = fatigue.evaluate_imperfections(
        user_params.get("thickness", design_input.get("plate_thickness_mm", 0)),
        user_params.get("quality_level", "C"),
        vision_input.get("imperfections", []),
    )
    plan = suggest_improvements(design_input, fatigue_fail=not fc["pass"])

    # 疲劳不足的通用建议
    if not fc["pass"]:
        plan.append({"priority": "high", "rule_id": "F1", "title": "疲劳强度不满足",
                     "action": "降低 Δσ / 增加板厚 / 焊趾打磨或 TIG/锤击提升 FAT，或优化细部设计",
                     "raises_fat_to": None, "effort": "—"})
    fatigue_critical = [r for r in imp_results if r.get("fatigue_relevant") and r.get("accepted") is False]
    for r in fatigue_critical:
        plan.append({"priority": "medium", "rule_id": "I1", "title": f"缺陷超差: {r['label']}",
                     "action": f"「{r['label']}」超 {user_params.get('quality_level','C')} 级且位于焊趾，建议打磨改善疲劳",
                     "raises_fat_to": None, "effort": "低"})

    # 去重（按 action）
    final = []
    seen = set()
    for p in plan:
        if p["action"] in seen:
            continue
        seen.add(p["action"])
        final.append(p)
    if not final:
        final.append({"priority": "ok", "rule_id": "OK", "title": "满足要求",
                      "action": "结构设计细节与表面质量在当前输入下满足疲劳要求。",
                      "raises_fat_to": None, "effort": "—"})
    return {
        "design": dr,
        "fatigue": fc,
        "imperfections": imp_results,
        "improvement_plan": final,
        "recommendations": [f"[{p['priority']}] {p['title']}: {p['action']}" for p in final],
        "disclaimer": "辅助判定，非认证检测；结论须由持证人员复核。",
    }


def demo_design():
    """示例 3D 设计输入：承载十字角接头（强迫低 FAT）+ 多处不合理，用于演示。"""
    return {
        "source": "sample 3D",
        "joint_type": "cruciform",
        "weld_type": "fillet",
        "loading_direction": "transverse",
        "load_carrying": True,
        "full_penetration": False,
        "ground_flush": False,
        "attachment_length_mm": 40,
        "plate_thickness_mm": 28,
        "cope_hole": False,
        "in_tension_zone": True,
        "stiffener_end": "square",
        "cover_termination": "abrupt",
        "misalignment_mm": 3.0,
        "intermittent": False,
        "weld_continuous": True,
        "runoff_tabs": False,
        "high_cycle": True,
        "crossing": False,
        "improvements_applied": [],
    }


if __name__ == "__main__":
    dr = review_design(demo_design())
    print(json.dumps(dr, ensure_ascii=False, indent=2))
    print("\n--- 改善计划 ---")
    for p in suggest_improvements(demo_design(), fatigue_fail=True):
        print(p)
