// Views/Model3DView.swift
// 原生 3D 模型导入与“实物照片 vs 模型”对比。
// - .step/.iges 经 OCCT 桥接读取（需 Mac 端 build_occt_ios.sh 启用 USE_OCCT）
// - .obj/.stl/.ply/.usdz/.glb/.gltf 经 Model I/O 直接读取（无需 OCCT）
// - 支持：双指旋转/缩放、实物照片叠加（透明度可调）、并排对比、包围盒尺寸填入设计表单
import SwiftUI
import SceneKit
import ModelIO
import UniformTypeIdentifiers

struct Model3DView: View {
    @EnvironmentObject var store: Store
    @State private var showPicker = false
    @State private var modelNode: SCNNode?
    @State private var bbox: (x: Float, y: Float, z: Float) = (0, 0, 0)
    @State private var status: String = "点「导入 3D 模型」选择 .step / .iges / .obj / .stl / .ply / .usdz 文件。"
    @State private var overlayOpacity: Double = 0.5
    @State private var sideBySide = false
    @State private var loadedName: String = ""

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
                            Model3DSceneView(node: $modelNode).frame(maxWidth: .infinity)
                        }
                    } else {
                        Model3DSceneView(node: $modelNode).frame(maxWidth: .infinity)
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
            if ext == "step" || ext == "stp" {
                node = loadSTEP(url, &errMsg)
            } else if ext == "iges" || ext == "igs" {
                node = loadIGES(url, &errMsg)
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
                    self.loadedName = displayName
                    self.status = "已加载 \(displayName) ｜ 包围盒(假设 mm) X≈\(Int(sizes.0)) Y≈\(Int(sizes.1)) Z≈\(Int(sizes.2))"
                } else {
                    self.status = errMsg ?? "加载失败"
                }
            }
        }
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

    // 把包围盒三边长（按 mm 假设）填入设计表单：最短边≈板厚，最长边≈长度
    private func fillDesign() {
        let dims = [bbox.x, bbox.y, bbox.z].sorted()
        let thick = Double(dims[0]); let len = Double(dims[2])
        store.design.plateThicknessMm = max(thick, 1)
        store.design.attachmentLengthMm = max(len, 1)
        status = "已填入设计表单：板厚≈\(Int(thick))mm，长度≈\(Int(len))mm（按模型单位为 mm 假设；若模型单位为 m 请除以 1000）。"
    }
}

// MARK: - SceneKit 渲染容器（UIViewRepresentable）
struct Model3DSceneView: UIViewRepresentable {
    @Binding var node: SCNNode?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene?.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let n = node else { return }
        view.scene?.rootNode.addChildNode(n)
        // 自动取景：把相机放到包围盒对角方向
        let (mn, mx) = n.boundingBox
        let center = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        let size = max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z))
        let dist = max(size * 1.8, 0.1)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.position = SCNVector3(center.x + dist, center.y + dist * 0.5, center.z + dist)
        cam.look(at: center)
        view.scene?.rootNode.addChildNode(cam)
    }
}
