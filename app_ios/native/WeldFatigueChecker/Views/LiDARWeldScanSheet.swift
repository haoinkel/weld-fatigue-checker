// LiDARWeldScanSheet.swift
// iPad Pro 2025 11" M5（带 LiDAR）专用：激光雷达自动识别焊缝及焊缝缺陷。
//
// 原理：
//   1) 用 ARKit 的 sceneDepth 帧语义拿到实时深度图（Float32，单位米）。
//   2) 沿屏幕中线横向采样一条深度剖面（mm），即"垂直于焊缝的横截面"。
//   3) WeldProfileAnalyzer 从剖面识别：焊缝余高、左右焊趾咬边、错边。
//   4) 识别到的候选自动写入缺陷清单（带实测 mm），用户可逐项复核/微调。
//
// 与手动 LiDAR 点测（LiDARMeasureSheet）的区别：本视图"一扫即全"，
// 自动给出整条焊缝的几何轮廓，无需逐点测量。
//
// 入口：PhotoCheckView 的「📡 LiDAR 自动识别焊缝」按钮 → sheet 调起。

import SwiftUI
import ARKit
import RealityKit
import AVFoundation
import CoreVideo
import simd

// MARK: - 深度采样协调器（UIViewRepresentable 持有 ARView）

final class WeldScanCoordinator {
    static let shared = WeldScanCoordinator()
    weak var arView: ARView?
    var anchorTransform: matrix_float4x4?   // 优化点 E：位姿漂移守卫的参考位姿锚

    static func sampleDepthRow(_ depth: AVDepthData) -> [Float]? {
        let map = depthMapMeters(depth)
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = rowBytes / MemoryLayout<Float32>.stride
        let y = h / 2
        var out: [Float] = []
        let step = max(1, w / 240)
        for x in stride(from: 0, to: w, by: step) {
            let v = ptr[y * floatsPerRow + x]
            if v.isFinite, v > 0 { out.append(v * 1000.0) }   // 米 → 毫米
        }
        return out.isEmpty ? nil : out
    }

    /// 抓取当前帧中心竖直列（用于"纵向焊缝"的横截面采样，自顶向下）
    func captureDepthColumn() -> [Float]? {
        guard let frame = arView?.session.currentFrame,
              let depth = frame.capturedDepthData else { return nil }
        return WeldScanCoordinator.sampleDepthColumn(depth)
    }

    static func sampleDepthColumn(_ depth: AVDepthData) -> [Float]? {
        let map = depthMapMeters(depth)
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = rowBytes / MemoryLayout<Float32>.stride
        let x = w / 2
        var out: [Float] = []
        let step = max(1, h / 240)
        for y in stride(from: 0, to: h, by: step) {
            let v = ptr[y * floatsPerRow + x]
            if v.isFinite, v > 0 { out.append(v * 1000.0) }
        }
        return out.isEmpty ? nil : out
    }

    /// 把深度图统一转成"深度(米)"格式，返回其 depthDataMap（视差格式自动回退）
    /// 改为 internal 以便 runScan 复用同一帧深度图做照片缺陷深度反投影（优化点 B）。
    static func depthMapMeters(_ depth: AVDepthData) -> CVPixelBuffer {
        let depthMeters: AVDepthData
        if depth.depthDataType == kCVPixelFormatType_DisparityFloat32 ||
           depth.depthDataType == kCVPixelFormatType_DisparityFloat16 {
            depthMeters = (try? depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)) ?? depth
        } else {
            depthMeters = depth
        }
        return depthMeters.depthDataMap
    }

    /// 在指定横向位置(归一化 frac 0..1)取一条竖线深度剖面（用于横向焊缝多点采样）
    static func sampleDepthColumn(_ depth: AVDepthData, atXFraction frac: Double) -> [Float]? {
        let map = depthMapMeters(depth)
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = rowBytes / MemoryLayout<Float32>.stride
        let x = min(max(Int(Double(w) * frac), 0), w - 1)
        var out: [Float] = []
        let step = max(1, h / 240)
        for y in stride(from: 0, to: h, by: step) {
            let v = ptr[y * floatsPerRow + x]
            if v.isFinite, v > 0 { out.append(v * 1000.0) }
        }
        return out.isEmpty ? nil : out
    }

    /// 在指定纵向位置(归一化 frac 0..1)取一条横线深度剖面（用于纵向焊缝多点采样）
    static func sampleDepthRow(_ depth: AVDepthData, atYFraction frac: Double) -> [Float]? {
        let map = depthMapMeters(depth)
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = rowBytes / MemoryLayout<Float32>.stride
        let y = min(max(Int(Double(h) * frac), 0), h - 1)
        var out: [Float] = []
        let step = max(1, w / 240)
        for x in stride(from: 0, to: w, by: step) {
            let v = ptr[y * floatsPerRow + x]
            if v.isFinite, v > 0 { out.append(v * 1000.0) }
        }
        return out.isEmpty ? nil : out
    }

    /// 沿焊缝长度方向多点采样（点云/网格思路）：横向焊缝取多条竖线、纵向焊缝取多条横线，
    /// 返回 count 条横截面深度剖面（mm）。供 WeldProfileAnalyzer.analyzeBand 做沿缝局部缺陷定位。
    func captureProfileBand(orientation: WeldOrientation, count: Int = 5) -> [[Float]]? {
        guard let frame = arView?.session.currentFrame,
              let depth = frame.capturedDepthData else { return nil }
        let ori: WeldOrientation = (orientation == .auto) ? WeldScanCoordinator.detectOrientation(depth) : orientation
        var band: [[Float]] = []
        for i in 0..<count {
            let frac = count > 1 ? Double(i) / Double(count - 1) : 0.5
            if ori == .horizontal {
                if let p = WeldScanCoordinator.sampleDepthColumn(depth, atXFraction: frac) { band.append(p) }
            } else {
                if let p = WeldScanCoordinator.sampleDepthRow(depth, atYFraction: frac) { band.append(p) }
            }
        }
        return band.isEmpty ? nil : band
    }

    /// 自动判断焊缝走向：比较中心横行与中心纵列的总变差。
    /// 横截面（垂直于焊缝）方向变差更大。
    /// 纵向列变差大 → 横截面是竖线 → 焊缝横向；横行变差大 → 焊缝纵向。
    static func detectOrientation(_ depth: AVDepthData) -> WeldOrientation {
        guard let row = sampleDepthRow(depth), row.count > 5,
              let col = sampleDepthColumn(depth), col.count > 5 else { return .horizontal }
        return totalVariation(col) >= totalVariation(row) ? .horizontal : .vertical
    }

    private static func totalVariation(_ a: [Float]) -> Float {
        guard a.count > 1 else { return 0 }
        var sum: Float = 0
        for i in 1..<a.count { sum += abs(a[i] - a[i - 1]) }
        return sum
    }

    /// 按指定走向抓取横截面剖面；auto 时先检测再采样
    func captureProfile(orientation: WeldOrientation) -> [Float]? {
        guard let frame = arView?.session.currentFrame,
              let depth = frame.capturedDepthData else { return nil }
        let ori: WeldOrientation = (orientation == .auto) ? WeldScanCoordinator.detectOrientation(depth) : orientation
        // 横向焊缝→横截面是竖线→取中心纵列；纵向焊缝→横截面是横线→取中心横行
        return ori == .horizontal ? WeldScanCoordinator.sampleDepthColumn(depth)
                                   : WeldScanCoordinator.sampleDepthRow(depth)
    }

    // MARK: - 优化点 E：位姿漂移守卫
    // 依据：Bondar et al., Measurement 2026 —— 手持抖动 >2cm 引入系统性尺度误差，需告警。
    // 用法：用户点「📌 锁定对齐」记录参考位姿；扫描时比对当前 camera.transform 平移量，超 2cm 告警。
    static let driftThresholdM: Double = 0.02   // 2 cm

    /// 记录当前设备位姿为参考（用户确认对齐焊缝后调用；不调用则扫描时自动以起始帧为锚）
    func setAnchor() {
        anchorTransform = arView?.session.currentFrame?.camera.transform
    }

    /// 自参考位姿的平移量（米）；未锁定返回 nil
    func driftFromAnchorMeters() -> Double? {
        guard let a = anchorTransform,
              let cur = arView?.session.currentFrame?.camera.transform else { return nil }
        let d = cur.columns.3 - a.columns.3   // 平移向量差
        return Double(length(d))
    }

    /// 是否超过漂移阈值
    func isDriftExceeded() -> Bool {
        guard let d = driftFromAnchorMeters() else { return false }
        return d > Self.driftThresholdM
    }

    // MARK: - 优化点 F：实时 AR 3D 锚定标注（链路第⑤步：标注钉在工件表面）
    // 用 RealityKit 锚点把缺陷标签按真实世界坐标固定在工件上；用户移动设备时标注随工件静止。
    private var defectAnchors: [AnchorEntity] = []

    /// 归一化图像点(u,v∈0..1, 原点左上, y 向下) + 深度图 + AR 帧 → 真实世界坐标(米)。
    /// 用彩色相机内参做针孔反投影, 再乘 AR 相机世界变换。深度缺失返回 nil(上层仅保留 2D 清单)。
    static func worldPoint(normalized point: CGPoint, depth: CVPixelBuffer, frame: ARFrame) -> SIMD3<Float>? {
        guard let dM = MetricSizer.depthMeters(at: point, in: depth), dM > 0, dM.isFinite else { return nil }
        let intr = frame.camera.intrinsics
        let fx = Double(intr.columns.0.x), fy = Double(intr.columns.1.y)
        let cx = Double(intr.columns.2.x), cy = Double(intr.columns.2.y)
        guard fx > 0, fy > 0 else { return nil }
        let W = Double(CVPixelBufferGetWidth(depth)), H = Double(CVPixelBufferGetHeight(depth))
        let u = point.x * W, v = point.y * H
        let xCam = Float((u - cx) / fx * dM)
        let yCam = Float(-(v - cy) / fy * dM)   // 图像 y 向下 → 相机 y 向上
        let zCam = Float(dM)
        let world = frame.camera.transform * SIMD4<Float>(xCam, yCam, zCam, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// 在真实世界坐标处放置缺陷标注（小球 + 文字），随工件静止。
    func addDefectAnchor(world: SIMD3<Float>, label: String, color: UIColor) {
        guard let arView = arView else { return }
        let anchor = AnchorEntity(world: world)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.008),
                                materials: [SimpleMaterial(color: color, roughness: 0.4, isMetallic: false)])
        let textMesh = MeshResource.generateText(label, extrusionDepth: 0.001,
                                                 font: .systemFont(ofSize: 0.035),
                                                 containerFrame: .zero, alignment: .center)
        let text = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: color)])
        text.position = [0, 0.03, 0]   // 球上方 3 cm
        anchor.addChild(sphere)
        anchor.addChild(text)
        arView.scene.addAnchor(anchor)
        defectAnchors.append(anchor)
    }

    /// 清除所有已放置的 3D 标注
    func clearDefectAnchors() {
        guard let arView = arView else { defectAnchors.removeAll(); return }
        for a in defectAnchors { arView.scene.removeAnchor(a) }
        defectAnchors.removeAll()
    }
}

// MARK: - ARView 容器

struct WeldScanContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if LidarScaleCalibrator.supportsSceneReconstruction {
            config.sceneReconstruction = .meshWithClassification
        }
        config.environmentTexturing = .automatic
        view.session.run(config)
        WeldScanCoordinator.shared.arView = view
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - 扫描会话（设备能力）

final class WeldScanSession: ObservableObject {
    @Published var lidarOK: Bool = false
    @Published var scanning: Bool = false

    func start() {
        lidarOK = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    func stop() {
        WeldScanCoordinator.shared.arView?.session.pause()
    }
}

// MARK: - 主视图

struct LiDARWeldScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store
    @StateObject private var session = WeldScanSession()

    @State private var summary: String = "将 iPad 正对焊缝，使屏幕中线横切焊缝，保持 20–60cm，缓慢平移几秒建立深度后点「扫描焊缝」。可手动指定焊缝走向，或选「自动」由 LiDAR 判定。"
    @State private var scanning: Bool = false
    @State private var recognizedCount: Int = 0
    @State private var orientation: WeldOrientation = .auto
    @State private var showCloudCfg: Bool = false   // 云端配置（模型/Key）sheet

    var body: some View {
        ZStack {
            WeldScanContainer()
                .ignoresSafeArea()

            // 采样线指示：横向焊缝→竖线(取中心纵列)；纵向焊缝→横线(取中心横行)；自动→十字
            GeometryReader { geo in
                let cx = geo.size.width / 2, cy = geo.size.height / 2
                Path { p in
                    if orientation == .vertical {
                        p.move(to: CGPoint(x: 0, y: cy)); p.addLine(to: CGPoint(x: geo.size.width, y: cy))
                    } else if orientation == .horizontal {
                        p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: geo.size.height))
                    } else {
                        p.move(to: CGPoint(x: 0, y: cy)); p.addLine(to: CGPoint(x: geo.size.width, y: cy))
                        p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: geo.size.height))
                    }
                }
                .stroke(Theme.cyan.opacity(0.85), lineWidth: 2)
                .allowsHitTesting(false)
            }

            VStack {
                // 顶部状态
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Text("📡 LiDAR 自动识别焊缝")
                            .font(.subheadline.bold()).foregroundStyle(.white)
                        Badge(text: session.lidarOK ? "LiDAR 深度 ✓" : "LiDAR 深度 ✗",
                              color: session.lidarOK ? .green : .orange)
                    }
                    Spacer()
                    Color.clear.frame(width: 32, height: 32)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                Spacer()

                // 结果与操作
                VStack(spacing: 12) {
                    Text(summary)
                        .font(.callout).multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                    Picker("焊缝走向", selection: $orientation) {
                        ForEach(WeldOrientation.allCases, id: \.self) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)

                    // 检测引擎模式（端侧/云端/自动，与照片页同源）；runScan 读取 store.params.engineMode
                    Picker("检测引擎", selection: $store.params.engineMode) {
                        ForEach(DetectionEngineMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)

                    if store.params.engineMode != "local" {
                        Button {
                            showCloudCfg = true
                        } label: {
                            Label("云端配置（模型/Key）", systemImage: "server.rack")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.10), in: Capsule())
                                .foregroundStyle(.cyan)
                        }
                    }

                    Button(action: runScan) {
                        Label(scanning ? "识别中…" : "扫描焊缝", systemImage: "waveform")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                                       startPoint: .leading, endPoint: .trailing),
                                        in: Capsule())
                            .foregroundStyle(.black)
                            .shadow(color: Theme.cyan.opacity(0.4), radius: 10, y: 0)
                    }
                    .disabled(scanning)

                    if recognizedCount > 0 {
                        Button("完成并返回") { dismiss() }
                            .buttonStyle(.borderedProminent).tint(.green)
                        Button(action: { WeldScanCoordinator.shared.clearDefectAnchors() }) {
                            Label("清除 3D 标注", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered).tint(.white)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .statusBarHidden(true)
        .onAppear { session.start() }
        .onDisappear { WeldScanCoordinator.shared.clearDefectAnchors(); session.stop() }
        // 云端配置 sheet（模型预设三选一 + endpoint/Key），与照片页共用 CloudVisionConfigView
        .sheet(isPresented: $showCloudCfg) {
            NavigationStack {
                ScrollView { CloudVisionConfigView().padding() }
                .navigationTitle("云端视觉配置")
                .toolbar { Button("完成") { showCloudCfg = false } }
            }
        }
    }

    private func runScan() {
        scanning = true
        // 优化点 E：若用户未手动锁定对齐，则以此刻为锚（扫描为单帧抓取，瞬时漂移≈0）
        if WeldScanCoordinator.shared.anchorTransform == nil { WeldScanCoordinator.shared.setAnchor() }
        summary = "正在读取 LiDAR 深度剖面…"
        WeldScanCoordinator.shared.clearDefectAnchors()   // 重新扫描前清掉旧 3D 标注
        // 深度抓取需在主线程 AR 会话中，UI 反馈稍后给结果
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let band = WeldScanCoordinator.shared.captureProfileBand(orientation: orientation) else {
                scanning = false
                summary = "未获取到深度。请正对焊缝、保持 20–60cm，缓慢平移设备几秒后重试。"
                return
            }
            // 解析实际走向（auto 时由 LiDAR 判定），用于结果说明
            let resolved: WeldOrientation = {
                guard orientation == .auto,
                      let depth = WeldScanCoordinator.shared.arView?.session.currentFrame?.capturedDepthData
                else { return orientation }
                return WeldScanCoordinator.detectOrientation(depth)
            }()
            // 沿缝多点采样 → 合并为缺陷候选（含焊瘤/满溢 overlap 与沿缝局部缺陷）
            let cands = WeldProfileAnalyzer.analyzeBand(band)
            // 自动写入缺陷清单（带实测 mm，用户可逐项复核）
            for c in cands {
                store.vision.imperfections.append(
                    ImperfectionInput(type: c.type, sizeMm: c.sizeMm, poreMm: nil))
            }
            // 自动标定：用 LiDAR 深度 + 相机内参(fx) 反推 像素/mm，使照片 ML 检测结果无需手动标定即得 mm
            var autoScaledNote = ""
            if let arView = WeldScanCoordinator.shared.arView,
               let frame = arView.session.currentFrame {
                let fx = frame.camera.intrinsics.columns.0.x
                let scaleProfile = band[band.count / 2]   // 用中心剖面做尺度标定
                let depths = scaleProfile.filter { $0.isFinite && $0 > 0 }
                if depths.count > 4, fx > 0 {
                    let sorted = depths.sorted()
                    let medianM = Double(sorted[sorted.count / 2]) / 1000.0
                    let pxPerMm = Double(fx) / medianM
                    store.applyPhotoScale(pxPerMm)
                    autoScaledNote = "\n（已用 LiDAR 深度自动标定尺度：1 mm ≈ \(String(format: "%.1f", pxPerMm)) px，照片检测现可直接按 mm 评级）"

                    // 优化点 B：用同一 AR 帧的彩色图 + 深度图 + 相机内参，直接对焊缝做缺陷识别，
                    // 并深度反投影得到公制 mm（无需单独"点测/照片标定"）。失败自动跳过，不影响既有 LiDAR 候选。
                    // 注：ARKit capturedImage 为相机朝向，与深度同坐标系，尺寸换算一致；框叠层显示 orientation 由 UI 另处校正。
                    if let colorPB = frame.capturedImage as CVPixelBuffer?,
                       let ui = UIImage.fromPixelBuffer(colorPB),
                       let depthData = frame.capturedDepthData {
                        let depthPB = WeldScanCoordinator.depthMapMeters(depthData)
                        let intr = frame.camera.intrinsics
                        let mode = DetectionEngineMode(rawValue: store.params.engineMode) ?? .local
                        if mode == .local {
                            // 现有本地深度感知检测（保留 LiDAR 真尺度 mm）
                            let photoDets = MLDefectDetector.detect(in: ui, maxCount: 16,
                                                                   roi: store.vision.weldSeamROIs.first,
                                                                   depth: depthPB, intrinsics: intr)
                            for d in photoDets {
                                let mm = d.metric.map { $0.primaryMm(type: d.type) }
                                store.vision.imperfections.append(
                                    ImperfectionInput(type: d.type, sizeMm: mm, poreMm: nil,
                                                      location: CGPoint(x: d.rect.midX, y: d.rect.midY),
                                                      bbox: d.rect, pixelSize: d.pixelSize))
                            }
                            // 优化点 F：彩色帧融合缺陷按真实世界坐标钉在工件表面（AR 叠加）
                            for d in photoDets {
                                let c = CGPoint(x: d.rect.midX, y: d.rect.midY)
                                if let wp = WeldScanCoordinator.worldPoint(normalized: c, depth: depthPB, frame: frame) {
                                    let mm = d.metric.map { $0.primaryMm(type: d.type) } ?? 0
                                    let lbl = "\(d.type) \(String(format: "%.1f", mm))mm"
                                    WeldScanCoordinator.shared.addDefectAnchor(world: wp, label: lbl, color: .systemYellow)
                                }
                            }
                            if !photoDets.isEmpty {
                                autoScaledNote += "\n（LiDAR 融合：彩色帧缺陷已识别并深度反投影得 mm，共 \(photoDets.count) 项）"
                            }
                        } else {
                            // 云端 / 自动：经 DetectionRouter 获取类别+bbox（无网自动回落端侧），
                            // 仍用 LiDAR 深度反投影定位钉 AR 锚点；mm 取云端 estSizeMm（模型估算，非 LiDAR 真尺度）
                            let rois = store.vision.weldSeamROIs.isEmpty
                                ? [CGRect(x: 0, y: 0, width: 1, height: 1)]
                                : store.vision.weldSeamROIs
                            let capUI = ui, capDepth = depthPB, capFrame = frame
                            Task {
                                let (cd, src, note) = await DetectionRouter.detect(in: capUI, rois: rois, mode: mode)
                                DispatchQueue.main.async {
                                    for d in cd {
                                        let mm = d.metric.map { $0.primaryMm(type: d.type) }
                                        store.vision.imperfections.append(
                                            ImperfectionInput(type: d.type, sizeMm: mm, poreMm: nil,
                                                              location: CGPoint(x: d.rect.midX, y: d.rect.midY),
                                                              bbox: d.rect, pixelSize: d.pixelSize))
                                    }
                                    for d in cd {
                                        let c = CGPoint(x: d.rect.midX, y: d.rect.midY)
                                        if let wp = WeldScanCoordinator.worldPoint(normalized: c, depth: capDepth, frame: capFrame) {
                                            let mm = d.metric.map { $0.primaryMm(type: d.type) } ?? 0
                                            let lbl = "\(d.type) \(String(format: "%.1f", mm))mm"
                                            WeldScanCoordinator.shared.addDefectAnchor(world: wp, label: lbl, color: .systemYellow)
                                        }
                                    }
                                    if !cd.isEmpty {
                                        summary += "\n（\(src) 融合：彩色帧缺陷已识别并深度反投影，共 \(cd.count) 项）"
                                    } else if src == "local(fallback)" {
                                        summary += "\n（云端不可用，已自动回落端侧）"
                                    }
                                }
                            }
                        }
                    }
                // 优化点 F：深度剖面候选也锚定在扫描中线附近（不依赖彩色帧）
                if let dd = frame.capturedDepthData {
                    let dpb = WeldScanCoordinator.depthMapMeters(dd)
                    for (i, c) in cands.enumerated() {
                        let p = CGPoint(x: 0.5, y: 0.5 + Double(i) * 0.05)
                        if let wp = WeldScanCoordinator.worldPoint(normalized: p, depth: dpb, frame: frame) {
                            let lbl = "\(c.label) \(String(format: "%.1f", c.sizeMm))mm"
                            WeldScanCoordinator.shared.addDefectAnchor(world: wp, label: lbl, color: .systemOrange)
                        }
                    }
                }
            }
            }
            scanning = false
            recognizedCount = cands.count
            if cands.isEmpty {
                summary = "（走向：\(resolved.label)）深度剖面未见明显焊缝轮廓或几何不规则（差均 < 阈值）。\n建议手动记录，或用「📐 点测」精确测量单个缺陷。"
            } else {
                summary = "（走向：\(resolved.label)）LiDAR 已识别 \(cands.count) 项，已自动加入缺陷清单（可复核/微调）：\n" +
                    cands.map { "· \($0.label)：\(String(format: "%.1f", $0.sizeMm)) mm（置信度 \(Int($0.confidence * 100))%）" }
                        .joined(separator: "\n")
            }
            summary += autoScaledNote + "\n" + ISO5817Grader.ndtDisclaimer
        }
    }
}
