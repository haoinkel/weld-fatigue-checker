// FatigueEngine.swift
// 疲劳校核引擎（移植自 engine/fatigue.py，纯 Swift，iPad 端侧运行）
// EN 1993-1-9:2005 + ISO 5817:2023

import Foundation

enum FatigueEngine {
    /// 考虑改善措施后的有效 FAT
    static func effectiveFat(_ detailId: String, improvements: [String]) -> (fat: Double, applied: [(String, Double, Double)]) {
        // 安全兜底：未知细节 ID（如标准包数据变更）不再 fatalError，回退 FAT 80
        guard let d = KnowledgeBank.findDetail(detailId) ?? KnowledgeBank.details.first else {
            return (80, [])
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
    /// - defectInputs/defectResults: 与 imps 同序的 ISO5817 缺陷输入与判定结果；
    ///   用于「缺陷→FAT 定量回写」，把超差且疲劳相关的缺陷折算进有效 FAT。
    static func constantAmplitudeCheck(_ detailId: String, _ deltaSigma: Double, _ nRequired: Double,
                                       improvements: [String] = [], gammaMf: Double = 1.0,
                                       defectInputs: [ImperfectionInput] = [],
                                       defectResults: [ImperfectionResult] = [],
                                       thickness: Double = 12) -> FatigueResult {
        let (fatEff, applied) = effectiveFat(detailId, improvements: improvements)
        // 缺陷→FAT 定量回写：在改善后 FAT 基础上再折减
        let (penFat, penNotes, forcedFail) = defectFatPenalty(
            baseFat: fatEff, inputs: defectInputs, results: defectResults, thickness: thickness)
        let nAllow = allowableCycles(penFat, deltaSigma, gammaMf)
        let util = nAllow > 0 ? nRequired / nAllow : .infinity
        // 安全兜底：未知细节 ID 不强解包（避免闪退）
        let d = KnowledgeBank.findDetail(detailId)
            ?? DetailCategory(id: detailId, fat: Int(penFat), name: detailId)
        return FatigueResult(
            detailId: detailId, detailName: d.name, baseFat: d.fat,
            improvements: applied.map { ($0.0, $0.1, $0.2) },
            effectiveFat: penFat, deltaSigma: deltaSigma, gammaMf: gammaMf,
            nAllowable: nAllow, nRequired: nRequired, utilization: util,
            pass: forcedFail ? false : (util <= 1.0),
            fatPenalties: penNotes, defectForcedFail: forcedFail)
    }

    /// EN 1993-1-9 FAT 阶梯（降序）；用于几何缺陷「降一级」折减。
    private static let fatLadder = [160, 140, 125, 112, 100, 90, 80, 71, 63, 56, 50,
                                    45, 40, 36, 35, 31, 25, 22, 16, 12]

    /// 缺陷→FAT 定量回写（核心）
    /// - 裂纹/未熔合/未焊透/不允许级缺陷(notPermitted)：有效 FAT 直接判废，疲劳不满足（一票否决）。
    /// - 其余几何缺陷（咬边/余高过大/焊瘤/错边/根部咬边）：有效 FAT 降一级（取阶梯上一档更低值）；
    ///   多个几何缺陷逐项叠加降级，下限 12。
    ///
    /// 说明：这是 EN 1993-1-9 + IIW 实务中「制造缺陷超差则 FAT 降级」的保守简化实现；
    /// 错边也可按偏心系数 K_m=1+3e/(2t) 折减，此处统一为降级一级以便与离散 FAT 模型一致。
    static func defectFatPenalty(baseFat: Double, inputs: [ImperfectionInput],
                                 results: [ImperfectionResult], thickness: Double)
        -> (effectiveFat: Double, notes: [String], forcedFail: Bool) {
        var fat = max(baseFat, Double(fatLadder.last ?? 12))
        var notes: [String] = []
        var forcedFail = false
        for (_, res) in zip(inputs, results) {
            guard res.fatigueRelevant, let acc = res.accepted, !acc else { continue }
            if res.notPermitted {
                forcedFail = true
                notes.append("\(res.label)：该质量等级不允许(一票否决)，有效 FAT 判废，疲劳不满足。")
                continue
            }
            // 几何缺陷降一级
            if let lower = fatLadder.first(where: { Double($0) < fat }) {
                let from = Int(round(fat))
                fat = Double(lower)
                notes.append("\(res.label)超差：有效 FAT \(from) → \(lower)（几何缺陷降一级）。")
            } else {
                notes.append("\(res.label)超差：有效 FAT 已为最低档 \(Int(fat))，无法再降。")
            }
        }
        return (fat, notes, forcedFail)
    }

    /// 按 ISO 5817 验收表面缺陷
    /// - weldWidthMm: 余高/凸度计算基准宽度 b（ref=="b" 时使用）；缺省按 2t 近似。
    ///   同时也是气孔「截面累计气孔率法」的评定区带宽（与余高同基准）。
    static func evaluateImperfections(_ thickness: Double, _ level: String,
                                      _ items: [ImperfectionInput],
                                      weldWidthMm: Double? = nil) -> [ImperfectionResult] {
        let b = weldWidthMm ?? (2.0 * thickness)   // 余高/凸度/评定区带宽缺省按 2t
        // 检测器输出名 → 标准库 type（模型输出 unfused，标准库键为 lack_of_fusion）
        let alias: [String: String] = [
            "unfused": "lack_of_fusion", "crater_crack": "crack",
            "pore": "porosity", "air-hole": "porosity"
        ]
        // —— 气孔截面累计气孔率法（ISO 5817 表 2/3）预聚合 ——
        let poreSpec = KnowledgeBank.isoImperfections.first(where: { $0.type == "porosity" })
        let poreLimit = poreSpec?.limits[level]
        let poreMax = poreLimit?.maxPore
        let poreRateLimit = poreLimit?.poreRate
        let poreDiameters: [Double] = items.compactMap { imp in
            guard (alias[imp.type] ?? imp.type) == "porosity" else { return nil }
            return imp.poreMm ?? imp.sizeMm
        }
        let assessLen = max(12.0 * thickness, 150.0)          // 评定长度 l = max(12t,150)
        let assessArea = assessLen * b                          // 评定区面积 = l × 带宽 b
        let totalPoreArea = poreDiameters.reduce(0.0) { $0 + Double.pi / 4.0 * $1 * $1 }
        let poreRatePct: Double? = (poreRateLimit != nil && assessArea > 0)
            ? (totalPoreArea / assessArea * 100.0) : nil

        return items.map { imp in
            let key = alias[imp.type] ?? imp.type
            guard let spec = KnowledgeBank.isoImperfections.first(where: { $0.type == key }) else {
                return ImperfectionResult(label: imp.type, accepted: nil, limit: "ISO5817 无此类型",
                                          fatigueRelevant: false, notPermitted: false)
            }
            guard let lim = spec.limits[level] else {
                return ImperfectionResult(label: spec.label, accepted: nil, limit: "无该等级定义",
                                          fatigueRelevant: spec.fatigueRelevant, notPermitted: false)
            }
            // 一票否决：该等级不允许（裂纹/未熔合/焊瘤 B,C/根部咬边 B…）→ 直接 ✗
            if let permitted = lim.permitted, !permitted {
                return ImperfectionResult(label: spec.label, accepted: false,
                                          limit: lim.formula ?? "不允许", fatigueRelevant: spec.fatigueRelevant,
                                          notPermitted: true)
            }
            // 气孔：单孔直径 + 截面累计气孔率 双判据
            if key == "porosity" {
                let d = imp.poreMm ?? imp.sizeMm
                var parts: [String] = []
                var ok = true
                if let mp = poreMax, let dd = d {
                    let single = dd <= mp
                    ok = ok && single
                    parts.append(String(format: "单孔 d=%.1fmm(限≤%.1f)", dd, mp))
                } else if let dd = d {
                    parts.append(String(format: "单孔 d=%.1fmm", dd))
                }
                if let rl = poreRateLimit, let rp = poreRatePct {
                    let rateOK = rp <= rl
                    ok = ok && rateOK
                    parts.append(String(format: "累计气孔率=%.1f%%(限≤%.0f%%)", rp, rl))
                } else if let rp = poreRatePct {
                    parts.append(String(format: "累计气孔率=%.1f%%", rp))
                }
                let acc: Bool? = (poreMax == nil && poreRateLimit == nil) ? nil : ok
                return ImperfectionResult(label: spec.label, accepted: acc,
                    limit: parts.isEmpty ? "无量化限值" : parts.joined(separator: "；"),
                    fatigueRelevant: spec.fatigueRelevant, notPermitted: false)
            }
            // 比例/绝对型（ref t 或 b，可带 add，受 maxAbs 截断）
            let size = imp.sizeMm
            if let v = lim.value, let ref = lim.ref {
                let base: Double = (ref == "t") ? thickness : b
                var thr = v * base
                if let add = lim.add { thr += add }
                if let mx = lim.maxAbs { thr = min(thr, mx) }
                if let s = size {
                    let accepted = s <= thr
                    return ImperfectionResult(label: spec.label, accepted: accepted,
                        limit: String(format: "阈值≈%.3fmm, 实测=%.3fmm", thr, s),
                        fatigueRelevant: spec.fatigueRelevant, notPermitted: false)
                }
                return ImperfectionResult(label: spec.label, accepted: nil,
                    limit: String(format: "阈值≈%.3fmm, 需实测尺寸", thr),
                    fatigueRelevant: spec.fatigueRelevant, notPermitted: false)
            }
            // 仅绝对上限
            if let mx = lim.maxAbs, let s = size {
                let accepted = s <= mx
                return ImperfectionResult(label: spec.label, accepted: accepted,
                    limit: String(format: "上限=%.1fmm, 实测=%.1fmm", mx, s),
                    fatigueRelevant: spec.fatigueRelevant, notPermitted: false)
            }
            return ImperfectionResult(label: spec.label, accepted: nil,
                limit: "需按 ISO 5817:2023 原文判定", fatigueRelevant: spec.fatigueRelevant,
                notPermitted: false)
        }
    }
}
