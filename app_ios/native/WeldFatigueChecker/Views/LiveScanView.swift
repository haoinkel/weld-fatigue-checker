// LiveScanView.swift
// 实时相机预览识别视图：后置摄像头实时取帧 → MLDefectDetector 检测 → 屏幕叠加缺陷框。
// 点「📸 捕获」把当前帧与检测到的缺陷写入 store，回到「外观检查」后可标定/LiDAR 量测并评级。
//
// 入口：PhotoCheckView 的「🎥 实时扫描识别」按钮 → fullScreenCover 调起。

import SwiftUI
import AVFoundation

// MARK: - 相机预览
//
// 真机实证：AVCaptureVideoPreviewLayer 在本 App 层级下表现不稳定（帧率正常但画面全黑），
// 而 captureOutput 送来的 lastCapturedImage 已证明持续更新（FPS 计数正常）。
// 故预览直接显示与检测同源的最近帧：① 不可能黑屏；② 与缺陷框叠层坐标完全对齐
// （叠层的 aspectFill 映射本来就是按 frameSize 算的）。代价是预览帧率≈检测节流帧率(约7fps)，
// 对"框选焊缝 + 看缺陷框"的用途完全够用。

// MARK: - 主视图

struct LiveScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store
    @StateObject private var scanner = RealtimeDefectScanner()

    // 阶段2 引擎开关（与 PhotoCheckView 同来源）
    @State private var useMLModel: Bool = MLDefectDetector.useMLModel
    @State private var captureMsg: String = ""

    // 焊缝区域(ROI)框选：拖拽期间记录起止屏幕点；提交后追加写入 scanner.rois 与 store
    @State private var roiDrawing: Bool = false
    @State private var roiStart: CGPoint?
    @State private var roiCurrent: CGPoint?

    var body: some View {
        ZStack {
            // 相机预览：直接显示与检测同源的最近帧（不再依赖预览层，杜绝黑屏且坐标对齐）
            Group {
                if let img = scanner.lastCapturedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Color.black
                    Text("正在启动相机…（首次约需 1~2 秒）")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                // aspectFill 映射：归一化检测框 → 屏幕坐标
                let a = scanner.frameSize.width / max(1, scanner.frameSize.height)   // 图像宽高比
                let vw = geo.size.width, vh = geo.size.height
                let (iwP, ihP, offX, offY) = Self.aspectFill(imageAspect: a, viewW: vw, viewH: vh)

                ZStack {
                    // 关键修复：恒存在的透明占位层。若没有它，当无 roi/无拖拽/无缺陷时
                    // ZStack 尺寸为 0 → contentShape 命中区域为空 → 框选拖拽永远无法触发。
                    Color.clear

                    // 已提交的焊缝区域（虚线黄，支持多处）：区域外不检测
                    ForEach(Array(scanner.rois.enumerated()), id: \.offset) { ri, r in
                        let rs = Self.screenOf(r, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                        Rectangle()
                            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .frame(width: rs.width, height: rs.height)
                            .position(x: rs.midX, y: rs.midY)
                        Text("焊缝#\(ri + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                            .position(x: rs.midX, y: max(offY + 12, rs.minY - 10))
                    }

                    // 拖拽中的框（实线黄）
                    if let s = roiStart, let c = roiCurrent {
                        let n0 = Self.normOf(s, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                        let n1 = Self.normOf(c, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                        let rect = CGRect(x: min(n0.x, n1.x), y: min(n0.y, n1.y),
                                          width: abs(n1.x - n0.x), height: abs(n1.y - n0.y))
                        let rs = Self.screenOf(rect, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: 2)
                            .frame(width: rs.width, height: rs.height)
                            .position(x: rs.midX, y: rs.midY)
                    }

                    // 实时缺陷框（仅在 roi 内）
                    ForEach(Array(scanner.detections.enumerated()), id: \.offset) { _, d in
                        let bx = offX + d.rect.minX * iwP
                        let by = offY + d.rect.minY * ihP
                        let bw = d.rect.width * iwP
                        let bh = d.rect.height * ihP
                        // 优化点 B：若带深度反投影公制尺寸则显示 mm，否则显示像素（未标定）
                        let metricText: String = d.metric.map {
                            String(format: "%.1f mm", $0.primaryMm(type: d.type))
                        } ?? "\(Int(defectMeasurePx(type: d.type, pixelSize: d.pixelSize)))px"
                        ZStack(alignment: .bottom) {
                            Rectangle()
                                .stroke(Theme.defect, lineWidth: 2)
                                .shadow(color: Theme.defect.opacity(0.8), radius: 4, y: 0)
                                .frame(width: bw, height: bh)
                            Text("\(AnnotationMarker.shortLabel(d.type))  \(metricText)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Theme.defect.opacity(0.9),
                                             in: RoundedRectangle(cornerRadius: 5))
                                .offset(y: -bh - 2)
                        }
                        .position(x: bx + bw / 2, y: by + bh / 2)
                    }
                }
                // 框选手势：仅在 roiDrawing 模式下生效（拖拽定义焊缝区域）
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard roiDrawing else { return }
                        if roiStart == nil { roiStart = v.location }
                        roiCurrent = v.location
                    }
                    .onEnded { v in
                        guard roiDrawing, let s = roiStart else { roiStart = nil; roiCurrent = nil; return }
                        let n0 = Self.normOf(s, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                        let n1 = Self.normOf(v.location, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                        let rect = CGRect(x: min(n0.x, n1.x), y: min(n0.y, n1.y),
                                          width: abs(n1.x - n0.x), height: abs(n1.y - n0.y))
                        if rect.width > 0.02, rect.height > 0.02 {   // 太小视为误触
                            // 多处框选：新框追加（可连续框多条焊缝/多个区域）
                            scanner.rois.append(rect)
                            store.vision.weldSeamROIs = scanner.rois
                        }
                        roiStart = nil; roiCurrent = nil
                        roiDrawing = false
                    })
            }

            // 顶部状态条 + 底部控制：用全屏 VStack + Spacer 把两者分别钉到顶部 / 底部，
            // 避免默认居中 ZStack 把两个面板叠在屏幕中间（底部面板会盖住“退出”按钮、挤压框选按钮）。
            // 该外层 VStack 无背景，中间 Spacer 区域透明，触摸可穿透到下层的框选手势。
            VStack(spacing: 0) {
                // 顶部状态条
                HStack {
                    Button(action: { dismiss() }) {
                        Label("退出", systemImage: "xmark.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.55), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1))
                    }
                    .accessibilityLabel("退出实时扫描")
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

                // 底部控制
                VStack(spacing: 10) {
                    if !captureMsg.isEmpty {
                        Text(captureMsg)
                            .font(.caption).foregroundStyle(.white)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }

                    // 焊缝区域闸门（ROI）
                    HStack {
                        Button {
                            if roiDrawing { roiDrawing = false; roiStart = nil; roiCurrent = nil }
                            else { roiDrawing = true }
                        } label: {
                            Label(roiDrawing ? "框选中…拖拽" : "🎯 框选焊缝", systemImage: "viewfinder")
                                .font(.subheadline)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(roiDrawing ? Color.yellow : Theme.cyan.opacity(0.12),
                                             in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(roiDrawing ? .black : Theme.cyan)
                        }
                        if !scanner.rois.isEmpty {
                            Button {
                                scanner.rois = []
                                store.vision.weldSeamROIs = []
                            } label: {
                                Label("清除全部", systemImage: "xmark")
                                    .font(.subheadline)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)

                    if scanner.rois.isEmpty {
                        Text("未框选焊缝区域：暂不检测任何缺陷（避免把非焊缝物体误报为余高）。点「🎯 框选焊缝」在预览上拖拽出焊缝范围；可连续框选多处，每拖一次追加一个区域。")
                            .font(.caption2).foregroundStyle(.orange)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 8)
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
                                        .background(Theme.defect.opacity(0.85), in: Capsule())
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(12)
        }
        .statusBarHidden(true)
        .onAppear {
            scanner.start()
            // 沿用之前已框选的焊缝区域（若用户已在照片或上次扫描中框选过）
            scanner.rois = store.vision.weldSeamROIs
        }
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

    // 屏幕坐标 → 归一化图像坐标（原点左上，0..1），用于把拖拽框换算成 roi
    private static func normOf(_ p: CGPoint, offX: CGFloat, offY: CGFloat,
                               iwP: CGFloat, ihP: CGFloat) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - offX) / iwP)),
                y: min(1, max(0, (p.y - offY) / ihP)))
    }
    // 归一化 → 屏幕（供显示已框选的 roi）
    private static func screenOf(_ r: CGRect, offX: CGFloat, offY: CGFloat,
                                 iwP: CGFloat, ihP: CGFloat) -> CGRect {
        CGRect(x: offX + r.minX * iwP, y: offY + r.minY * ihP,
               width: r.width * iwP, height: r.height * ihP)
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
