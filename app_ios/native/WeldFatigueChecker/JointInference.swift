// JointInference.swift
// 阶段2（M2a 规则引擎）：导入 STEP/OBJ 等 3D 模型后，基于网格顶点法线做方向聚类，
// 启发式推断接头类型 / 焊缝类型 / 荷载方向 / 是否传力，并预填设计表单（半自动，需用户确认）。
//
// 设计约束（见 AUTO_3D_REVIEW_PLAN.md §6）：
//   ✅ 本文件属于「识别/显示层」，不触碰 EN1993-1-9 评估内核（DesignReviewer / FatigueEngine）。
//   ✅ 阶段2 为纯 Swift mesh 法线启发式；M1 已接入 OCCT 几何原语（板面组数/二面角/板厚）做融合校正，
//      仅增强识别层，未改动 occt_bridge 的 STEP 导入/三角化逻辑。
//   ⚠️ 全熔透：坡口特征常不在 STEP 中建模，几何无法判定 → fullPenetration 恒为 nil（待确认），绝不臆测，
//      避免错误判定引发工程误判（规划文档 §5 风险3）。
//   ⚠️ 本推断为「启发式 + 中低置信度」，定位是「减少手填负担的起点」，最终以用户确认值为准。

import Foundation
import SceneKit

/// M3（阶段3）焊缝位置提取基础：板面法线聚类出的「板面组」（质心 + 平均法线 + 顶点数）。
/// 焊缝候选 = 相邻板面组的质心中点（由 Model3DView 计算）。纯 Swift，不依赖 OCCT。
struct PlateGroup {
    let centroid: simd_float3   // 板面组质心（模型本地坐标）
    let normal: simd_float3     // 板面平均法线方向（单位向量）
    let count: Int              // 该组顶点数（用于规模比）
}

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
    /// 从已加载的 SCNNode（可能是层级）推断接头假设。
    /// - Parameters:
    ///   - root: 模型根节点（已加入场景或仅本地持有均可）
    ///   - occt: 可选，来自 OCCT B-rep 的几何原语（板面组数/二面角/板厚等）；
    ///           可用时作为权威几何源，校正网格法线启发式的接头类型与置信度。
    static func inferJoint(from root: SCNNode, occt: OCCTGeomPrimitives? = nil) -> JointHypothesis {
        let normals = collectNormals(from: root)

        // 退化分支：无网格法线但有 OCCT 原语，则仅依据 OCCT 原语推断
        guard !normals.isEmpty else {
            if let o = occt, o.available { return hypothesisFromOCCT(o) }
            return JointHypothesis(
                jointType: "cruciform", weldType: "fillet", loadingDirection: "transverse",
                loadCarrying: true, fullPenetration: nil, confidence: 0.2,
                rationale: "未提取到网格法线且 OCCT 原语不可用，已给保守默认（十字/传力），请人工确认。")
        }

        // 1) mesh 法线聚类（阶段2 逻辑，作为规模比参考）
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
        let sig = clusters.filter { Float($0.count) / Float(total) > 0.08 }
                          .sorted { $0.count > $1.count }

        // 2) OCCT 校正源（若可用，作为权威几何信息）
        let occtOK = (occt?.available == true)
        let plateGroups = occtOK ? max(occt!.plateGroupCount, 1) : sig.count
        let dihedral = occtOK ? occt!.dihedralAngle : nil      // 度
        let ortho = dihedral.map { $0 > 70 }                   // 近似正交
        let parallel = dihedral.map { $0 < 30 }                // 近似平行

        // 3) 主判定：优先 OCCT 的板面组数 + 二面角；规模比沿用 mesh sig
        var jt: String
        var conf: Double
        var base: String

        if plateGroups <= 1 {
            jt = "butt"; conf = 0.5; base = "单一板面主导"
        } else if plateGroups == 2 {
            if let parallel = parallel, parallel {
                jt = "lap"; conf = 0.5; base = "两组近似平行板面（OCCT 二面角≈\(Int(dihedral!))°）"
            } else if let ortho = ortho, ortho {
                // 需规模比判 cruciform/t_joint；mesh sig 不足 2 组时默认十字（保守，最常见）
                if sig.count >= 2 {
                    let bigger = max(sig[0].count, sig[1].count)
                    let smaller = min(sig[0].count, sig[1].count)
                    let ratio = Double(smaller) / Double(max(bigger, 1))
                    jt = ratio > 0.5 ? "cruciform" : "t_joint"
                } else {
                    jt = "cruciform"
                }
                conf = 0.6
                base = "两组近似正交板面（OCCT 二面角≈\(Int(dihedral!))°）"
            } else {
                // 二面角介于 30~70：回退 mesh 判定（同样守护 sig.count，避免越界）
                if sig.count >= 2 {
                    let a = simd_normalize(sig[0].axis)
                    let b = simd_normalize(sig[1].axis)
                    if abs(simd_dot(a, b)) < 0.5 {
                        let bigger = max(sig[0].count, sig[1].count)
                        let smaller = min(sig[0].count, sig[1].count)
                        let ratio = Double(smaller) / Double(max(bigger, 1))
                        jt = ratio > 0.5 ? "cruciform" : "t_joint"; conf = 0.5
                    } else {
                        jt = "lap"; conf = 0.45
                    }
                } else {
                    jt = "cruciform"; conf = 0.4
                }
                base = "两组板面（二面角不确定 \(Int(dihedral ?? -1))°，沿用网格法线）"
            }
        } else {
            jt = "cruciform"; conf = 0.35; base = "多组板面（≥3 组显著）"
        }

        // 置信度上调：OCCT 原语可用（B-rep 精确）且已作为主判定依据
        if occtOK { conf = max(conf, 0.6) }

        let weldType = (jt == "butt") ? "butt" : "fillet"
        let loadingDirection: String = (jt == "lap") ? "longitudinal" : "transverse"
        let loadCarrying: Bool = (jt != "lap")

        // 4) 可解释依据文本
        var rat = "几何推理：板面组数 \(plateGroups)（\(base)）。"
        if occtOK {
            rat += " OCCT 原语：板面组=\(occt!.plateGroupCount)，二面角≈\(Int(occt!.dihedralAngle))°，主体板厚≈\(Int(occt!.plateThickness))mm，焊缝候选边=\(occt!.weldCandidateEdges)。"
        } else {
            rat += " 注：OCCT 原语不可用（未启用或 STEP 解析失败），仅基于网格法线启发式，置信度偏低。"
        }
        rat += " 荷载方向默认\(loadingDirection == "transverse" ? "横向（最不利）" : "纵向")，请按实际传力确认；全熔透几何无法判定→待确认。"

        return JointHypothesis(jointType: jt, weldType: weldType, loadingDirection: loadingDirection,
            loadCarrying: loadCarrying, fullPenetration: nil, confidence: conf, rationale: rat)
    }

    /// 退化分支：仅依据 OCCT 几何原语（无网格法线）推断接头假设
    private static func hypothesisFromOCCT(_ o: OCCTGeomPrimitives) -> JointHypothesis {
        let pg = max(o.plateGroupCount, 1)
        let jt: String
        if pg <= 1 { jt = "butt" }
        else if pg == 2 {
            if o.dihedralAngle > 70 { jt = "cruciform" }
            else if o.dihedralAngle < 30 { jt = "lap" }
            else { jt = "t_joint" }
        } else { jt = "cruciform" }
        let weldType = (jt == "butt") ? "butt" : "fillet"
        let loadingDirection: String = (jt == "lap") ? "longitudinal" : "transverse"
        let loadCarrying = (jt != "lap")
        let rat = "仅 OCCT 原语（无网格法线）：板面组=\(o.plateGroupCount)，二面角≈\(Int(o.dihedralAngle))°，主体板厚≈\(Int(o.plateThickness))mm → 推断为 \(JointHypothesis.jointTypeLabel(jt))，请人工确认。"
        return JointHypothesis(jointType: jt, weldType: weldType, loadingDirection: loadingDirection,
            loadCarrying: loadCarrying, fullPenetration: nil, confidence: 0.5, rationale: rat)
    }

    // MARK: - M3：板面组提取（焊缝位置候选基础，纯 Swift）

    /// 从网格法线方向聚类出「板面组」，返回每组质心与平均法线。
    /// 复用 collectVertices 收集 (位置, 法线) 对，按 |dot|>0.9 合并为板面组（± 视作同一板）。
    /// 仅保留占比 > 8% 的显著板面组（其余视为噪声/倒角）。
    static func plateGroups(from root: SCNNode) -> [PlateGroup] {
        let vn = collectVertices(from: root)
        guard !vn.isEmpty else { return [] }
        var clusters: [(axis: simd_float3, normalSum: simd_float3, posSum: simd_float3, count: Int)] = []
        for (p, n) in vn {
            let len = simd_length(n)
            guard len > 1e-6 else { continue }
            let u = n / len
            var matched = false
            for i in clusters.indices {
                if abs(simd_dot(u, clusters[i].axis)) > 0.9 {
                    clusters[i].normalSum += u
                    clusters[i].posSum += p
                    clusters[i].count += 1
                    matched = true
                    break
                }
            }
            if !matched { clusters.append((axis: u, normalSum: u, posSum: p, count: 1)) }
        }
        let total = max(clusters.reduce(0) { $0 + $1.count }, 1)
        return clusters
            .filter { Float($0.count) / Float(total) > 0.08 }
            .sorted { $0.count > $1.count }
            .map { c in
                let axis = simd_normalize(c.normalSum)
                let cen = c.count > 0 ? c.posSum / Float(c.count) : simd_float3(0, 0, 0)
                return PlateGroup(centroid: cen, normal: axis, count: c.count)
            }
    }

    /// 递归遍历节点树，收集所有几何的 (顶点位置, 顶点法线) 对（世界/本地坐标，法线已归一化）。
    private static func collectVertices(from root: SCNNode) -> [(simd_float3, simd_float3)] {
        var out: [(simd_float3, simd_float3)] = []
        func walk(_ node: SCNNode) {
            if let geo = node.geometry,
               let vsrc = geo.sources(for: .vertex).first,
               let nsrc = geo.sources(for: .normal).first,
               let vdata = vsrc.data, let ndata = nsrc.data {
                let tf = node.simdWorldTransform
                let vstride = vsrc.dataStride > 0 ? vsrc.dataStride : MemoryLayout<Float>.stride * 3
                let voff = vsrc.dataOffset
                let nstride = nsrc.dataStride > 0 ? nsrc.dataStride : MemoryLayout<Float>.stride * 3
                let noff = nsrc.dataOffset
                let n = min(vsrc.vectorCount, nsrc.vectorCount)
                for i in 0..<n {
                    let vs = voff + i * vstride
                    let ns = noff + i * nstride
                    guard vs + 12 <= vdata.count, ns + 12 <= ndata.count else { continue }
                    let px = vdata.subdata(in: vs..<vs+4).withUnsafeBytes { $0.load(as: Float.self) }
                    let py = vdata.subdata(in: vs+4..<vs+8).withUnsafeBytes { $0.load(as: Float.self) }
                    let pz = vdata.subdata(in: vs+8..<vs+12).withUnsafeBytes { $0.load(as: Float.self) }
                    let nx = ndata.subdata(in: ns..<ns+4).withUnsafeBytes { $0.load(as: Float.self) }
                    let ny = ndata.subdata(in: ns+4..<ns+8).withUnsafeBytes { $0.load(as: Float.self) }
                    let nz = ndata.subdata(in: ns+8..<ns+12).withUnsafeBytes { $0.load(as: Float.self) }
                    let wp = (tf * simd_float4(px, py, pz, 1)).xyz
                    let wn = (tf * simd_float4(nx, ny, nz, 0)).xyz
                    out.append((wp, wn))
                }
            }
            for c in node.childNodes { walk(c) }
        }
        walk(root)
        return out
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
