// LiveScanView.swift
// 实时相机预览识别视图：后置摄像头实时取帧 → MLDefectDetector 检测 → 屏幕叠加缺陷框。
// 点「📸 捕获」把当前帧与检测到的缺陷写入 store，回到「外观检查」后可标定/LiDAR 量测并评级。
//
// 入口：PhotoCheckView 的「🎥 实时扫描识别」按钮 → fullScreenCover 调起。

import SwiftUI
import AVFoundation

// MARK: - 相机预览层（AVCaptureVideoPreviewLayer 容器）

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        context.coordinator.previewLayer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var previewLayer: AVCaptureVideoPreviewLayer? }
}

// MARK: - 主视图

struct LiveScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store
    @StateObject private var scanner = RealtimeDefectScanner()

    // 阶段2 引擎开关（与 PhotoCheckView 同来源）
    @State private var useMLModel: Bool = MLDefectDetector.useMLModel
    @State private var captureMsg: String = ""

    var body: some View {
        ZStack {
            CameraPreview(session: scanner.session)
                .ignoresSafeArea()

            GeometryReader { geo in
                // aspectFill 映射：归一化检测框 → 屏幕坐标
                let a = scanner.frameSize.width / max(1, scanner.frameSize.height)   // 图像宽高比
                let vw = geo.size.width, vh = geo.size.height
                let (iwP, ihP, offX, offY) = Self.aspectFill(imageAspect: a, viewW: vw, viewH: vh)

                ForEach(Array(scanner.detections.enumerated()), id: \.offset) { _, d in
                    let bx = offX + d.rect.minX * iwP
                    let by = offY + d.rect.minY * ihP
                    let bw = d.rect.width * iwP
                    let bh = d.rect.height * ihP
                    let longPx = Int(defectMeasurePx(type: d.type, pixelSize: d.pixelSize))
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .stroke(Theme.cyan, lineWidth: 2)
                            .shadow(color: Theme.cyan.opacity(0.8), radius: 4, y: 0)
                            .frame(width: bw, height: bh)
                        Text("\(AnnotationMarker.shortLabel(d.type))  \(longPx)px")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.cyan.opacity(0.9),
                                         in: RoundedRectangle(cornerRadius: 5))
                            .offset(y: -bh - 2)
                    }
                    .position(x: bx + bw / 2, y: by + bh / 2)
                }
            }

            // 顶部状态条
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("🎥 实时焊缝缺陷扫描")
                            .font(.subheadline.bold()).foregroundStyle(.white)
                        if let err = scanner.lastError {
                            Text(err).font(.caption2).foregroundStyle(.red)
                        } else {
                            Text("\(scanner.fps) FPS · \(MLDefectDetector.engineName)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    Spacer()
                    Color.clear.frame(width: 32, height: 32)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Spacer()
            }

            // 底部控制
            VStack(spacing: 10) {
                Spacer()
                if !captureMsg.isEmpty {
                    Text(captureMsg)
                        .font(.caption).foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                // 引擎开关 + 实时缺陷数
                HStack {
                    Image(systemName: "brain").foregroundStyle(.purple)
                    Toggle("AI 模型识别", isOn: $useMLModel)
                        .font(.subheadline)
                    Spacer()
                    Text(MLDefectDetector.isModelAvailable ? "模型已加载" : "CV 回退")
                        .font(.caption2)
                        .foregroundStyle(MLDefectDetector.isModelAvailable ? .green : .secondary)
                }
                .padding(.horizontal, 8)
                .onChange(of: useMLModel) { _, v in MLDefectDetector.useMLModel = v }

                // 实时缺陷列表（类型 + 像素尺寸；mm 评级需在捕获后标定）
                if !scanner.detections.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(scanner.detections.enumerated()), id: \.offset) { i, d in
                                let longPx = Int(defectMeasurePx(type: d.type, pixelSize: d.pixelSize))
                                Text("#\(i+1) \(AnnotationMarker.shortLabel(d.type)) \(longPx)px")
                                    .font(.caption2).foregroundStyle(.black)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.cyan.opacity(0.85), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 28)
                }

                // 捕获按钮
                Button(action: captureCurrent) {
                    Label("捕获快照", systemImage: "camera.circle.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                                   startPoint: .leading, endPoint: .trailing),
                                     in: Capsule())
                        .foregroundStyle(.black)
                        .shadow(color: Theme.cyan.opacity(0.4), radius: 10, y: 0)
                }

                Text("捕获后回到「外观检查」，可用 📏 标定比例 或 LiDAR 点测得到真实 mm 并自动评级。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .statusBarHidden(true)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    // aspectFill：图像按 cover 填满视图时的显示尺寸与居中偏移
    private static func aspectFill(imageAspect a: CGFloat, viewW: CGFloat, viewH: CGFloat)
        -> (iwP: CGFloat, ihP: CGFloat, offX: CGFloat, offY: CGFloat) {
        guard a > 0, viewW > 0, viewH > 0 else {
            return (viewW, viewH, 0, 0)
        }
        let viewAspect = viewW / viewH
        let iwP: CGFloat, ihP: CGFloat
        if viewAspect >= a {        // 视图更宽 → 高度填满
            ihP = viewH; iwP = viewH * a
        } else {                    // 视图更窄 → 宽度填满
            iwP = viewW; ihP = viewW / a
        }
        return (iwP, ihP, (viewW - iwP) / 2, (viewH - ihP) / 2)
    }

    /// 把当前帧与检测到的缺陷写入 store，回到照片视图继续标定/评级
    private func captureCurrent() {
        guard let img = scanner.lastCapturedImage else {
            captureMsg = "尚未取到帧，请稍候再点捕获。"
            return
        }
        store.photo = img
        // 清掉之前自动框（保留手动添加的缺陷），写入本次实时检测
        store.vision.imperfections.removeAll { $0.bbox != nil }
        let t = store.vision.plateThicknessMm
        for d in scanner.detections {
            let center = CGPoint(x: d.rect.midX, y: d.rect.midY)
            // 实时无参照比例，mm 未知 → 不评级；尺寸以像素记录，待标定/LiDAR 后转 mm
            store.vision.imperfections.append(
                ImperfectionInput(type: d.type, sizeMm: nil, poreMm: nil,
                                  location: center, bbox: d.rect, pixelSize: d.pixelSize)
            )
        }
        let n = scanner.detections.count
        captureMsg = n == 0 ? "已捕获（未检出明显缺陷），回到外观检查。" : "已捕获 \(n) 处疑似缺陷，回到外观检查后可标定评级。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
    }
}
