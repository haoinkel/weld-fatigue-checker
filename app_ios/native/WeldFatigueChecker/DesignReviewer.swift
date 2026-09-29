// DesignReviewer.swift
// 设计审查规则 R1~R16（移植自 engine/design_review.py）
// 标出不合理/疲劳不利细部，并给出可落地的改型建议（含目标 FAT 与工作量）。

import Foundation

struct Rule {
    let id: String
    let severity: String        // high | medium | low
    let title: String
    let condition: (DesignInput) -> Bool
    let finding: String
    let suggestions: [ImprovementSuggestion]
}

enum DesignReviewer {
    /// 由几何/传力属性映射到 EN1993-1-9 细节 id
    /// 注意：ID 与 v5 校正版数据（表 8.4/8.5 权威 W 系列）保持一致；
    /// 旧占位 ID 经 KnowledgeBank.findDetail 的别名映射仍可解析。
    ///
    /// 扩展后覆盖表 8.3/8.4/8.5 的完整几何分级维度：
    ///   · 对接(8.3)：打磨齐平 → 125，焊态 → 100
    ///   · 传力十字/T/角接头(8.5)：焊趾 80；部分熔透/角焊根部另按 36* 双评估（见 R17）
    ///   · 横向非承载附件(8.4)：端部打磨 → 80，否则 L≤100 焊态 → 71
    ///   · 纵向附件(8.4 detail1~3)：按 r/L 分级 90/71/50
    static func matchDetail(_ d: DesignInput) -> String? {
        // 对接焊缝（表8.3）
        if d.weldType == "butt" {
            return d.groundFlush ? "W_BUTT_GROUND" : "W_BUTT_ASWELD"
        }
        // 传力接头（十字/T/角/承载角焊）→ 表8.5 焊趾失效 FAT80
        if d.loadCarrying && ["cruciform", "t_joint", "corner", "fillet"].contains(d.jointType) {
            return "W_CRUCIFORM_TOE_80"
        }
        // 搭接接头（表8.5 detail5）
        if d.jointType == "lap" {
            return "W_LAPJOINT_45"
        }
        // 以下为「非承载附件 / 角焊缝」按走向与几何分级（表8.4）
        // 横向非承载附件
        if d.loadingDirection == "transverse" {
            return d.attachmentToeGround ? "W_TA_TRANS_GROUND_80" : "W_TA_TRANS_71"
        }
        // 纵向非承载附件（表8.4 detail1~3）：按 r/L 分级
        if let L = d.attachmentLengthMm, L > 0, let r = d.transitionRadiusMm, r > 0 {
            let ratio = r / L
            if ratio >= 1.0 / 3.0 { return "W_LA_LONG_90" }   // r/L ≥ 1/3 → 90
            else if ratio >= 1.0 / 6.0 { return "W_LA_LONG_71" } // 1/6 ≤ r/L ≤ 1/3 → 71
            else { return "W_LA_LONG_50" }                    // 焊态无过渡半径 → 50
        }
        return "W_LA_LONG_50"   // 无 r/L 信息时按焊态保守归类
    }

    static let rules: [Rule] = [
        Rule(id: "R1", severity: "high", title: "承载十字/角接头 FAT 过低",
            condition: { $0.loadCarrying && ["cruciform","t_joint","fillet","corner"].contains($0.jointType) },
            finding: "荷载经角焊缝传递（十字/承载角接头），FAT≈80 为较低等级，疲劳寿命对 Δσ 极敏感。",
            suggestions: [
                ImprovementSuggestion(action: "改为非承载纵向附件或全熔透对接焊", raisesFatTo: 125, effort: "中(需改图)"),
                ImprovementSuggestion(action: "对焊趾施加锤击/针束锤击强化", raisesFatTo: 112, effort: "低(焊后)"),
                ImprovementSuggestion(action: "对焊趾打磨或 TIG 熔修", raisesFatTo: 100, effort: "低(焊后)")
            ]),
        Rule(id: "R2", severity: "medium", title: "对接焊缝未打磨齐平",
            condition: { $0.weldType == "butt" && !$0.groundFlush },
            finding: "横向对接焊缝焊态 FAT≈100；余高与母材过渡不平滑，焊趾应力集中。",
            suggestions: [
                ImprovementSuggestion(action: "打磨焊缝与母材齐平", raisesFatTo: 125, effort: "低(焊后)"),
                ImprovementSuggestion(action: "100%探伤+双面打磨齐平+无起止点(自动焊)", raisesFatTo: 140, effort: "中")
            ]),
        Rule(id: "R3", severity: "high", title: "拉应力区采用部分熔透",
            condition: { $0.inTensionZone && !$0.fullPenetration },
            finding: "位于拉应力区的接头采用部分熔透，根部为疲劳薄弱面，FAT 显著低于全熔透。",
            suggestions: [
                ImprovementSuggestion(action: "改为全熔透焊缝(K型/双面焊，保证根部焊透)", raisesFatTo: 125, effort: "中(改图工艺)"),
                ImprovementSuggestion(action: "端部加引/收弧板，避免弧坑裂纹后去除打磨", raisesFatTo: nil, effort: "低")
            ]),
        Rule(id: "R4", severity: "medium", title: "横向附件长度偏短",
            condition: { $0.loadingDirection == "transverse" && ($0.attachmentLengthMm ?? 99) < 50 },
            finding: "横向受力附件/加劲肋长度过短，焊趾附近应力集中系数偏高。",
            suggestions: [
                ImprovementSuggestion(action: "加长附件至 l≥1.5×板宽或端部斜切过渡", raisesFatTo: 90, effort: "中(改图)"),
                ImprovementSuggestion(action: "端部采用斜面/圆弧过渡降低应力集中", raisesFatTo: 90, effort: "低")
            ]),
        Rule(id: "R5", severity: "medium", title: "梁端未设切孔(cope hole)",
            condition: { $0.jointType == "t_joint" && !$0.copeHole },
            finding: "梁端腹板处未设切孔，焊缝收弧于腹板自由边，产生局部应力集中与弧坑裂纹风险。",
            suggestions: [
                ImprovementSuggestion(action: "增设端部切孔(cope hole)或端部铣切成型", raisesFatTo: 90, effort: "中(改图)"),
                ImprovementSuggestion(action: "采用连续焊并端部打磨圆滑过渡", raisesFatTo: 80, effort: "低")
            ]),
        Rule(id: "R6", severity: "low", title: "纵向角焊缝 FAT 最低",
            condition: { $0.weldType == "fillet" && $0.loadingDirection == "longitudinal" },
            finding: "纵向角焊缝 FAT≈71(最低一级)，仅适用于非承载且应力水平较低处。",
            suggestions: [
                ImprovementSuggestion(action: "若实际承载，改为全熔透对接焊", raisesFatTo: 125, effort: "中"),
                ImprovementSuggestion(action: "对焊趾施加改善措施(打磨/TIG/锤击)", raisesFatTo: 100, effort: "低")
            ]),
        Rule(id: "R7", severity: "medium", title: "盖板/附件端部 abrupt 终止",
            condition: { $0.coverTermination == "abrupt" },
            finding: "盖板或附件端部 abrupt 终止(直角收尾)，端部焊趾应力集中大，FAT≈80。",
            suggestions: [
                ImprovementSuggestion(action: "端部削薄/斜面过渡(taper)，长度≥5×板厚", raisesFatTo: 100, effort: "中(改图)"),
                ImprovementSuggestion(action: "盖板全长焊接并对端部焊趾打磨", raisesFatTo: 90, effort: "低")
            ]),
        Rule(id: "R8", severity: "medium", title: "焊缝位于受拉自由边",
            condition: { $0.inTensionZone && ["lap","corner","fillet"].contains($0.jointType) && $0.weldType == "fillet" },
            finding: "角焊缝/搭接焊位于板件受拉自由边附近，净截面焊趾受拉，FAT≈80 且易起裂。",
            suggestions: [
                ImprovementSuggestion(action: "将焊缝移离自由边，或把该边改为轧制/机加工边", raisesFatTo: 90, effort: "中"),
                ImprovementSuggestion(action: "对焊趾打磨/TIG 改善并做磁粉探伤", raisesFatTo: 100, effort: "低")
            ]),
        Rule(id: "R9", severity: "medium", title: "厚板尺寸效应未处理 (t>25mm)",
            condition: { $0.plateThicknessMm > 25 },
            finding: "板厚 t>25mm 时 EN1993-1-9 引入尺寸效应，FAT 按 (25/t)^0.25 折减。",
            suggestions: [
                ImprovementSuggestion(action: "对厚板焊趾施加锤击/打磨改善，抵消尺寸效应", raisesFatTo: 112, effort: "低(焊后)"),
                ImprovementSuggestion(action: "细部设计中避免厚板焊趾位于高 Δσ 区", raisesFatTo: nil, effort: "中(改图)")
            ]),
        Rule(id: "R10", severity: "medium", title: "对接错边(未对齐)",
            condition: { ($0.misalignmentMm ?? 0) > 0 },
            finding: "对接接头存在母材错边 e，产生二阶弯曲应力，需乘折减系数 k_m。",
            suggestions: [
                ImprovementSuggestion(action: "装配对齐，控制错边 e≤0.15t 并局部打磨过渡", raisesFatTo: nil, effort: "低(装配)"),
                ImprovementSuggestion(action: "对高 Δσ 区改用全熔透+打磨齐平", raisesFatTo: 125, effort: "中")
            ]),
        Rule(id: "R11", severity: "low", title: "焊缝交叉处应力集中",
            condition: { $0.jointType == "cruciform" && !$0.loadCarrying && $0.crossing },
            finding: "横向焊缝与纵向焊缝交叉处，交叉点焊趾 FAT≈80 且双向应力叠加。",
            suggestions: [
                ImprovementSuggestion(action: "重新布置焊缝避免交叉；不可避免时交叉处打磨", raisesFatTo: 90, effort: "中(改图)")
            ]),
        Rule(id: "R12", severity: "high", title: "受拉区焊缝起止点(弧坑)未处理",
            condition: { $0.inTensionZone && !$0.runoffTabs && $0.weldType == "butt" },
            finding: "对接焊缝起止点位于受拉区且无引/收弧板，弧坑为典型裂纹起源，FAT 显著下降。",
            suggestions: [
                ImprovementSuggestion(action: "使用引/收弧板(run-off tabs)，焊后去除并打磨", raisesFatTo: 112, effort: "低(工艺)"),
                ImprovementSuggestion(action: "起止点移至低应力区并打磨", raisesFatTo: 100, effort: "低")
            ]),
        Rule(id: "R13", severity: "low", title: "高周疲劳未施加焊趾改善",
            condition: { $0.highCycle && $0.improvementsApplied.isEmpty },
            finding: "设计寿命 >5e6 次(高周疲劳)的细部未施加焊趾改善，未利用可提升的 FAT 上限。",
            suggestions: [
                ImprovementSuggestion(action: "对关键焊趾施加 TIG 熔修/锤击，FAT 上限可达 125", raisesFatTo: 125, effort: "低")
            ]),
        Rule(id: "R14", severity: "medium", title: "加劲肋端部为方形",
            condition: { $0.stiffenerEnd == "square" },
            finding: "加劲肋端部方形收尾，焊趾应力集中明显(FAT≈80)，易在端部起裂。",
            suggestions: [
                ImprovementSuggestion(action: "端部改为圆弧过渡(r≥)或将端部切成斜面", raisesFatTo: 90, effort: "中(改图)"),
                ImprovementSuggestion(action: "端部焊趾打磨并做无损检测", raisesFatTo: 90, effort: "低")
            ]),
        Rule(id: "R15", severity: "low", title: "间断焊缝参数不利",
            condition: { $0.intermittent && !$0.weldContinuous },
            finding: "间断角焊缝端部焊趾 FAT≈80；若 g/h>25 则端部效应更不利。",
            suggestions: [
                ImprovementSuggestion(action: "改为连续焊缝，或控制间距 g/h ≤ 25", raisesFatTo: nil, effort: "中(改图)")
            ]),
        Rule(id: "R16", severity: "low", title: "焊脚尺寸可能不足",
            condition: { _ in false },   // 需 legSize/requiredLeg 字段，由 UI 补充；保留占位
            finding: "实际焊脚尺寸小于所需喉厚对应焊脚，静强度与疲劳喉部均不足。",
            suggestions: [
                ImprovementSuggestion(action: "加大焊脚至满足喉厚 a≥0.7×所需焊脚，并重新评估 FAT", raisesFatTo: nil, effort: "中(工艺)")
            ]),
        Rule(id: "R17", severity: "high", title: "部分熔透传力接头须双评估根部",
            condition: { (["cruciform","t_joint"].contains($0.jointType) || ($0.weldType == "fillet" && $0.loadCarrying)) && !$0.fullPenetration },
            finding: "部分熔透/角焊传力接头，除焊趾(FAT80)外，根部失效须按 FAT36* 双评估（EN1993-1-9 表8.5 detail2/3）。仅判焊趾会高估疲劳能力。",
            suggestions: [
                ImprovementSuggestion(action: "改为全熔透焊缝，消除根部失效面", raisesFatTo: 80, effort: "中(改图工艺)"),
                ImprovementSuggestion(action: "根部按 FAT36* 校核；不满足则全熔透或加厚", raisesFatTo: nil, effort: "中")
            ])
    ]

    /// 审查 3D 设计输入
    static func reviewDesign(_ d: DesignInput) -> DesignReviewResult {
        guard let detailId = matchDetail(d), let det = KnowledgeBank.findDetail(detailId) else {
            return DesignReviewResult(detailId: nil, detailName: nil, baseFat: nil,
                warnings: [DesignWarning(id: "M0", severity: "high", title: "无法映射细节",
                    finding: "无法由几何映射细节类别。",
                    suggestions: [ImprovementSuggestion(action: "请在界面确认接头类型/焊缝类型/荷载方向", raisesFatTo: nil, effort: "—")])])
        }
        let order = ["high": 0, "medium": 1, "low": 2]
        let warnings = rules.compactMap { r -> DesignWarning? in
            if r.condition(d) {
                return DesignWarning(id: r.id, severity: r.severity, title: r.title,
                                     finding: r.finding, suggestions: r.suggestions)
            }
            return nil
        }.sorted { (order[$0.severity] ?? 3) < (order[$1.severity] ?? 3) }
        return DesignReviewResult(detailId: detailId, detailName: det.name, baseFat: det.fat, warnings: warnings)
    }

    /// 生成按优先级排序的改型计划
    static func suggestImprovements(_ d: DesignInput, fatigueFail: Bool) -> [PlanItem] {
        var plan: [PlanItem] = []
        var seen = Set<String>()
        for w in reviewDesign(d).warnings {
            for s in w.suggestions {
                let key = "\(s.action)|\(s.raisesFatTo ?? -1)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                plan.append(PlanItem(priority: w.severity, ruleId: w.id, title: w.title,
                                     action: s.action, raisesFatTo: s.raisesFatTo, effort: s.effort))
            }
        }
        let order = ["high": 0, "medium": 1, "low": 2]
        plan.sort { (order[$0.priority] ?? 3) < (order[$1.priority] ?? 3) ||
                    (($0.priority == $1.priority) && ($0.ruleId < $1.ruleId)) }
        if fatigueFail && !plan.isEmpty {
            plan.insert(PlanItem(priority: "high", ruleId: "F0", title: "疲劳强度不足",
                action: "优先降低应力幅 Δσ 或提升 FAT(见下方改型)，使利用率≤1", raisesFatTo: nil, effort: "—"), at: 0)
        }
        return plan
    }

    /// 综合评估（3D 定 FAT + 照片定缺陷 + 用户荷载）
    static func assess(design: DesignInput, vision: VisionInput, params: UserParams,
                       mode: String) -> AssessmentResult {
        let dr: DesignReviewResult
        let detailId: String?
        if mode == "design" {
            dr = reviewDesign(design); detailId = dr.detailId
        } else if mode == "photo" {
            // 用照片识别的接头属性推导细节类别
            let vDesign = DesignInput(jointType: vision.jointType, weldType: vision.jointType == "butt" ? "butt" : "fillet",
                                      loadingDirection: vision.loadingDirection, loadCarrying: vision.loadCarrying,
                                      fullPenetration: false, groundFlush: false, attachmentLengthMm: nil,
                                      plateThicknessMm: params.thickness, copeHole: false, inTensionZone: false,
                                      stiffenerEnd: "square", coverTermination: "abrupt", misalignmentMm: 0,
                                      runoffTabs: false, highCycle: false, crossing: false, intermittent: false,
                                      weldContinuous: true, improvementsApplied: vision.improvementsApplied)
            let vid = matchDetail(vDesign)
            dr = DesignReviewResult(detailId: vid, detailName: vid.flatMap { KnowledgeBank.findDetail($0)?.name },
                                    baseFat: vid.flatMap { KnowledgeBank.findDetail($0)?.fat }, warnings: [])
            detailId = vid
        } else {
            dr = reviewDesign(design); detailId = dr.detailId ?? vision.detailCandidate
        }
        let fid = detailId ?? "W_TA_TRANS_71"
        // 先算 ISO 5817 缺陷判定，再回写 FAT（缺陷→FAT 定量回写）
        let imps = FatigueEngine.evaluateImperfections(params.thickness, params.qualityLevel, vision.imperfections,
                                                        weldWidthMm: params.weldWidthMm)
        let fc = FatigueEngine.constantAmplitudeCheck(fid, params.deltaSigma, params.nRequired,
                      improvements: vision.improvementsApplied, gammaMf: params.gammaMf,
                      defectInputs: vision.imperfections, defectResults: imps, thickness: params.thickness)

        var plan = (mode == "photo") ? [] : suggestImprovements(design, fatigueFail: !fc.pass)
        if !fc.pass {
            plan.append(PlanItem(priority: "high", ruleId: "F1", title: "疲劳强度不满足",
                action: "降低 Δσ / 增加板厚 / 焊趾打磨或 TIG/锤击提升 FAT，或优化细部设计", raisesFatTo: nil, effort: "—"))
        }
        for r in imps where r.fatigueRelevant && r.accepted == false {
            plan.append(PlanItem(priority: "medium", ruleId: "I1", title: "缺陷超差: \(r.label)",
                action: "「\(r.label)」超 \(params.qualityLevel) 级且位于焊趾，已折算降低有效 FAT，建议打磨改善疲劳", raisesFatTo: nil, effort: "低"))
        }
        var finalPlan: [PlanItem] = []
        var seen = Set<String>()
        for p in plan where !seen.contains(p.action) {
            seen.insert(p.action); finalPlan.append(p)
        }
        if finalPlan.isEmpty {
            finalPlan.append(PlanItem(priority: "ok", ruleId: "OK", title: "满足要求",
                action: "结构设计细节与表面质量在当前输入下满足疲劳要求。", raisesFatTo: nil, effort: "—"))
        }
        return AssessmentResult(design: dr, fatigue: fc, imperfections: imps, plan: finalPlan,
                                disclaimer: "辅助判定，非认证检测；结论须由持证人员复核。")
    }
}
