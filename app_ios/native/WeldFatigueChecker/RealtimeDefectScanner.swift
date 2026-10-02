// RealtimeDefectScanner.swift
// 阶段2 延伸：把相机取帧做成「实时预览识别」，而非只能选照片。
//
// 原理：
//   - AVCaptureSession 取 iPad 后置广角摄像头帧（视频数据输出，逐帧回调）。
//   - 每帧（节流到约 6~7 fps 以省电）转 UIImage → 调 MLDefectDetector.detect(in:)。
//   - MLDefectDetector 内部优先 Core ML 实例分割，未加载模型时自动回退 CV 规则，
//     因此本模块零改动即可在「有模型 / 无模型」两种状态下工作。
//   - 检测结果（归一化框 + App type）通过 @Published 暴露，供 LiveScanView 叠层绘制。
//
// 与 LiDARWeldScanSheet 的关系：
//   - 本模块负责「表面缺陷有无 / 分类 / 平面尺寸」（可见光）。
//   - 余高 / 咬边深度等几何量仍由 LiDARWeldScanSheet + WeldProfileAnalyzer 负责。
//   - 捕获一帧后，缺陷以自动框形式写入 store.vision.imperfections，回到照片视图后可
//     用「📏 标定比例」或 LiDAR 点测得到真实 mm，再触发 ISO 5817 评级。
//
// 说明：本环境无 Mac，无法编译验证；已对授权、节流、空值守卫做 try/catch 包裹。

import Foundation
import AVFoundation
import UIKit
import CoreImage
import CoreMedia
import CoreVideo

final class RealtimeDefectScanner: NSObject, ObservableObject,
                                    AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - 会话与队列
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "realtime.defect.scan.session")
    private let detectQueue  = DispatchQueue(label: "realtime.defect.scan.detect")

    // MARK: - 发布状态（供 SwiftUI 叠层）
    @Published var detections: [DetectedDefect] = []
    @Published var isRunning: Bool = false
    @Published var lastError: String? = nil
    @Published var fps: Int = 0
    /// 最近一帧（用于「捕获快照」写入报告）；同时记录其尺寸供叠层做 aspectFill 映射
    @Published var lastCapturedImage: UIImage? = nil
    @Published var frameSize: CGSize = CGSize(width: 720, height: 1280)
    /// 焊缝区域闸门（归一化 0..1，由 LiveScanView 的「框选焊缝」写入）。
    /// 为 nil 时不检测任何缺陷（避免扫描非焊缝物体误报余高等）；设置后只检测该区域内缺陷。
    @Published var roi: CGRect? = nil

    // MARK: - 参数
    /// 单帧检测节流间隔（秒）：约 6.7 fps，足够实时预览且省电。
    private let detectInterval: CFTimeInterval = 0.15
    private var lastDetectTime: CFTimeInterval = 0
    private var fpsCount = 0
    private var fpsStart = CFAbsoluteTimeGetCurrent()
    private var started = false

    // MARK: - 启动 / 停止

    func start() {
        guard !started else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureAndRun() }
                else { DispatchQueue.main.async { self.lastError = "相机权限被拒绝，请在「设置」中允许。" } }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.lastError = "相机权限被拒绝，请在「设置 → 隐私与安全 → 相机」中允许本 App。"
            }
        @unknown default:
            configureAndRun()
        }
    }

    func stop() {
        guard started else { return }
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        DispatchQueue.main.async {
            self.isRunning = false
            self.detections = []
        }
        started = false
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            // 后置广角摄像头（iPad Pro 自带；与 LiDAR 同设备）
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.lastError = "无法访问后置摄像头。" }
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)

            // 视频数据输出（逐帧回调）
            self.videoOutput.videoSettings =
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.detectQueue)
            guard self.session.canAddOutput(self.videoOutput) else {
                DispatchQueue.main.async { self.lastError = "无法添加视频输出。" }
                self.session.commitConfiguration()
                return
            }
            self.session.addOutput(self.videoOutput)

            // 竖屏：预览层与检测 UIImage 同朝向，框才能对齐
            if let conn = self.videoOutput.connection(with: .video) {
                if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
                if conn.isVideoMirroringSupported { conn.isVideoMirrored = false }
            }
            self.session.commitConfiguration()

            self.session.startRunning()
            DispatchQueue.main.async {
                self.started = true
                self.isRunning = true
                self.lastError = nil
            }
        }
    }

    // MARK: - 逐帧回调

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDetectTime >= detectInterval else { return }
        lastDetectTime = now

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let (ui, size) = Self.uiImage(from: pb) else { return }

        // 先保存最新帧与 FPS 统计（与 ROI 无关）：
        // 修复——原实现把 lastCapturedImage 更新放在 ROI 闸门之后，未框选焊缝时帧被
        // 直接丢弃，点「捕获快照」永远报"尚未取到帧"。ROI 只应闸检测，不应闸取帧。
        DispatchQueue.main.async {
            self.frameSize = size
            self.lastCapturedImage = ui
            // FPS 统计
            self.fpsCount += 1
            let el = now - self.fpsStart
            if el >= 1.0 {
                self.fps = Int(Double(self.fpsCount) / el)
                self.fpsCount = 0
                self.fpsStart = now
            }
        }

        // 焊缝区域闸门：未框选焊缝时不检测，避免非焊缝物体（高光/纹理）被误判为余高等缺陷
        guard let roi = roi else {
            DispatchQueue.main.async {
                self.detections = []
            }
            return
        }

        // 同一入口：模型可用走 Core ML，否则回退 CV 规则（均按 roi 过滤）
        let dets = MLDefectDetector.detect(in: ui, maxCount: 16, roi: roi)

        DispatchQueue.main.async {
            self.detections = dets
        }
    }

    /// 把 CVPixelBuffer 转成 cgImage 支撑的 UIImage（竖屏、降采样到 ≤720px 提速）
    private static func uiImage(from pb: CVPixelBuffer) -> (UIImage, CGSize)? {
        let ci = CIImage(cvPixelBuffer: pb)
        let w = ci.extent.width, h = ci.extent.height
        guard w > 0, h > 0 else { return nil }
        let maxDim: CGFloat = 720
        let scale = min(1.0, maxDim / max(w, h))
        let tw = w * scale, th = h * scale
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tw, height: th))
        let ui = renderer.image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: tw, height: th))
        }
        return (ui, CGSize(width: tw, height: th))
    }
}
