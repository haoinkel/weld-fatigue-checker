// WeldSpecCalculator.swift
// 焊接工艺参数推荐（WeldersHub「焊规计算器」思路的本地化实现）
// 依据：工艺 / 材质 / 板厚 / 接头形式 / 焊接位置 → 推荐电流、电压、焊速、送丝速度、预热温度。
// ⚠️ 输出为经验参考区间（简化 AWS/EN WPS 规律），非经评定的正式焊接工艺规程（pWPS/WPS），
//    现场必须以经评定批准的 WPS 为准。

import Foundation

struct WeldSpecResult {
    let process: String
    let material: String
    let joint: String
    let position: String
    let thickness: Double
    let currentRange: ClosedRange<Double>?      // A
    let voltageRange: ClosedRange<Double>?      // V
    let travelSpeed: ClosedRange<Double>        // cm/min
    let wireFeed: ClosedRange<Double>?          // m/min（焊条/实心丝自动，TIG 无）
    let preheat: Double                         // ℃
    let notes: [String]
}

enum WeldSpecCalculator {

    // 可选项
    static let processes = ["GMAW", "FCAW", "SMAW", "GTAW"]      // 熔化极气保 / 药芯 / 手工电弧 / 钨极氩弧
    static let materials = ["碳钢", "低合金钢", "不锈钢"]
    static let joints    = ["对接", "角接"]
    static let positions = ["PA 平焊", "PC 横焊", "PF 立向上", "PG 立向下", "PE 仰焊"]

    /// 推荐焊接工艺参数
    static func recommend(process: String, material: String, thickness t: Double,
                           joint: String, position: String) -> WeldSpecResult {
        // 1) 基准电流（按板厚分档，碳钢 GMAW 1.2mm 丝经验值）
        let base: ClosedRange<Double> = {
            switch t {
            case ..<3:   return 70...110
            case ..<6:   return 110...180
            case ..<12:  return 180...260
            case ..<20:  return 260...340
            default:     return 340...420
            }
        }()
        // 2) 工艺系数
        var curLo = base.lowerBound, curHi = base.upperBound
        if process == "GTAW" { curLo *= 0.55; curHi *= 0.55 }          // TIG 电流较低
        if process == "SMAW" { curLo *= 0.9;  curHi *= 0.9 }            // 手弧焊略低
        // 3) 位置系数（仰/立降电流，减少下淌）
        let posFactor: Double = {
            if position.hasPrefix("PE") { return 0.85 }               // 仰焊
            if position.hasPrefix("PF") || position.hasPrefix("PG") { return 0.90 } // 立焊
            if position.hasPrefix("PC") { return 0.95 }               // 横焊
            return 1.0                                                 // 平焊
        }()
        curLo *= posFactor; curHi *= posFactor
        let currentRange: ClosedRange<Double> = curLo...curHi

        // 4) 电压（GMAW/FCAW 随电流升；SMAW 约 22-26；GTAW 约 10-15）
        let voltageRange: ClosedRange<Double>? = {
            switch process {
            case "GMAW", "FCAW": return (16 + t * 0.6)...(22 + t * 0.6)
            case "SMAW":         return 21...27
            case "GTAW":         return 10...15
            default:             return nil
            }
        }()

        // 5) 焊速（cm/min）：薄板略快，角接略慢
        let travelLo = joint == "角接" ? 25.0 : 32.0
        let travelHi = joint == "角接" ? 45.0 : 58.0
        let travelSpeed: ClosedRange<Double> = travelLo...travelHi

        // 6) 送丝速度（m/min，仅自动/半自动熔化极）：≈ 电流 / 9（1.2mm 实芯丝经验）
        let wireFeed: ClosedRange<Double>? = (process == "GMAW" || process == "FCAW")
            ? (curLo / 9)...(curHi / 9) : nil

        // 7) 预热温度（℃）
        var preheat: Double = 5   // 室温下限
        if material == "低合金钢" { preheat = t > 25 ? 120 : 80 }
        else if material == "不锈钢" { preheat = 5 }   // 一般不预热，控层温≤150
        else { preheat = t > 35 ? 100 : 5 }            // 碳钢厚板适当预热

        // 8) 备注
        var notes: [String] = []
        notes.append("输出为经验参考区间，非评定 WPS；现场须以批准的焊接工艺规程为准。")
        if material == "不锈钢" { notes.append("不锈钢：控制层间温度≤150℃，避免碳化物析出。") }
        if material == "低合金钢" { notes.append("低合金钢：注意预热与缓冷，防止冷裂纹。") }
        if position.hasPrefix("PE") || position.hasPrefix("PF") || position.hasPrefix("PG") {
            notes.append("立/仰位置：建议小参数、窄焊道、多层多道。")
        }
        if process == "GTAW" { notes.append("TIG：通常用于打底（根焊），双面成型或加衬垫。") }

        return WeldSpecResult(process: process, material: material, joint: joint,
                              position: position, thickness: t, currentRange: currentRange,
                              voltageRange: voltageRange, travelSpeed: travelSpeed,
                              wireFeed: wireFeed, preheat: preheat, notes: notes)
    }
}
