// FatigueEngine.swift
// 疲劳校核引擎（移植自 engine/fatigue.py，纯 Swift，iPad 端侧运行）
// EN 1993-1-9:2005 + ISO 5817:2023

import Foundation

enum FatigueEngine {
    /// 考虑改善措施后的有效 FAT
    static func effectiveFat(_ detailId: String, improvements: [String]) -> (fat: Double, applied: [(String, Double, Double)]) {
        guard let d = KnowledgeBank.findDetail(detailId) else {
            fatalError("未知细节类别: \(detailId)")
        }
        var fatEff = Double(d.fat)
        var applied: [(String, Double, Double)] = []
        for imp in KnowledgeBank.improvements where improvements.contains(imp.method) {
            let capped = min(fatEff * imp.factor, Double(imp.maxFat))
            applied.append((imp.label, imp.factor, capped))
            fatEff = capped
        }
        return (fatEff, applied)
    }

    /// 等幅允许循环次数 N = refN * (FAT / (γMf·Δσ))^3
    static func allowableCycles(_ fat: Double, _ deltaSigma: Double, _ gammaMf: Double) -> Double {
        let deltaEff = gammaMf * deltaSigma
        guard deltaEff > 0 else { return .infinity }
        return KnowledgeBank.refN * pow(fat / deltaEff, 3)
    }

    /// 单一等幅应力幅疲劳验算
    static func constantAmplitudeCheck(_ detailId: String, _ deltaSigma: Double, _ nRequired: Double,
                                       improvements: [String] = [], gammaMf: Double = 1.0) -> FatigueResult {
        let (fatEff, applied) = effectiveFat(detailId, improvements: improvements)
        let nAllow = allowableCycles(fatEff, deltaSigma, gammaMf)
        let util = nAllow > 0 ? nRequired / nAllow : .infinity
        let d = KnowledgeBank.findDetail(detailId)!
        return FatigueResult(
            detailId: detailId, detailName: d.name, baseFat: d.fat,
            improvements: applied.map { ($0.0, $0.1, $0.2) },
            effectiveFat: fatEff, deltaSigma: deltaSigma, gammaMf: gammaMf,
            nAllowable: nAllow, nRequired: nRequired, utilization: util, pass: util <= 1.0)
    }

    /// 按 ISO 5817 验收表面缺陷
    static func evaluateImperfections(_ thickness: Double, _ level: String,
                                      _ items: [ImperfectionInput]) -> [ImperfectionResult] {
        items.map { imp in
            guard let spec = KnowledgeBank.isoImperfections.first(where: { $0.type == imp.type }) else {
                return ImperfectionResult(label: imp.type, accepted: nil, limit: "ISO5817 无此类型", fatigueRelevant: false)
            }
            let lim = spec.limits[level]
            var accepted: Bool? = nil
            var limitTxt = lim == nil ? "无该等级定义" : ""
            if let l = lim, let v = l.value, let size = imp.sizeMm {
                var thr = v * (l.ref == "t" ? thickness : 1.0)
                if let mx = l.maxAbs { thr = min(thr, mx) }
                accepted = size <= thr
                limitTxt = String(format: "阈值≈%.3fmm, 实测=%.3fmm", thr, size)
            } else if let l = lim, let mp = l.maxPore, let pore = imp.poreMm {
                accepted = pore <= mp
                limitTxt = String(format: "最大孔径=%.1fmm, 实测=%.1fmm", mp, pore)
            } else if lim != nil {
                limitTxt = "需按 ISO 5817:2023 原文判定(示例库未含量化限值)"
            }
            return ImperfectionResult(label: spec.label, accepted: accepted,
                                      limit: limitTxt, fatigueRelevant: spec.fatigueRelevant)
        }
    }
}
