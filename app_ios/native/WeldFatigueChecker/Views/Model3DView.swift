// Views/Model3DView.swift
// 原生 3D 模型导入与“实物照片 vs 模型”对比。
// - .step/.iges 经 OCCT 桥接读取（需 Mac 端 build_occt_ios.sh 启用 USE_OCCT）
// - .obj/.stl/.ply/.usdz/.glb/.gltf 经 Model I/O 直接读取（无需 OCCT）
// - 支持：双指旋转/缩放、实物照片叠加（透明度可调）、并排对比、包围盒尺寸填入设计表单
import SwiftUI
import SceneKit
import ModelIO
import UniformTypeIdentifiers

// MARK: - M1：OCCT 几何原语（STEP/IGES 经 OCCT 提取，供 JointInference 融合提高准确率）
/// 由 extractFeatures 从 C 结构体 OCCTFeatures 映射而来；available 表示 OCCT 是否成功提取。
struct OCCTGeomPrimitives {
    let thick: Double
    let len: Double
    let minEdge: Double
    let jointHint: String
    // M1 新增（来自 OCCT B-rep 精确几何）
    let plateGroupCount: Int       // 显著板面组数
    let mainNormal: simd_float3    // 主板面法线方向（单位向量）
    let secondNormal: simd_float3  // 次板面法线方向
    let dihedralAngle: Double      // 度，0=平行 90=正交
    let plateThickness: Double     // mm
    let weldCandidateEdges: Int
    let jointHintScore: Double     // 0..1
    let available: Bool
}

// MARK: - 阶段1：3D 图上标注层数据模型（M4 基础）
enum AnnotationSeverity: Equatable {
    case pass      // 绿：满足 / 合理
    case fail      // 红：不满足 / 不合理
    case pending   // 黄：待确认
}

struct ModelAnnotation: Identifiable, Equatable {
    let id = UUID()
    let position: SCNVector3
    let radius: Float
    let severity: AnnotationSeverity
    let title: String
    let detail: String

    // 仅按内容比较（忽略 id），避免每次 body 重建都触发场景重绘
    static func == (lhs: ModelAnnotation, rhs: ModelAnnotation) -> Bool {
        lhs.position.x == rhs.position.x && lhs.position.y == rhs.position.y && lhs.position.z == rhs.position.z
            && lhs.radius == rhs.radius && lhs.severity == rhs.severity
            && lhs.title == rhs.title && lhs.detail == rhs.detail
    }
}

struct Model3DView: View {
    @EnvironmentObject var store: Store
    @State private var showPicker = false
    @State private var modelNode: SCNNode?
    @State private var bbox: (x: Float, y: Float, z: Float) = (0, 0, 0)
    @State private var status: String = "点「导入 3D 模型」选择 .step / .iges / .obj / .stl / .ply / .usdz 文件。"
    @State private var overlayOpacity: Double = 0.5
    @State private var sideBySide = false
    @State private var loadedName: String = ""
    @State private var occtFeatures: OCCTGeomPrimitives? = nil
    @State private var selectedAnnotation: ModelAnnotation? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack {
                    Button { showPicker = true } label: {
                        Label("导入 3D 模型", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(TechButtonStyle())
                    if modelNode != nil {
                        Button { fillDesign() } label: {
                            Label("填入设计表单", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(TechButtonStyle(filled: false))
                        Button { applyInference() } label: {
                            Label("智能推测接头", systemImage: "sparkles")
                        }
                        .buttonStyle(TechButtonStyle(filled: false))
                    }
                }
                .padding(.horizontal)

                Toggle("照片并排对比（左实物 / 右模型）", isOn: $sideBySide)
                    .padding(.horizontal)

                if modelNode != nil, store.photo != nil {
                    HStack {
                        Text("实物照片叠加透明度").font(.caption)
                        Slider(value: $overlayOpacity, in: 0...1)
                    }
                    .padding(.horizontal)
                }

                ZStack {
                    if sideBySide, let photo = store.photo {
                        HStack(spacing: 0) {
                            Image(uiImage: photo).resizable().scaledToFit()
                            Model3DSceneView(node: $modelNode, annotations: buildAnnotations(), selected: $selectedAnnotation)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        Model3DSceneView(node: $modelNode, annotations: buildAnnotations(), selected: $selectedAnnotation)
                            .frame(maxWidth: .infinity)
                        if let photo = store.photo {
                            Image(uiImage: photo).resizable().scaledToFit()
                                .opacity(overlayOpacity)
                                .allowsHitTesting(false)
                                .padding(8)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Theme.panelBottom)
                .overlay(alignment: .topLeading) {
                    if let sel = selectedAnnotation {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(sel.severity == .pass ? Color.green : (sel.severity == .fail ? Color.red : Color.yellow))
                                    .frame(width: 10, height: 10)
                                Text(sel.title).bold().foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 4)
                                Button { selectedAnnotation = nil } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Text(sel.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(10)
                        .background(Theme.panelGradient, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cyan.opacity(0.3), lineWidth: 1))
                        .padding()
                    }
                }

                Text(status).font(.caption2).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal)
            }
            .background(Theme.bgGradient.ignoresSafeArea())
            .navigationTitle("3D 模型对比")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: allowedTypes) { result in
                handlePicker(result)
            }
        }
        .navigationViewStyle(.stack)   // iPad 上强制单栏（修饰符必须加在 NavigationView 上才生效）
    }

    private var allowedTypes: [UTType] {
        ["step", "stp", "iges", "igs", "obj", "stl", "ply", "usdz", "glb", "gltf"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    private func handlePicker(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e):
            status = "选择失败：\(e.localizedDescription)"
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                status = "无法访问该文件（沙盒权限）"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            // 关键：安全作用域在 defer 处立即释放，而解析在后台线程异步进行。
            // 必须在作用域内先把文件拷到 tmp，否则 OCCT 打不开原路径（ReadFile 返回 RetError=2）。
            let name = url.lastPathComponent
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: url, to: tmp)
            } catch {
                status = "复制文件到临时目录失败：\(error.localizedDescription)"
                return
            }
            loadModel(tmp, displayName: name)
        }
    }

    private func loadModel(_ url: URL, displayName: String) {
        let ext = url.pathExtension.lowercased()
        status = "加载中：\(displayName) …"
        DispatchQueue.global(qos: .userInitiated).async {
            var node: SCNNode?
            var errMsg: String?
            var feat: OCCTGeomPrimitives? = nil
            if ext == "step" || ext == "stp" || ext == "iges" || ext == "igs" {
                node = (ext == "step" || ext == "stp") ? loadSTEP(url, &errMsg) : loadIGES(url, &errMsg)
                // OCCT 几何特征提取（STEP/IGES）：板厚/长度/最短边(过渡半径候选)/拓扑提示
                if let f = self.extractFeatures(url) { feat = f }
            } else {
                node = loadViaModelIO(url, &errMsg)
            }
            var sizes: (Float, Float, Float) = (0, 0, 0)
            if let n = node {
                let (mn, mx) = n.boundingBox
                sizes = (abs(mx.x - mn.x), abs(mx.y - mn.y), abs(mx.z - mn.z))
            }
            DispatchQueue.main.async {
                if let n = node {
                    self.modelNode = n
                    self.bbox = sizes
                    self.occtFeatures = feat
                    self.loadedName = displayName
                    if let f = feat {
                        self.status = "已加载 \(displayName) ｜ OCCT 解析：板厚≈\(Int(f.thick))mm，长度≈\(Int(f.len))mm，最短边≈\(String(format:"%.2f", f.minEdge))mm（jointHint=\(f.jointHint)）"
                    } else {
                        self.status = "已加载 \(displayName) ｜ 包围盒(假设 mm) X≈\(Int(sizes.0)) Y≈\(Int(sizes.1)) Z≈\(Int(sizes.2))"
                    }
                    // 阶段2：导入后自动推测接头属性并预填表单（半自动，用户可在「3D 设计审查」确认）
                    self.applyInference()
                } else {
                    self.status = errMsg ?? "加载失败"
                }
            }
        }
    }

    // OCCT 几何特征提取（仅 STEP/IGES，需 USE_OCCT 编译）。返回 nil 表示未启用或失败。
    private func extractFeatures(_ url: URL) -> OCCTGeomPrimitives? {
        var feat = OCCTFeatures()
        var ok = false
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return }
            ok = occt_extract_features(ptr, &feat) != 0
        }
        guard ok else { return nil }
        let dims = [Double(feat.bboxX), Double(feat.bboxY), Double(feat.bboxZ)].sorted()
        let hint = feat.solidCount <= 1 ? "single_solid" : "assembly_\(feat.solidCount)"
        return OCCTGeomPrimitives(
            thick: max(dims[0], 1), len: max(dims[2], 1),
            minEdge: Double(feat.minEdgeLen), jointHint: hint,
            plateGroupCount: Int(feat.plateGroupCount),
            mainNormal: simd_float3(feat.mainNormalX, feat.mainNormalY, feat.mainNormalZ),
            secondNormal: simd_float3(feat.secondNormalX, feat.secondNormalY, feat.secondNormalZ),
            dihedralAngle: Double(feat.dihedralAngle),
            plateThickness: Double(feat.plateThickness),
            weldCandidateEdges: Int(feat.weldCandidateEdges),
            jointHintScore: Double(feat.jointHintScore),
            available: true
        )
    }

    // MARK: - STEP / IGES（经 OCCT 桥接）
    private func loadSTEP(_ url: URL, _ err: inout String?) -> SCNNode? {
        var mesh: UnsafeMutablePointer<OCCTMesh>?
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return }
            mesh = occt_read_step(ptr)
        }
        return finishOCCT(mesh, &err, ext: "STEP")
    }

    private func loadIGES(_ url: URL, _ err: inout String?) -> SCNNode? {
        var mesh: UnsafeMutablePointer<OCCTMesh>?
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return }
            mesh = occt_read_iges(ptr)
        }
        return finishOCCT(mesh, &err, ext: "IGES")
    }

    private func finishOCCT(_ mesh: UnsafeMutablePointer<OCCTMesh>?, _ err: inout String?, ext: String) -> SCNNode? {
        guard let m = mesh else {
            let detail = String(cString: occt_last_error())
            if !detail.isEmpty {
                err = "\(ext) 解析失败：\(detail)"
            } else {
                err = "\(ext) 解析失败，或 OCCT 未启用。请先在 Mac 运行 build_occt_ios.sh 生成 Vendor/OCCT，再用 ./build.sh 重新编译（会自动开启 USE_OCCT）。"
            }
            return nil
        }
        defer { occt_free_mesh(m) }
        return geometryFromMesh(m)
    }

    private func geometryFromMesh(_ m: UnsafeMutablePointer<OCCTMesh>) -> SCNNode? {
        let vCount = Int(m.pointee.vertexCount)
        let iCount = Int(m.pointee.indexCount)
        guard vCount > 0, iCount > 0 else { return nil }
        let posData = Data(bytes: m.pointee.positions!, count: vCount * MemoryLayout<OCCTVec3f>.stride)
        let normData = Data(bytes: m.pointee.normals!,   count: vCount * MemoryLayout<OCCTVec3f>.stride)
        let posSrc = SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: vCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0, dataStride: MemoryLayout<OCCTVec3f>.stride)
        let normSrc = SCNGeometrySource(data: normData, semantic: .normal, vectorCount: vCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0, dataStride: MemoryLayout<OCCTVec3f>.stride)
        let idxData = Data(bytes: m.pointee.indices!, count: iCount * MemoryLayout<Int32>.stride)
        let elem = SCNGeometryElement(data: idxData, primitiveType: .triangles, primitiveCount: iCount / 3,
            bytesPerIndex: MemoryLayout<Int32>.stride)
        let geo = SCNGeometry(sources: [posSrc, normSrc], elements: [elem])
        geo.firstMaterial = standardMaterial()
        return SCNNode(geometry: geo)
    }

    // MARK: - 其余格式（Model I/O 原生支持）
    // 说明：Xcode 26 / iOS 26.5 SDK 已移除 SCNScene(mdlAsset:) 与 SCNScene.sceneWithMDLAsset，
    // 因此这里改为手动把 MDLMesh 的顶点/法线/索引转成 SCNGeometry（仅用未弃用的基础 API）。
    private func loadViaModelIO(_ url: URL, _ err: inout String?) -> SCNNode? {
        let asset = MDLAsset(url: url)
        let root = SCNNode()
        var meshCount = 0
        // childObjects(of:) 直接返回资源层级里全部指定类别的对象（iOS 26 仍可用）
        for obj in asset.childObjects(of: MDLMesh.self) {
            if let mesh = obj as? MDLMesh, let node = scnNode(from: mesh) {
                root.addChildNode(node)
                meshCount += 1
            }
        }
        if meshCount == 0 {
            err = "文件已读取但无几何内容（可能为空模型或格式不支持）。"
            return nil
        }
        return root
    }

    // 把单个 MDLMesh 转为 SCNNode（手动桥接，兼容 iOS 26 SDK）
    // 说明：Xcode 26 / iOS 26.5 SDK 已移除 SCNScene(mdlAsset:) 与 SCNScene.sceneWithMDLAsset，
    // 因此这里改用手动桥接——仅用未弃用的基础 API：
    //   MDLVertexDescriptor.attributes / .layouts、MDLMeshBuffer.length / .map()、MDLSubmesh.indexBuffer。
    // 注意：MDLMeshBufferMap 只有 bytes，没有 length，字节数必须从 MDLMeshBuffer.length 取。
    private func scnNode(from mesh: MDLMesh) -> SCNNode? {
        let vCount = mesh.vertexCount
        let vd = mesh.vertexDescriptor
        let attrs = (vd.attributes as? [MDLVertexAttribute]) ?? []
        let vbufs = (mesh.vertexBuffers as? [MDLMeshBuffer]) ?? []
        // 注意：iOS 26 的 MDLVertexDescriptor.layouts 是 NSMutableArray（非可选、无 stride 成员），
        // 因此 stride 改从 MDLVertexAttributeData.stride 取（该属性稳定存在），
        // offset / bufferIndex 用 MDLVertexAttribute 上已验证可用的字段。
        guard !vbufs.isEmpty else { return nil }

        // position（必需）
        guard let posAttr = attrs.first(where: { $0.name == MDLVertexAttributePosition }) else { return nil }
        let posBufIdx = Int(posAttr.bufferIndex)
        guard posBufIdx >= 0, posBufIdx < vbufs.count else { return nil }
        guard let posAD = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition) else { return nil }
        let posStride = Int(posAD.stride)
        let posVBuf = vbufs[posBufIdx]
        let posData = Data(bytes: posVBuf.map().bytes, count: posVBuf.length)
        let posSrc = SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: vCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: Int(posAttr.offset), dataStride: posStride)

        var sources: [SCNGeometrySource] = [posSrc]
        // normal（可选）
        if let nrmAttr = attrs.first(where: { $0.name == MDLVertexAttributeNormal }) {
            let nrmBufIdx = Int(nrmAttr.bufferIndex)
            guard nrmBufIdx >= 0, nrmBufIdx < vbufs.count else { return nil }
            guard let nrmAD = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) else { return nil }
            let nrmStride = Int(nrmAD.stride)
            let nrmVBuf = vbufs[nrmBufIdx]
            let nrmData = Data(bytes: nrmVBuf.map().bytes, count: nrmVBuf.length)
            let nrmSrc = SCNGeometrySource(data: nrmData, semantic: .normal, vectorCount: vCount,
                usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
                dataOffset: Int(nrmAttr.offset), dataStride: nrmStride)
            sources.append(nrmSrc)
        }

        // 子网格索引
        let subs = (mesh.submeshes as? [MDLSubmesh]) ?? []
        guard !subs.isEmpty else { return nil }
        var elements: [SCNGeometryElement] = []
        for sub in subs {
            let idxVBuf = sub.indexBuffer
            let idxMap = idxVBuf.map()
            let idxData = Data(bytes: idxMap.bytes, count: idxVBuf.length)
            let bytesPerIndex = (sub.indexType == MDLIndexBitDepth.uint16) ? 2 : MemoryLayout<UInt32>.stride
            let isTri = (sub.geometryType == MDLGeometryType.triangles)
            let primType: SCNGeometryPrimitiveType = isTri ? .triangles : .triangleStrip
            let primCount = isTri ? (sub.indexCount / 3) : max(0, sub.indexCount - 2)
            guard primCount > 0 else { continue }
            let el = SCNGeometryElement(data: idxData, primitiveType: primType,
                primitiveCount: primCount, bytesPerIndex: bytesPerIndex)
            elements.append(el)
        }
        guard !elements.isEmpty else { return nil }

        let geo = SCNGeometry(sources: sources, elements: elements)
        geo.firstMaterial = standardMaterial()
        return SCNNode(geometry: geo)
    }

    private func standardMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
        m.metalness.contents = 0.6
        m.roughness.contents = 0.35
        m.emission.contents = UIColor(red: 0.0, green: 0.42, blue: 0.62, alpha: 1.0)
        m.isDoubleSided = true
        return m
    }

    // 把几何特征填入设计表单：优先用 OCCT 解析（板厚/长度/最短边过渡半径候选），
    // 退回用包围盒（最短边≈板厚，最长边≈长度）。
    private func fillDesign() {
        if let f = occtFeatures {
            store.design.plateThicknessMm = f.thick
            store.design.attachmentLengthMm = f.len
            if f.minEdge > 0 { store.design.transitionRadiusMm = f.minEdge }   // 候选，待人工复核
            status = "已通过 OCCT 解析填入：板厚≈\(Int(f.thick))mm，长度≈\(Int(f.len))mm，" +
                "最短边(过渡半径候选)≈\(String(format:"%.2f", f.minEdge))mm（jointHint=\(f.jointHint)；过渡半径/接头类型请人工复核）。"
            return
        }
        let dims = [bbox.x, bbox.y, bbox.z].sorted()
        let thick = Double(dims[0]); let len = Double(dims[2])
        store.design.plateThicknessMm = max(thick, 1)
        store.design.attachmentLengthMm = max(len, 1)
        status = "已填入设计表单：板厚≈\(Int(thick))mm，长度≈\(Int(len))mm（按模型单位为 mm 假设；若模型单位为 m 请除以 1000）。"
    }

    // MARK: - 阶段2：基于 3D 网格几何启发式推断接头属性并预填表单（半自动，需用户确认）
    // 仅作「识别层」增强，不改动 EN1993-1-9 评估内核（见 AUTO_3D_REVIEW_PLAN.md §6）。
    private func applyInference() {
        guard let node = modelNode else { return }
        // 1) 几何（板厚/长度/过渡半径候选）沿用既有逻辑填入
        fillDesign()
        // 2) 接头假设（mesh 法线聚类 + OCCT 几何原语融合 → 启发式，准确率更高）
        let hyp = JointInference.inferJoint(from: node, occt: occtFeatures)
        store.design.jointType = hyp.jointType
        store.design.weldType = hyp.weldType
        store.design.loadingDirection = hyp.loadingDirection
        store.design.loadCarrying = hyp.loadCarrying
        // 全熔透几何无法判定 → 保守默认 false，并在横幅中提示「待确认」（绝不臆测）
        store.design.fullPenetration = hyp.fullPenetration ?? false
        store.inferredJoint = hyp
        status = "几何已填入 + 接头已自动推测（\(hyp.summaryForUI())）。" +
            "置信度\(hyp.confidenceLabel)，请到「3D 设计审查」逐项确认/修改；全熔透无法从几何判定→待人工确认。"
    }

    // MARK: - 阶段1：根据最新评估结果，在 3D 模型上方生成状态标注锚点
    private func buildAnnotations() -> [ModelAnnotation] {
        guard let node = modelNode, let result = store.result else { return [] }
        let (mn, mx) = node.boundingBox
        let center = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        let size = max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z))
        let radius = max(size * 0.03, 1)
        let anchor = SCNVector3(center.x, mx.y + radius * 2.5, center.z)  // 浮于模型顶部之上
        let sev: AnnotationSeverity = result.fatigue.pass ? .pass : .fail
        let title = result.fatigue.detailName
        let verdict = result.fatigue.pass ? "满足 ✓" : (result.fatigue.defectForcedFail ? "缺陷强制判废 ✗" : "不满足 ✗")
        let detail = "对比标准表：EN 1993-1-9 表 \(result.fatigue.table ?? "—")\n有效 FAT \(Int(result.fatigue.effectiveFat)) · 利用率 \(String(format: "%.2f", result.fatigue.utilization)) · \(verdict)"
        return [ModelAnnotation(position: anchor, radius: radius, severity: sev, title: title, detail: detail)]
    }
}

// MARK: - SceneKit 渲染容器（UIViewRepresentable）+ 阶段1 标注层
struct Model3DSceneView: UIViewRepresentable {
    @Binding var node: SCNNode?
    var annotations: [ModelAnnotation]
    @Binding var selected: ModelAnnotation?

    final class Coordinator: NSObject {
        var attached: SCNNode?
        var annotationNodes: SCNNode?
        var annotations: [ModelAnnotation] = []
        var onSelect: ((ModelAnnotation) -> Void)?
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            guard let hit = view.hitTest(g.location(in: view), options: nil).first else { return }
            var n: SCNNode? = hit.node
            while let cur = n {
                if let name = cur.name, let ann = annotations.first(where: { $0.id.uuidString == name }) {
                    onSelect?(ann); return
                }
                n = cur.parent
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.scene = SCNScene()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.onSelect = { a in selected = a }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // 模型节点变化时才重建（避免重置用户视角）
        if context.coordinator.attached !== node {
            context.coordinator.attached = node
            view.scene?.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            context.coordinator.annotationNodes = nil
            context.coordinator.annotations = []
            guard let n = node else { return }
            view.scene?.rootNode.addChildNode(n)
            // 自动取景：把相机放到包围盒对角方向
            let (mn, mx) = n.boundingBox
            let center = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
            let size = max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z))
            let dist = max(size * 1.8, 0.1)
            let distD = Double(dist)  // iOS 上 SCNVector3 分量是 Float，SCNCamera 的 zNear/zFar 是 Double
            let cam = SCNNode()
            let camera = SCNCamera()
            // 关键：模型是 mm 级（可达上万单位），SceneKit 默认 zFar=100 会把整个模型裁掉导致黑屏
            camera.zNear = max(distD * 0.01, 0.01)
            camera.zFar = distD * 10
            camera.wantsHDR = true
            cam.camera = camera
            cam.position = SCNVector3(center.x + dist, center.y + dist * 0.5, center.z + dist)
            cam.look(at: center)
            view.scene?.rootNode.addChildNode(cam)
            view.pointOfView = cam
        }
        // 标注层变化时才重建（独立容器节点，不污染 mesh）
        if context.coordinator.annotations != annotations {
            context.coordinator.annotations = annotations
            context.coordinator.annotationNodes?.removeFromParentNode()
            let container = SCNNode()
            for ann in annotations {
                let marker = makeMarker(ann)
                marker.name = ann.id.uuidString
                container.addChildNode(marker)
            }
            view.scene?.rootNode.addChildNode(container)
            context.coordinator.annotationNodes = container
        }
    }

    private func makeMarker(_ ann: ModelAnnotation) -> SCNNode {
        let geo = SCNSphere(radius: CGFloat(ann.radius))
        let mat = SCNMaterial()
        let color: UIColor = (ann.severity == .pass) ? .systemGreen
            : (ann.severity == .fail ? .systemRed : .systemYellow)
        mat.diffuse.contents = color
        mat.emission.contents = color
        mat.emission.intensity = 0.6
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        node.position = ann.position
        // 呼吸动画，提示可点击
        let pulse = SCNAction.sequence([
            .scale(to: 1.25, duration: 0.8),
            .scale(to: 1.0, duration: 0.8)
        ])
        node.runAction(.repeatForever(pulse))
        return node
    }
}
