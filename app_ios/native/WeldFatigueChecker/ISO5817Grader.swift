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
        "crack": "crack"
    ]

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
    static func grade(type: String, sizeMm: Double, t: Double, b: Double? = nil) -> (level: String, accepted: Bool, limitText: String) {
        guard let d = doc else { return ("?", false, "标准数据缺失") }
        let key = aliases[type] ?? type
        guard let spec = d.imperfections.first(where: { $0.type == key }) else {
            return ("?", false, "未知缺陷类型: \(type)")
        }

        // 从最严 B 到最松 D 找第一个满足的尺寸等级
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
