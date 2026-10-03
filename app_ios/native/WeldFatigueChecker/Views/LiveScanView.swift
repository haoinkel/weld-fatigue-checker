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
    @State private var roiHint: String = ""   // 框选方向/多选反馈（短暂提示）

    /// 短暂提示：2.5 秒后若未被新提示覆盖则自动清除
    private func flashRoi(_ msg: String) {
        roiHint = msg
        let token = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if roiHint == token { roiHint = "" }
        }
    }

    var body: some View {
        // 结构性防呆（真机五轮实证后的最终结论）：
        // 顶/底栏"出屏"的病根从来不是容器姿势（VStack/safeAreaInset/overlay 都试过），
        // 而是 .scaledToFill 的相机 Image 以图像完整原始尺寸参与布局，把容器撑得比屏幕大。
        // 相机层改为精确 aspectFill 尺寸后（见 cameraLayer），回到最经典的三段 VStack：
        // 顶栏(退出+标题+FPS) / 相机弹性区 / 底栏(框选+AI开关+捕获)，高度协商必然正常。
        VStack(spacing: 0) {
            topBar
            cameraLayer
            bottomPanel
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
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

    // MARK: - 顶栏（对齐用户基线图：退出按钮 + 标题 + FPS，黑半透明圆角条）
    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: { dismiss() }) {
                Label("退出", systemImage: "xmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
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
                if !scanner.rois.isEmpty {
                    Text("已框选 \(scanner.rois.count) 处焊缝")
                        .font(.caption2).foregroundStyle(.yellow)
                }
            }
            Spacer()
            Color.clear.frame(width: 64, height: 30)   // 与退出按钮等宽占位，标题保持居中
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55))
    }

    // MARK: - 中部：相机画面 + ROI/缺陷叠层（aspectFill 映射基于本区域）
    private var cameraLayer: some View {
        GeometryReader { geo in
            let a = scanner.frameSize.width / max(1, scanner.frameSize.height)   // 图像宽高比
            let (iwP, ihP, offX, offY) = Self.aspectFill(imageAspect: a,
                                                          viewW: geo.size.width,
                                                          viewH: geo.size.height)
            ZStack {
                if let img = scanner.lastCapturedImage {
                    // 治本（真机五轮实证的根因）：禁用 scaledToFill——它按图像完整原始尺寸
                    // (如 4032x3024) 参与布局，把容器撑得比屏幕大，顶/底栏全被推出屏幕外。
                    // 改为按叠层同源的 aspectFill 精确尺寸放置：零贪婪，且与缺陷框坐标天然对齐。
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: iwP, height: ihP)
                        .position(x: offX + iwP / 2, y: offY + ihP / 2)
                } else {
                    Text("正在启动相机…（首次约需 1~2 秒）")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                cameraOverlay
            }
        }
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

                // 拖拽中的框：合法方向（左上→右下）黄色实线，非法方向红色提示
                if let s = roiStart, let c = roiCurrent {
                    let n0 = Self.normOf(s, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                    let n1 = Self.normOf(c, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                    let downRight = n1.x >= n0.x && n1.y >= n0.y
                    let rect = CGRect(x: min(n0.x, n1.x), y: min(n0.y, n1.y),
                                      width: abs(n1.x - n0.x), height: abs(n1.y - n0.y))
                    let rs = Self.screenOf(rect, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                    Rectangle()
                        .stroke(downRight ? Color.yellow : Color.red, lineWidth: 2)
                        .frame(width: rs.width, height: rs.height)
                        .position(x: rs.midX, y: rs.midY)
                    if !downRight {
                        Text("请从左上向右下拖拽框选")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                            .position(x: rs.midX, y: max(offY + 12, rs.minY - 12))
                    }
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
                    if roiStart == nil { roiStart = v.location; roiHint = "" }   // 新一次拖拽，清掉上一条提示
                    roiCurrent = v.location
                }
                .onEnded { v in
                    guard roiDrawing, let s = roiStart else { roiStart = nil; roiCurrent = nil; return }
                    let n0 = Self.normOf(s, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                    let n1 = Self.normOf(v.location, offX: offX, offY: offY, iwP: iwP, ihP: ihP)
                    roiStart = nil; roiCurrent = nil
                    // 方向约束（需求2）：只允许 左上 → 右下 框选
                    guard n1.x >= n0.x, n1.y >= n0.y else {
                        flashRoi("方向错误：请始终从左上向右下拖拽框选焊缝")
                        return   // 多点框选：保持 roiDrawing，便于立即重拖
                    }
                    let rect = CGRect(x: n0.x, y: n0.y, width: n1.x - n0.x, height: n1.y - n0.y)
                    if rect.width > 0.02, rect.height > 0.02 {   // 太小视为误触
                        // 多处框选（需求1）：新框追加，可连续框多条焊缝/多个区域
                        scanner.rois.append(rect)
                        store.vision.weldSeamROIs = scanner.rois
                        flashRoi("已框选 \(scanner.rois.count) 处，可继续框选；点「完成框选」结束")
                    } else {
                        flashRoi("框选区域过小，请重新从左上向右下拖拽")
                    }
                    // 注意：不复位 roiDrawing —— 连续框选多条焊缝，由「完成框选」按钮结束
                })
        }
    }

    // MARK: - 底部控制面板（对齐用户基线图：框选焊缝/清除 → AI开关 → 捕获快照大按钮 → 小字）
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if !captureMsg.isEmpty {
                Text(captureMsg)
                    .font(.caption).foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            // 第一行：焊缝区域闸门（ROI）——框选焊缝 / 撤销 / 清除
            HStack(spacing: 12) {
                Button {
                    if roiDrawing {            // 结束多点框选
                        roiDrawing = false
                        roiStart = nil; roiCurrent = nil
                        roiHint = ""
                    } else {                   // 进入多点框选
                        roiDrawing = true
                        flashRoi("从左上向右下拖拽框选焊缝：可连续框多条，点「完成框选」结束")
                    }
                } label: {
                    Label(roiDrawing ? "完成框选" : "框选焊缝", systemImage: "viewfinder")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(roiDrawing ? Color.yellow.opacity(0.9) : Color.white.opacity(0.10),
                                     in: Capsule())
                        .foregroundStyle(roiDrawing ? .black : .cyan)
                        .overlay(Capsule().stroke(Color.cyan.opacity(roiDrawing ? 0 : 0.7), lineWidth: 1))
                }
                .accessibilityHint("进入后从左上向右下拖拽可连续框选多条焊缝，再次点击结束框选")
                if !scanner.rois.isEmpty {
                    Button {
                        scanner.rois.removeLast()
                        store.vision.weldSeamROIs = scanner.rois
                        flashRoi(scanner.rois.isEmpty ? "" : "已撤销最近一处，剩 \(scanner.rois.count) 处")
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Button {
                        scanner.rois = []
                        store.vision.weldSeamROIs = []
                        roiHint = ""
                    } label: {
                        Label("清除", systemImage: "xmark")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.red.opacity(0.14), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }

            // 框选方向/多选提示
            if !roiHint.isEmpty {
                Text(roiHint)
                    .font(.caption2).foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            // 第二行：引擎开关 + 状态
            HStack {
                Image(systemName: "brain").foregroundStyle(.purple)
                Toggle("AI 模型识别", isOn: $useMLModel)
                    .font(.subheadline)
                    .tint(.cyan)
                Spacer()
                Text(MLDefectDetector.isModelAvailable ? "模型已加载" : "CV 回退")
                    .font(.caption2)
                    .foregroundStyle(MLDefectDetector.isModelAvailable ? .green : .secondary)
            }
            .onChange(of: useMLModel) { _, v in MLDefectDetector.useMLModel = v }

            // 捕获按钮（大胶囊，蓝渐变）
            Button(action: captureCurrent) {
                Label("捕获快照", systemImage: "camera.circle.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                               startPoint: .leading, endPoint: .trailing),
                                 in: Capsule())
                    .foregroundStyle(.black)
                    .shadow(color: Theme.cyan.opacity(0.35), radius: 8, y: 0)
            }

            Text("捕获后回到「外观检查」，可用 📏 标定比例或 LiDAR 点测得到真实 mm 并自动评级 · BUILD \(BuildInfo.gitSHA)")
                .font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.72))
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
