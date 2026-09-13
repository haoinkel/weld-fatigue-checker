// WeldProfileAnalyzer.swift
// 焊缝深度剖面分析（纯 Swift，可单元测试，不依赖 ARKit）
//
// 输入：沿焊缝横截面采样得到的一维深度数组（单位 mm，来自 LiDAR 深度图）。
//   约定：数值为相机到表面的距离；距离越小＝表面越凸出（焊缝余高），距离越大＝表面越凹（咬边）。
// 输出：识别到的焊缝相关几何候选（余高、咬边、错边），带实测 mm 与置信度。
//
// 说明：这是辅助性几何启发式，用于把 LiDAR 点云快速转成可复核的缺陷候选；
//       最终判定须由持证人员按 ISO 5817 / EN 1993-1-9 结合无损检测确认。

import Foundation

/// 焊缝走向（决定 LiDAR 取哪条横截面采样线）
enum WeldOrientation: String, CaseIterable {
    case auto = "auto"
    case horizontal = "horizontal"   // 焊缝横向（左右走向）
    case vertical = "vertical"       // 焊缝纵向（上下走向）
    var label: String {
        switch self {
        case .auto: return "自动"
        case .horizontal: return "横向"
        case .vertical: return "纵向"
        }
    }
}

struct WeldCandidate {
    let type: String        // excess_weld_metal | undercut | linear_misalignment
    let label: String
    let sizeMm: Double
    let confidence: Double  // 0..1
    let note: String
}

enum WeldProfileAnalyzer {
    /// 阈值（mm）：超过才记为缺陷候选，避免噪声误报
    private static let excessThresh: Float = 1.5
    private static let undercutThresh: Float = 0.5
    private static let misalignThresh: Float = 1.0

    /// 分析横截面深度剖面，返回缺陷候选（可能为空）。
    /// 剖面为沿焊缝横截面采样的一维距离数组（mm）。本算法与焊缝朝向无关：
    /// 先定位余高峰（最小距离＝最凸出），再以峰为界把剖面分成焊趾两侧，
    /// 两侧各自找最凹处即为咬边。横/纵向焊缝的剖面只是同一逻辑的不同 1D 序列。
    static func analyze(_ raw: [Float]) -> [WeldCandidate] {
        guard raw.count > 20 else { return [] }
        let s = movingAverage(raw, window: 3)          // 轻度平滑抑制噪声
        let baseline = median(s)                        // 母材表面基线距离
        guard baseline > 0, baseline.isFinite else { return [] }

        var cands: [WeldCandidate] = []

        // 1) 焊缝余高：剖面最小距离（最凸出处）相对基线的差值
        guard let peak = s.min() else { return [] }
        let excess = baseline - peak
        if excess > excessThresh {
            cands.append(WeldCandidate(
                type: "excess_weld_metal",
                label: "余高过大(实测)",
                sizeMm: Double(excess),
                confidence: min(0.9, 0.5 + Double(excess) / 10.0),
                note: "LiDAR 剖面测得焊缝凸出母材约 \(String(format: "%.1f", excess)) mm"))
        }

        // 2) 焊趾咬边：以余高峰为界，左右两侧各自取最凹处（最大距离）相对基线的差值
        let crest = s.firstIndex(of: peak) ?? (s.count / 2)
        let left = Array(s[0..<crest])
        let right = Array(s[crest..<s.count])
        for (seg, side) in [(left, "左"), (right, "右")] {
            guard let localMax = seg.max(), (localMax - baseline) > undercutThresh else { continue }
            let depth = localMax - baseline
            cands.append(WeldCandidate(
                type: "undercut",
                label: "咬边(实测·\(side)侧)",
                sizeMm: Double(depth),
                confidence: min(0.85, 0.5 + Double(depth) / 5.0),
                note: "LiDAR 测得\(side)侧焊趾下凹约 \(String(format: "%.1f", depth)) mm"))
        }

        // 3) 错边：余高峰左右两侧基线的差值
        let leftBase = median(left)
        let rightBase = median(right)
        let mis = abs(leftBase - rightBase)
        if mis > misalignThresh {
            cands.append(WeldCandidate(
                type: "linear_misalignment",
                label: "错边(实测)",
                sizeMm: Double(mis),
                confidence: min(0.8, 0.5 + Double(mis) / 10.0),
                note: "LiDAR 测得左右板面错位约 \(String(format: "%.1f", mis)) mm"))
        }

        return cands
    }

    // MARK: - 工具

    private static func movingAverage(_ a: [Float], window w: Int) -> [Float] {
        guard w > 1, a.count > w else { return a }
        var out = [Float](repeating: 0, count: a.count)
        let r = w / 2
        for i in 0..<a.count {
            let lo = max(0, i - r), hi = min(a.count - 1, i + r)
            var sum: Float = 0
            for j in lo...hi { sum += a[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }

    private static func median(_ a: [Float]) -> Float {
        guard !a.isEmpty else { return 0 }
        let sorted = a.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
