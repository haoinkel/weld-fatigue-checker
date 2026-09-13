// LidarScaleCalibrator.swift
// iPad Pro 2025 11" M5（带激光雷达）专用：用 ARKit 直接测得真实尺寸，无需参照物。
//
// 原理：对屏幕上两点做 ARKit 射线投射（raycast）。带 LiDAR 的设备会利用场景深度/
// 场景重建网格提高命中精度，得到两个世界坐标后取欧氏距离即为真实长度。
//
// 使用：把本文件加入 Xcode Target，Info.plist 需含 NSCameraUsageDescription。
// 在 PhotoCheckView 中用 .sheet { LidarMeasureView { mm in ... } } 调起。

import ARKit
import RealityKit
import SwiftUI
import simd

extension float4x4 {
    /// 取变换矩阵的平移分量
    var translation3: SIMD3<Float> { SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z) }
}

// MARK: - 测距核心
final class LidarScaleCalibrator {

    enum MeasureError: LocalizedError {
        case noSurface
        var errorDescription: String? {
            switch self {
            case .noSurface:
                return "未命中被测表面。请正对焊缝、保持 20–50cm 距离，并缓慢平移设备几秒以建立深度信息后重试。"
            }
        }
    }

    /// 设备是否支持场景深度（LiDAR）。iPad Pro 2025 M5 返回 true。
    static var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// 是否支持场景重建网格（LiDAR 建面，命中率更高）
    static var supportsSceneReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    /// 测得屏幕上两点之间的真实距离（毫米）
    /// - 说明：相比 PWA 的"参照物标定"，本方法由 LiDAR 深度直接给出尺度，无需任何参照物。
    static func distanceMillimeters(arView: ARView,
                                    from pointA: CGPoint,
                                    to pointB: CGPoint) throws -> Double {
        let hitsA = arView.raycast(from: pointA, allowing: .estimatedPlane, alignment: .any)
        let hitsB = arView.raycast(from: pointB, allowing: .estimatedPlane, alignment: .any)
        guard let hitA = hitsA.first, let hitB = hitsB.first else {
            throw MeasureError.noSurface
        }
        let pA = hitA.worldTransform.translation3
        let pB = hitB.worldTransform.translation3
        // ARKit 世界坐标单位为米，转毫米
        return Double(simd_distance(pA, pB)) * 1000.0
    }

    /// 容错版本：命中失败返回 nil，便于 UI 直接展示
    static func measureOrNil(arView: ARView, from a: CGPoint, to b: CGPoint) -> Double? {
        try? distanceMillimeters(arView: arView, from: a, to: b)
    }
}

// MARK: - ARView 持有者（供 SwiftUI 层调用测距）
final class ARMeasureCoordinator {
    static let shared = ARMeasureCoordinator()
    weak var arView: ARView?

    func measure(from a: CGPoint, to b: CGPoint) -> Double? {
        guard let v = arView else { return nil }
        return LidarScaleCalibrator.measureOrNil(arView: v, from: a, to: b)
    }
}

// MARK: - ARView 容器（UIViewRepresentable）
struct ARMeasureContainer: UIViewRepresentable {
    var onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        if LidarScaleCalibrator.supportsSceneReconstruction {
            config.sceneReconstruction = .meshWithClassification   // LiDAR 建面，提升命中与精度
        }
        config.environmentTexturing = .automatic
        view.session.run(config)

        ARMeasureCoordinator.shared.arView = view

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint) -> Void)?
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            onTap?(g.location(in: v))
        }
    }
}

// MARK: - LiDAR 测距界面
struct LidarMeasureView: View {
    /// 用户确认后回传测得尺寸（mm）
    let onMeasured: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var taps: [CGPoint] = []
    @State private var measured: Double?
    @State private var message: String = "对准焊缝，点击缺陷的起点，再点击终点"

    var body: some View {
        ZStack(alignment: .bottom) {
            ARMeasureContainer { point in handleTap(point) }
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                Text(LidarScaleCalibrator.supportsSceneDepth ? "LiDAR 深度：可用" : "LiDAR 深度：不可用（将回退普通 AR）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let m = measured {
                    Text(String(format: "测得尺寸 %.1f mm", m))
                        .font(.title3.bold())
                    HStack {
                        Button("使用该尺寸") { onMeasured(m); dismiss() }
                            .buttonStyle(.borderedProminent)
                        Button("重测") {
                            taps.removeAll(); measured = nil
                            message = "重新点击缺陷的起点与终点"
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private func handleTap(_ p: CGPoint) {
        taps.append(p)
        guard taps.count >= 2 else {
            message = "已选起点，请点击终点"
            return
        }
        if let mm = ARMeasureCoordinator.shared.measure(from: taps[0], to: taps[1]) {
            measured = mm
            message = "测量完成，可直接使用或重测"
        } else {
            taps.removeAll()
            message = "未命中表面：请正对焊缝、保持 20–50cm，缓慢平移设备后重测。"
        }
    }
}
