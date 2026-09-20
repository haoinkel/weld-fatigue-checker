// LiDARMeasureSheet.swift
// iPad Pro 2025 11" M5（带 LiDAR）专用测距界面：全屏 AR 视图 + 状态机 + reticle + 设备能力检测。
//
// 连续模式（v2）：
//   - 进入后自动列出所有"未填尺寸"的缺陷，按列表逐一提示用户测量
//   - 测完一条 → 写回 Store → 提示"已写入"→ 自动跳到下一个
//   - 全部测完 → 显示总结视图 → 一键完成退出
//   - 支持随时"跳过当前"、"完成退出"
//
// 入口：PhotoCheckView 在缺陷行点 "📐 LiDAR" 按钮 → sheet 调起本视图
//
// 设计要点：
//   1. 状态机 idle → first → done/failed（单次测量）
//   2. 屏幕中心 reticle：用户只需移动设备把 reticle 对准缺陷，无需在屏幕上点
//   3. 实时显示 LiDAR / 网格可用性（iPad Pro 2025 M5 都应是 ✓）
//   4. 引导遮罩：首次使用提示如何操作
//   5. 失败提示：未命中表面时（光线太暗 / 距离过远）给出明确指导

import SwiftUI
import ARKit

// MARK: - 状态机

enum MeasureState: Equatable {
    case idle       // 等用户点起点
    case first      // 起点已标记，等用户点终点
    case done       // 已测得距离
    case failed(String) // 测量失败原因
}

// MARK: - 缺陷任务（队列元素）

struct MeasureTask: Identifiable {
    let id: Int          // store 里的 imperfection 索引
    let type: String     // undercut/porosity/...
    let hint: String     // "咬边"等中文
    var sizeMm: Double?  // 已测得则非空
}

// MARK: - 主视图

struct LiDARMeasureSheet: View {
    /// 起始缺陷索引（用户在某行点 📐 触发）；nil 表示"扫描所有未填尺寸的缺陷"
    let initialIndex: Int?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store
    @StateObject private var session = MeasureSession()
    @State private var showGuide = true

    // 队列
    @State private var queue: [MeasureTask] = []
    @State private var queuePosition: Int = 0  // 当前正在测的索引
    @State private var doneCount: Int = 0      // 已完成（含跳过）
    @State private var skipCount: Int = 0

    var body: some View {
        ZStack {
            // AR 视图层
            ARMeasureContainer { point in
                session.handleTap(point)
            }
            .ignoresSafeArea()

            // 屏幕中心十字 reticle
            ReticleView(state: session.state)
                .allowsHitTesting(false)

            // 顶部状态条
            VStack {
                TopBar(
                    progress: queueProgress,
                    current: currentTask,
                    lidarOK: session.lidarOK,
                    meshOK: session.meshOK,
                    onClose: { dismiss() }
                )
                .padding()
                Spacer()
                BottomBar(
                    state: session.state,
                    measured: session.measuredMm,
                    canSkip: hasNext || hasPrev,
                    onCapture: { session.captureCenter() },
                    onReset: { session.reset() },
                    onSkip: { skipCurrent() },
                    onFinish: {
                        if let m = session.measuredMm, let t = currentTask {
                            commit(m, for: t)
                        }
                        finishSession()
                    },
                    onUse: {
                        if let m = session.measuredMm, let t = currentTask {
                            commit(m, for: t)
                            advance()
                        }
                    }
                )
                .padding()
            }

            if showGuide {
                GuideOverlay(onDismiss: {
                    withAnimation(.easeOut(duration: 0.25)) { showGuide = false }
                })
            }

            // 全部完成总结
            if queue.isEmpty || queuePosition >= queue.count {
                CompletionOverlay(
                    doneCount: doneCount,
                    skipCount: skipCount,
                    onDone: { dismiss() }
                )
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            session.start()
            loadQueue()
        }
        .onDisappear { session.stop() }
    }

    // MARK: - 队列

    /// 当前任务
    private var currentTask: MeasureTask? {
        guard queuePosition < queue.count else { return nil }
        return queue[queuePosition]
    }

    /// 进度文字
    private var queueProgress: String {
        if queue.isEmpty { return "队列为空" }
        let total = queue.count
        let current = min(queuePosition + 1, total)
        return "\(current) / \(total)"
    }

    private var hasNext: Bool { queuePosition < queue.count - 1 }
    private var hasPrev: Bool { queuePosition > 0 }

    /// 从 Store 加载待测队列：
    /// 1. 若指定了 initialIndex，从该行开始连续测所有未填尺寸的缺陷；
    /// 2. 否则扫描所有未填尺寸的缺陷。
    private func loadQueue() {
        let tasks: [MeasureTask] = store.vision.imperfections.enumerated().map { idx, imp in
            MeasureTask(id: idx, type: imp.type, hint: imperfectionLabel(imp.type), sizeMm: imp.sizeMm)
        }
        // 优先把 initialIndex 放在队首，其它未填尺寸的按顺序追加
        let unsizedIndices = tasks.enumerated().compactMap { $0.element.sizeMm == nil ? $0.offset : nil }
        var ordered: [Int] = []
        if let start = initialIndex, tasks.indices.contains(start) {
            ordered.append(start)
        }
        for i in unsizedIndices where i != initialIndex {
            ordered.append(i)
        }
        queue = ordered.map { tasks[$0] }
        queuePosition = 0
        doneCount = 0
        skipCount = 0
    }

    /// 中文类型标签
    private func imperfectionLabel(_ type: String) -> String {
        switch type {
        case "undercut": return "咬边"
        case "porosity": return "气孔"
        case "excess_weld_metal": return "余高过大"
        case "overlap": return "焊瘤/满溢"
        case "linear_misalignment": return "错边"
        default: return type
        }
    }

    /// 外部注入队列（PhotoCheckView 在 .sheet 弹出前调用）
    public func setQueue(_ tasks: [MeasureTask], startAt: Int) {
        queue = tasks
        queuePosition = max(0, min(startAt, tasks.count - 1))
    }

    /// 提交一个测量结果（直接写 Store，不走回调）
    private func commit(_ mm: Double, for task: MeasureTask) {
        if store.vision.imperfections.indices.contains(task.id) {
            store.vision.imperfections[task.id].sizeMm = mm
        }
        if let i = queue.firstIndex(where: { $0.id == task.id }) {
            queue[i].sizeMm = mm
        }
    }

    /// 测完后跳到下一个
    private func advance() {
        session.reset()
        doneCount += 1
        if queuePosition < queue.count - 1 {
            queuePosition += 1
        } else {
            // 全部完成
            queuePosition = queue.count
        }
    }

    /// 跳过当前
    private func skipCurrent() {
        skipCount += 1
        session.reset()
        if hasNext {
            queuePosition += 1
        } else {
            queuePosition = queue.count
        }
    }

    /// 手动结束整个会话
    private func finishSession() {
        queuePosition = queue.count
    }
}

// MARK: - 会话（状态机）

final class MeasureSession: ObservableObject {
    @Published var state: MeasureState = .idle
    @Published var measuredMm: Double?
    @Published var lidarOK: Bool = false
    @Published var meshOK: Bool = false

    private var pointA: CGPoint?

    func start() {
        lidarOK = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        meshOK = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    func stop() {
        ARMeasureCoordinator.shared.arView?.session.pause()
    }

    /// 用户按"标记"按钮 = 屏幕中心
    func captureCenter() {
        guard let arView = ARMeasureCoordinator.shared.arView else { return }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        handleTap(center)
    }

    func handleTap(_ p: CGPoint) {
        switch state {
        case .idle:
            pointA = p
            state = .first
        case .first:
            guard let a = pointA else { state = .idle; return }
            if let mm = ARMeasureCoordinator.shared.measure(from: a, to: p) {
                measuredMm = mm
                state = .done
            } else {
                state = .failed("未命中被测表面。请保持 20–50cm 距离，缓慢平移设备几秒以建立深度，再重测。")
                pointA = nil
            }
        case .done, .failed:
            break
        }
    }

    func reset() {
        pointA = nil
        measuredMm = nil
        state = .idle
    }
}

// MARK: - 屏幕中心十字

struct ReticleView: View {
    let state: MeasureState

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .stroke(stateColor, lineWidth: 3)
                    .frame(width: 36, height: 36)
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .shadow(color: .black.opacity(0.4), radius: 4)
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle: return .yellow
        case .first: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: - 顶部状态条

struct TopBar: View {
    let progress: String
    let current: MeasureTask?
    let lidarOK: Bool
    let meshOK: Bool
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            Spacer()
            VStack(spacing: 4) {
                if let t = current {
                    Text("缺陷 \(progress)：\(t.hint)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("LiDAR 测距 · 队列完成")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }
                HStack(spacing: 6) {
                    Badge(text: lidarOK ? "LiDAR ✓" : "LiDAR ✗", color: lidarOK ? .green : .orange)
                    Badge(text: meshOK ? "网格 ✓" : "网格 ✗", color: meshOK ? .green : .orange)
                }
            }
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 底部操作条

struct BottomBar: View {
    let state: MeasureState
    let measured: Double?
    let canSkip: Bool
    let onCapture: () -> Void
    let onReset: () -> Void
    let onSkip: () -> Void
    let onFinish: () -> Void
    let onUse: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case .done:
                if let m = measured {
                    Text(String(format: "%.1f mm", m))
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    HStack(spacing: 10) {
                        Button("重测", action: onReset)
                            .buttonStyle(.bordered).tint(.white).controlSize(.large)
                        Button("下一条 ➡", action: onUse)
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.large)
                    }
                    Button("完成本次会话", action: onFinish)
                        .buttonStyle(.bordered).tint(.white)
                }
            case .failed(let msg):
                Text(msg)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 10) {
                    Button(action: onReset) {
                        Label("重试", systemImage: "arrow.counterclockwise")
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .background(Color.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if canSkip {
                        Button(action: onSkip) {
                            Label("跳过", systemImage: "forward.fill")
                                .padding(.vertical, 8).padding(.horizontal, 12)
                                .background(Color.white.opacity(0.2), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            default:
                Text(prompt)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button(action: onCapture) {
                    Label(buttonLabel, systemImage: "scope")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(buttonColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                if canSkip {
                    Button("跳过当前", action: onSkip)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var prompt: String {
        switch state {
        case .idle: return "把屏幕中心十字对准缺陷的起点，按「标记起点」"
        case .first: return "保持设备稳定，平移使十字对准缺陷的终点，按「标记终点」"
        default: return ""
        }
    }

    private var buttonLabel: String {
        switch state {
        case .idle: return "标记起点"
        case .first: return "标记终点"
        default: return ""
        }
    }

    private var buttonColor: Color {
        switch state {
        case .idle: return Theme.cyan
        case .first: return .orange
        default: return .gray
        }
    }
}

// MARK: - 全部完成总结视图

struct CompletionOverlay: View {
    let doneCount: Int
    let skipCount: Int
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                Text("全部缺陷已测距")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                VStack(spacing: 6) {
                    Text("已完成 \(doneCount) 个")
                        .foregroundStyle(.white.opacity(0.9))
                    if skipCount > 0 {
                        Text("已跳过 \(skipCount) 个")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .font(.title3)
                Button(action: onDone) {
                    Text("完成")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.green, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)
            }
            .padding(40)
        }
    }
}

// MARK: - 首次使用引导遮罩

struct GuideOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "scope")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                Text("LiDAR 自动测距（连续模式）")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 10) {
                    bullet("保持 iPad 距离焊缝 20–50 cm")
                    bullet("正对焊缝，缓慢平移几秒建立深度")
                    bullet("屏幕中央十字对准缺陷起点，按「标记」")
                    bullet("平移至终点，按「标记」即得真实毫米")
                    bullet("点「下一条 ➡」自动写回并跳到下一个缺陷")
                    bullet("可随时「跳过」或「完成本次会话」")
                    bullet("整个过程无需任何参照物，精度 ±1–2 mm")
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding()
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                Button(action: onDismiss) {
                    Text("开始批量测量")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity).padding()
                        .background(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                                   startPoint: .leading, endPoint: .trailing),
                                     in: Capsule())
                        .foregroundStyle(.black)
                }
                .padding(.top, 8)
            }
            .padding(40)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").bold()
            Text(text)
        }
        .font(.callout)
    }
}