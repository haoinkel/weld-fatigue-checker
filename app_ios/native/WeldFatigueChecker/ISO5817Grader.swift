// ISO5817Grader.swift
// 端侧自动评级：把「缺陷类型 + 实测尺寸(mm) + 板厚 t」映射到 ISO 5817:2023 质量等级 B/C/D，
// 并给出合格性判定。直接读取 App 包内 Resources/iso5817.json（v4 已含官方限值），零网络请求。
//
// 用法：
//   let g = ISO5817Grader.grade(type: "undercut", sizeMm: 0.8, t: 12)
//   // g.level = "C", g.accepted = true, g.limitText = "≤0.1t 且最大 1.0 mm"
// 裂纹(crack)各等级均不允许 → 返回 accepted=false。
//
// 说明：本评级为辅助性启发结论，最终验收须由持证人员按 ISO 5817 / EN 1993-1-9 结合无损检测确认。

import Foundation

// MARK: - JSON 结构（与 knowledge/iso5817.json(v4) 同源）

struct IsoLimitEntry: Codable {
    var permitted: Bool?
    var value: Double?
    var ref: String?        // "t" = 母材厚度比例；"b" = 焊缝宽度基准
    var max_abs: Double?
    var max_pore: Double?   // 气孔单孔直径上限
    var pore_rate: Double?  // 气孔截面累计气孔率上限（%，B≤2/C≤4/D≤8）
    var add: Double?
    var formula: String?
}
struct IsoImperfectionEntry: Codable {
    var type: String
    var label: String
    var fatigue_relevant: Bool?
    var limits: [String: IsoLimitEntry]
}
struct ISO5817Doc: Codable {
    var imperfections: [IsoImperfectionEntry]
}

enum ISO5817Grader {
    /// 包内标准文档（懒加载一次）
    static var doc: ISO5817Doc? = { load() }()

    // 缺陷类型别名：检测器输出名 → ISO 5817 标准 type
    private static let aliases: [String: String] = [
        "crater_crack": "crack",
        "crack": "crack",
        "unfused": "lack_of_fusion"   // ML 模型输出 unfused，标准库键为 lack_of_fusion
    ]

    /// NDT 免责声明（评级结果页/检测提示统一引用）：明确 App 定位为辅助筛查，不替代认证检测。
    /// 依据 Hyperion 2026 等研究结论：视觉模型不分配"认证质量等级"，安全关键接头仍须 UT/RT。
    static let ndtDisclaimer: String =
        "本结果为 AI 辅助目视(VT)筛查，非质量认证；安全关键焊缝须由持证人员按 ISO 17635 / ISO 5817 用 UT/RT 等补充检测确认。"

    // MARK: - 加载

    private static func load() -> ISO5817Doc? {
        guard let url = Bundle.main.url(forResource: "iso5817", withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ISO5817Doc.self, from: data)
    }

    // MARK: - 评级主入口

    /// 判定单个缺陷在给定板厚下的质量等级与合格性。
    /// - type: 缺陷类型（检测器输出，如 undercut / porosity / crack / excess_weld_metal ...）
    /// - sizeMm: 实测尺寸（气孔=单孔直径；咬边=深度 h；余高=高度 h）
    /// - t: 母材厚度 mm（ref=="t" 的比例基准）
    /// - b: 焊缝宽度基准 mm（ref=="b" 用，余高/凸度/熔透；缺省按 2t 近似）
    /// - returns: (level, accepted, limitText)
    static func grade(type: String, sizeMm: Double, t: Double, b: Double? = nil, level targetLevel: String? = nil) -> (level: String, accepted: Bool, limitText: String) {
        guard let d = doc else { return ("?", false, "标准数据缺失") }
        let key = aliases[type] ?? type
        guard let spec = d.imperfections.first(where: { $0.type == key }) else {
            return ("?", false, "未知缺陷类型: \(type)")
        }

        // 用户指定目标质量等级（设计图纸指定 B/C/D）：只按该等级限值判定合格性
        if let target = targetLevel {
            guard let lim = spec.limits[target] else {
                return ("?", false, "无等级 \(target) 定义")
            }
            if let permitted = lim.permitted, !permitted {
                // 该等级不允许此类缺陷（如 B 级不允许咬边/未熔合）→ 一票否决
                return ("✗", false, lim.formula ?? "\(target)级不允许")
            }
            if let upper = computeUpper(lim: lim, t: t, b: b), sizeMm <= upper {
                return (target, true, lim.formula ?? "合格")
            }
            return ("✗", false, lim.formula ?? "超差")
        }

        // 未指定目标等级：自动从最严 B 到最松 D 找第一个满足的尺寸等级（辅助筛查）
        for level in ["B", "C", "D"] {
            guard let lim = spec.limits[level] else { continue }
            if let permitted = lim.permitted, !permitted {
                continue // 该等级不允许（如裂纹、未熔合）→ 看更松等级
            }
            if let upper = computeUpper(lim: lim, t: t, b: b), sizeMm <= upper {
                return (level, true, lim.formula ?? "合格")
            }
        }

        // 所有等级都不满足 → 不合格，给出最松等级的公式说明
        let lastFormula = spec.limits["D"]?.formula
            ?? spec.limits["C"]?.formula
            ?? spec.limits["B"]?.formula
            ?? "超差"
        return ("✗", false, lastFormula)
    }

    // MARK: - 上限计算

    /// 气孔截面累计气孔率法（ISO 5817 表 2/3）：对一组气孔直径做「双判据」验收。
    /// ① 单孔最大直径 ≤ max_pore；② 累计气孔率 ≤ pore_rate%。
    /// 评定区：长度 l = max(12·t, 150 mm)，带宽 = 焊缝宽度 b（缺省 2t）；评定区面积 = l·b。
    /// 累计气孔率 = Σ(π/4·dᵢ²) / 评定区面积 × 100%。
    /// - diameters: 各气孔实测直径(mm)
    /// - level: 目标质量等级（B/C/D）；缺省 "C"
    /// - returns: (accepted, maxDiameter, singleOK, ratePct, rateLimit, limitText)
    static func gradePorosity(pores diameters: [Double], t: Double, b: Double? = nil, level: String? = nil)
        -> (accepted: Bool, maxDiameter: Double, singleOK: Bool, ratePct: Double?, rateLimit: Double?, limitText: String) {
        guard let d = doc else { return (false, 0, false, nil, nil, "标准数据缺失") }
        guard let spec = d.imperfections.first(where: { $0.type == "porosity" }) else {
            return (false, 0, false, nil, nil, "未知缺陷类型: porosity")
        }
        let lv = level ?? "C"
        guard let lim = spec.limits[lv] else { return (false, 0, false, nil, nil, "无等级 \(lv) 定义") }
        let maxD = diameters.max() ?? 0
        let singleOK: Bool = lim.max_pore.map { maxD <= $0 } ?? true
        let l = max(12.0 * t, 150.0)
        let stripW = b ?? (2.0 * t)
        let assessArea = l * stripW
        let totalPoreArea = diameters.reduce(0.0) { $0 + Double.pi / 4.0 * $1 * $1 }
        let ratePct: Double? = assessArea > 0 ? (totalPoreArea / assessArea * 100.0) : nil
        let rateLimit = lim.pore_rate
        let rateOK: Bool = (rateLimit != nil && ratePct != nil) ? (ratePct! <= rateLimit!) : true
        let accepted = singleOK && rateOK
        var parts: [String] = []
        parts.append(String(format: "单孔 d≤%.1fmm：实测最大 %.1fmm（%@）",
                            lim.max_pore ?? 0, maxD, singleOK ? "通过" : "超差"))
        if let rl = rateLimit, let rp = ratePct {
            parts.append(String(format: "累计气孔率≤%.0f%%：实测 %.1f%%（%@）",
                                rl, rp, rateOK ? "通过" : "超差"))
        } else if let rp = ratePct {
            parts.append(String(format: "累计气孔率=%.1f%%", rp))
        }
        return (accepted, maxD, singleOK, ratePct, rateLimit, parts.joined(separator: "；"))
    }

    /// 计算某等级验收上限（mm）。nil 表示该等级无法用尺寸判定（如仅有 permitted=false）。
    private static func computeUpper(lim: IsoLimitEntry, t: Double, b: Double?) -> Double? {
        // 气孔：单孔直径上限（max_pore），并取与比例上限的较小值
        if let mp = lim.max_pore {
            if let v = lim.value, let ref = lim.ref {
                let base: Double = (ref == "t") ? t : (b ?? 2.0 * t)
                return min(mp, v * base)
            }
            return mp
        }
        // 比例型（咬边/错边/未焊透等）：value*ref + add，受 max_abs 截断
        if let v = lim.value, let ref = lim.ref {
            let base: Double = (ref == "t") ? t : (b ?? 2.0 * t)
            var upper = v * base
            if let add = lim.add { upper += add }
            if let maxAbs = lim.max_abs { upper = min(upper, maxAbs) }
            return upper
        }
        // 仅绝对上限
        if let maxAbs = lim.max_abs { return maxAbs }
        return nil
    }
}
