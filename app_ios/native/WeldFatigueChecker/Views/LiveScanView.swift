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
        // 结构性防呆（真机实证：全屏 ZStack 叠加 + VStack/Spacer 夹心布局，真机上可能把
        // 顶栏/底栏挤出可视区 → "看不到返回键、无法返回"）。改为【上-中-下三段 VStack】：
        // 顶栏(退出)与底栏(控制面板)由布局系统保证永远在安全区内、不可能出屏；
        // 相机画面只占中间弹性区；框选手势只挂中间相机区，与按钮无层级冲突。
        VStack(spacing: 0) {
            topBar
            cameraLayer
            bottomPanel
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        // 问题3加固：退出/返回键钉在根视图 overlay 最上层，不参与 VStack 布局分配——
        // 无论中间相机区/底栏如何伸缩，该键永远可见可点（真机“无返回无退出”的终极保险）。
        .overlay(alignment: .topLeading) { floatingExitButton }
        .onAppear {
            scanner.start()
            // 沿用之前已框选的焊缝区域（若用户已在照片或上次扫描中框选过）
            scanner.rois = store.vision.weldSeamROIs
        }
        .onDisappear { scanner.stop() }
        // 防御：首帧到达后再同步一次 roi，避免 onAppear 早于 store 就绪导致框选框不显示
        .onChange(of: scanner.lastCapturedImage) { _, newImg in
            if newImg != nil, scanner.rois.isEmpty, !store.vision.weldSeamROIs.isEmpty {
                scanner.rois = store.vision.weldSeamROIs
            }
        }
    }

    // MARK: - 顶栏（标题/FPS；退出键已上移为根视图浮动钉死，见 floatingExitButton）
    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 64, height: 34)   // 给浮动退出键占位，标题保持居中
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
                // 显式提示已沿用的框选：让用户明确知道焊缝框已带入、未丢失
                if !scanner.rois.isEmpty {
                    Text("已框选 \(scanner.rois.count) 处焊缝 · 检测仅在框内")
                        .font(.caption2).foregroundStyle(.yellow)
                }
                // 构建版本戳：真机验收时一眼判定侧载的是新包还是旧 artifact
                Text("Build \(BuildInfo.gitSHA)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Color.clear.frame(width: 64, height: 34)   // 与退出按钮等宽占位，标题保持居中
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55))
    }

    // 问题3：浮动退出/返回键——overlay 钉在根视图左上，永远在最上层、永远可点。
    // dismiss() 同时承担“返回上一页(外观检查)”与“退出实时扫描”两个语义。
    private var floatingExitButton: some View {
        Button(action: { dismiss() }) {
            Label("退出", systemImage: "xmark.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.black.opacity(0.65), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
        }
        .accessibilityLabel("退出实时扫描")
        .padding(.leading, 12)
        .padding(.top, 8)
    }

    // MARK: - 中部：相机画面 + ROI/缺陷叠层（aspectFill 映射基于本区域）
    private var cameraLayer: some View {
        ZStack {
            if let img = scanner.lastCapturedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                cameraOverlay
            } else {
                Color.black
                Text("正在启动相机…（首次约需 1~2 秒）")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // ROI 框选 + 缺陷框叠层：坐标按 aspectFill 映射到相机区；手势只作用于这一层
    private var cameraOverlay: some View {
        GeometryReader { geo in
            let a = scanner.frameSize.width / max(1, scanner.frameSize.height)   // 图像宽高比
            let vw = geo.size.width, vh = geo.size.height
            let (iwP, ihP, offX, offY) = Self.aspectFill(imageAspect: a, viewW: vw, viewH: vh)

            ZStack {
                // 关键：恒存在的透明占位层，保证无 roi/无拖拽/无缺陷时手势命中区域不为空
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

                // 问题3：未框选时常显“框选区域”虚线占位框——框选功能的可见存在感，
                // 与验证基线（用户基准截图）一致；拖拽出框后自动消失，替换为“焊缝#N”实框。
                if scanner.rois.isEmpty && roiStart == nil {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: vw * 0.28, height: vh * 0.30)
                        .overlay(alignment: .top) {
                            Text("框选区域")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                                .offset(y: -10)
                        }
                        .position(x: vw / 2, y: vh / 2)
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
            // 框选手势：拖拽定义焊缝区域（仅相机区内生效，不再全屏铺开）
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
    }

    // MARK: - 底部控制面板
    private var bottomPanel: some View {
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
                    Label(roiDrawing ? "框选中…拖拽" : "框选焊缝", systemImage: "viewfinder")
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
                        Label("清除", systemImage: "xmark")
                            .font(.subheadline)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }

            if scanner.rois.isEmpty {
                Text("未框选焊缝区域：暂不检测任何缺陷（避免把非焊缝物体误报为余高）。点「框选焊缝」后在画面上拖拽出焊缝范围；可连续框选多处，每拖一次追加一个区域。")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
