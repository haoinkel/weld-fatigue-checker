// JointInference.swift
// 阶段2（M2a 规则引擎）：导入 STEP/OBJ 等 3D 模型后，基于网格顶点法线做方向聚类，
// 启发式推断接头类型 / 焊缝类型 / 荷载方向 / 是否传力，并预填设计表单（半自动，需用户确认）。
//
// 设计约束（见 AUTO_3D_REVIEW_PLAN.md §6）：
//   ✅ 本文件属于「识别/显示层」新增，不触碰 EN1993-1-9 评估内核（DesignReviewer / FatigueEngine）。
//   ✅ 纯 Swift 实现，不改动 occt_bridge（无需 Mac 端重编译 OCCT，CI 验证成本最低）。
//   ⚠️ 全熔透：坡口特征常不在 STEP 中建模，几何无法判定 → fullPenetration 恒为 nil（待确认），绝不臆测，
//      避免错误判定引发工程误判（规划文档 §5 风险3）。
//   ⚠️ 本推断为「弱启发式 + 低置信度」，定位是「减少手填负担的起点」，最终以用户确认值为准。
//      更高准确率需 M1（OCCT 深度几何原语：平行面对 / 交线 / 夹角）支撑，列为后续增强。

import Foundation
import SceneKit

/// 接头几何推断假设（阶段2 输出契约，对应规划文档 M2 的 JointHypothesis）
struct JointHypothesis: Equatable {
    let jointType: String          // butt | fillet | t_joint | cruciform | corner | lap
    let weldType: String           // butt | fillet
    let loadingDirection: String   // transverse | longitudinal
    let loadCarrying: Bool
    let fullPenetration: Bool?     // nil = 几何无法判定，标记「待确认」
    let confidence: Double         // 0..1
    let rationale: String          // 几何证据说明（用户可读）

    /// 供表单横幅展示的简短摘要
    func summaryForUI() -> String {
        let jt = Self.jointTypeLabel(jointType)
        let wt = (weldType == "butt") ? "对接焊缝" : "角焊缝"
        let ld = (loadingDirection == "transverse") ? "横向" : "纵向"
        let lc = loadCarrying ? "是" : "否"
        let fp = (fullPenetration == nil) ? "待确认" : (fullPenetration! ? "是" : "否")
        return "接头类型=\(jt) · 焊缝=\(wt) · 荷载方向=\(ld) · 荷载传递=\(lc) · 全熔透=\(fp)"
    }

    /// 置信度中文档位
    var confidenceLabel: String {
        if confidence < 0.35 { return "低" }
        if confidence < 0.6  { return "中低" }
        return "中"
    }

    static func jointTypeLabel(_ t: String) -> String {
        switch t {
        case "cruciform": return "十字接头"
        case "t_joint":   return "T型接头"
        case "butt":      return "对接"
        case "fillet":    return "角接"
        case "lap":       return "搭接"
        case "corner":    return "角接(edge)"
        default:          return t
        }
    }
}

struct JointInference {

    /// 从已加载的 SCNNode（可能是层级）推断接头假设。
    /// - Parameters:
    ///   - root: 模型根节点（已加入场景或仅本地持有均可）
    ///   - solidCount: 可选，来自 OCCT 拓扑的实体数（assembly 提示），用于微调置信度
    static func inferJoint(from root: SCNNode, solidCount: Int? = nil) -> JointHypothesis {
        let normals = collectNormals(from: root)

        guard !normals.isEmpty else {
            return JointHypothesis(
                jointType: "cruciform", weldType: "fillet", loadingDirection: "transverse",
                loadCarrying: true, fullPenetration: nil, confidence: 0.2,
                rationale: "未提取到网格法线，无法几何推断，已给出保守默认（十字/传力），请人工确认。")
        }

        // 1) 法线方向聚类：把相近（|dot|>0.9）的法线归入同一板面组
        var clusters: [(axis: simd_float3, count: Int)] = []
        for n in normals {
            let len = simd_length(n)
            guard len > 1e-6 else { continue }
            let u = n / len
            var matched = false
            for i in clusters.indices {
                if abs(simd_dot(u, clusters[i].axis)) > 0.9 {
                    clusters[i].count += 1
                    matched = true
                    break
                }
            }
            if !matched { clusters.append((axis: u, count: 1)) }
        }

        let total = max(clusters.reduce(0) { $0 + $1.count }, 1)
        // 仅保留占比 > 8% 的显著板面组；其余视为噪声/倒角
        let sig = clusters.filter { Float($0.count) / Float(total) > 0.08 }
                          .sorted { $0.count > $1.count }

        // 2) 依据显著板面组数 + 正交关系做启发式判定
        let nGroups = sig.count

        if nGroups <= 1 {
            // 单一板面主导 → 推断为对接（单板对接，传力）
            let conf = (solidCount == 1) ? 0.5 : 0.45
            return JointHypothesis(
                jointType: "butt", weldType: "butt", loadingDirection: "transverse",
                loadCarrying: true, fullPenetration: nil, confidence: conf,
                rationale: "几何以单一板面为主（法线聚类仅 1 组显著）→ 推断为对接接头（单板对接）。")
        }

        if nGroups == 2 {
            // 两组板面：看是否正交（|dot| 小）判断「相交接头」
            let a = simd_normalize(sig[0].axis)
            let b = simd_normalize(sig[1].axis)
            let absDot = abs(simd_dot(a, b))
            if absDot < 0.5 {
                // 近似正交 → 两板相交：按组规模比判断十字 vs T/角接
                let bigger = max(sig[0].count, sig[1].count)
                let smaller = min(sig[0].count, sig[1].count)
                let ratio = Double(smaller) / Double(max(bigger, 1))
                var (jt, conf): (String, Double)
                if ratio > 0.5 {
                    jt = "cruciform"   // 两板规模相当 → 十字接头
                    conf = 0.55
                } else {
                    jt = "t_joint"     // 一块小附件搭另一大板 → T 型/角接类
                    conf = 0.5
                }
                return JointHypothesis(
                    jointType: jt, weldType: "fillet", loadingDirection: "transverse",
                    loadCarrying: true, fullPenetration: nil, confidence: conf,
                    rationale: "检测到 2 组近似正交板面（相交接头）；按规模比 \(String(format:"%.2f", ratio)) 推断为 \(JointHypothesis.jointTypeLabel(jt))。荷载方向默认横向（最不利，请按实际传力确认）。")
            } else {
                // 两组近似平行（同一轴正负）→ 可能为搭接（两板平行错位）
                return JointHypothesis(
                    jointType: "lap", weldType: "fillet", loadingDirection: "longitudinal",
                    loadCarrying: false, fullPenetration: nil, confidence: 0.4,
                    rationale: "检测到 2 组近似平行板面（同一轴正负）→ 推断为搭接接头。")
            }
        }

        // nGroups >= 3：多板面复杂接头，保守归为十字/角接类
        return JointHypothesis(
            jointType: "cruciform", weldType: "fillet", loadingDirection: "transverse",
            loadCarrying: true, fullPenetration: nil, confidence: 0.3,
            rationale: "检测到多组板面（≥3 组显著）→ 推断为交叉/角接类复杂接头，请人工确认具体形式。")
    }

    // MARK: - 几何法线收集（安全读取，避免指针越界崩溃）

    /// 递归遍历节点树，收集所有几何的顶点法线（世界坐标，已归一化）。
    /// 优先用几何自带 normal 源；缺失时退回由三角形面法线估算。
    private static func collectNormals(from root: SCNNode) -> [simd_float3] {
        var out: [simd_float3] = []
        func walk(_ node: SCNNode) {
            if let geo = node.geometry {
                let tf = node.simdWorldTransform
                let normalSrc = geo.sources(for: .normal).first
                if let ns = normalSrc, ns.vectorCount > 0 {
                    appendNormals(from: ns, transform: tf, into: &out)
                } else if let vsrc = geo.sources(for: .vertex).first,
                          let elem = geo.elements.first,
                          elem.primitiveType == .triangles {
                    appendFaceNormals(geometry: geo, vertexSource: vsrc, element: elem,
                                      transform: tf, into: &out)
                }
            }
            for c in node.childNodes { walk(c) }
        }
        walk(root)
        return out
    }

    /// 从 normal 源按 float3 读取并变换到世界空间
    private static func appendNormals(from src: SCNGeometrySource, transform tf: simd_float4x4,
                                      into out: inout [simd_float3]) {
        guard let data = src.data else { return }
        let stride = src.dataStride > 0 ? src.dataStride : MemoryLayout<Float>.stride * 3
        let offset = src.dataOffset
        let count = src.vectorCount
        for i in 0..<count {
            let start = offset + i * stride
            guard start + 12 <= data.count else { continue }
            let x = data.subdata(in: start..<start+4).withUnsafeBytes { $0.load(as: Float.self) }
            let y = data.subdata(in: start+4..<start+8).withUnsafeBytes { $0.load(as: Float.self) }
            let z = data.subdata(in: start+8..<start+12).withUnsafeBytes { $0.load(as: Float.self) }
            let w = (tf * simd_float4(x, y, z, 0)).xyz
            let len = simd_length(w)
            if len > 1e-6 { out.append(w / len) }
        }
    }

    /// 退化情况：无 normal 源时，从三角形索引估算面法线并变换
    private static func appendFaceNormals(geometry geo: SCNGeometry,
                                          vertexSource vsrc: SCNGeometrySource,
                                          element elem: SCNGeometryElement,
                                          transform tf: simd_float4x4,
                                          into out: inout [simd_float3]) {
        guard let vdata = vsrc.data, let idata = elem.data else { return }
        let vstride = vsrc.dataStride > 0 ? vsrc.dataStride : MemoryLayout<Float>.stride * 3
        let voffset = vsrc.dataOffset
        let vcount = vsrc.vectorCount
        let primCount = elem.primitiveCount
        let bpi = elem.bytesPerIndex
        func vertex(_ idx: Int) -> simd_float3? {
            guard idx >= 0, idx < vcount else { return nil }
            let s = voffset + idx * vstride
            guard s + 12 <= vdata.count else { return nil }
            let x = vdata.subdata(in: s..<s+4).withUnsafeBytes { $0.load(as: Float.self) }
            let y = vdata.subdata(in: s+4..<s+8).withUnsafeBytes { $0.load(as: Float.self) }
            let z = vdata.subdata(in: s+8..<s+12).withUnsafeBytes { $0.load(as: Float.self) }
            return (tf * simd_float4(x, y, z, 1)).xyz
        }
        for t in 0..<primCount {
            let base = t * 3 * bpi
            guard base + 3 * bpi <= idata.count else { continue }
            let i0 = Int(idata.subdata(in: base..<base+bpi).withUnsafeBytes { $0.load(as: Int32.self) })
            let i1 = Int(idata.subdata(in: base+bpi..<base+2*bpi).withUnsafeBytes { $0.load(as: Int32.self) })
            let i2 = Int(idata.subdata(in: base+2*bpi..<base+3*bpi).withUnsafeBytes { $0.load(as: Int32.self) })
            guard let p0 = vertex(i0), let p1 = vertex(i1), let p2 = vertex(i2) else { continue }
            let n = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(n)
            if len > 1e-6 { out.append(n / len) }
        }
    }
}
