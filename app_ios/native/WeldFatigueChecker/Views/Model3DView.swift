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
                    .buttonStyle(.borderedProminent)
                    if modelNode != nil {
                        Button { fillDesign() } label: {
                            Label("填入设计表单", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.bordered)
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
                .background(Color(.secondarySystemBackground))

                Text(status).font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            .navigationTitle("3D 模型对比")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: allowedTypes) { result in
                handlePicker(result)
            }
        }
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
            loadModel(url)
        }
    }

    private func loadModel(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        status = "加载中：\(url.lastPathComponent) …"
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
                    self.loadedName = url.lastPathComponent
                    self.status = "已加载 \(url.lastPathComponent) ｜ 包围盒(假设 mm) X≈\(Int(sizes.0)) Y≈\(Int(sizes.1)) Z≈\(Int(sizes.2))"
                } else {
                    self.status = errMsg ?? "加载失败"
                }
            }
        }
    }

    // MARK: - STEP / IGES（经 OCCT 桥接）
    private func loadSTEP(_ url: URL, _ err: inout String?) -> SCNNode? {
        var mesh: OCCTMesh?
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return }
            mesh = occt_read_step(ptr)
        }
        return finishOCCT(mesh, &err, ext: "STEP")
    }

    private func loadIGES(_ url: URL, _ err: inout String?) -> SCNNode? {
        var mesh: OCCTMesh?
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return }
            mesh = occt_read_iges(ptr)
        }
        return finishOCCT(mesh, &err, ext: "IGES")
    }

    private func finishOCCT(_ mesh: OCCTMesh?, _ err: inout String?, ext: String) -> SCNNode? {
        guard let m = mesh else {
            err = "\(ext) 解析失败，或 OCCT 未启用。请先在 Mac 运行 build_occt_ios.sh 生成 Vendor/OCCT，再用 ./build.sh 重新编译（会自动开启 USE_OCCT）。"
            return nil
        }
        defer { occt_free_mesh(m) }
        return geometryFromMesh(m)
    }

    private func geometryFromMesh(_ m: OCCTMesh) -> SCNNode? {
        let vCount = Int(m.vertexCount)
        let iCount = Int(m.indexCount)
        guard vCount > 0, iCount > 0 else { return nil }
        let posData = Data(bytes: m.positions!, count: vCount * MemoryLayout<OCCTVec3f>.stride)
        let normData = Data(bytes: m.normals!,   count: vCount * MemoryLayout<OCCTVec3f>.stride)
        let posSrc = SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: vCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0, dataStride: MemoryLayout<OCCTVec3f>.stride)
        let normSrc = SCNGeometrySource(data: normData, semantic: .normal, vectorCount: vCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0, dataStride: MemoryLayout<OCCTVec3f>.stride)
        let idxData = Data(bytes: m.indices!, count: iCount * MemoryLayout<Int32>.stride)
        let elem = SCNGeometryElement(data: idxData, primitiveType: .triangles, primitiveCount: iCount / 3,
            bytesPerIndex: MemoryLayout<Int32>.stride)
        let geo = SCNGeometry(sources: [posSrc, normSrc], elements: [elem])
        geo.firstMaterial = standardMaterial()
        return SCNNode(geometry: geo)
    }

    // MARK: - 其余格式（Model I/O 原生支持）
    private func loadViaModelIO(_ url: URL, _ err: inout String?) -> SCNNode? {
        do {
            let asset = MDLAsset(url: url)
            let scene = SCNScene(mdlAsset: asset)
            let node = SCNNode()
            for child in scene.rootNode.childNodes { node.addChildNode(child) }
            if node.childNodes.isEmpty && node.geometry == nil {
                err = "文件已读取但无几何内容（可能为空模型）。"
                return nil
            }
            return node
        } catch {
            err = "加载失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func standardMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemBlue
        m.metalness.contents = 0.1
        m.roughness.contents = 0.7
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
