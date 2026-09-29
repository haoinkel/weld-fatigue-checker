// Store.swift
// 全局可观察状态：3D 设计 / 照片 / 荷载 输入 + 评估结果

import SwiftUI

final class Store: ObservableObject {
    @Published var design = DesignInput()
    @Published var vision = VisionInput()
    @Published var params = UserParams()
    @Published var mode = "both"          // both | photo | design
    @Published var result: AssessmentResult?
    @Published var photo: UIImage?

    // 照片标定比例：每毫米对应多少「显示/原图像素」；nil 表示尚未标定。
    // 标定后，自动识别的缺陷尺寸会以 mm 显示（否则显示像素）。
    @Published var photoPxPerMm: Double?
    // 自动识别后的状态提示
    @Published var autoState: String = ""

    // 检测 / 评估历史（按时间倒序，最新在前）。用于回看既往焊缝检查记录。
    @Published var history: [HistoryEntry] = []

    // 评估进行中标志（C1：后台异步评估，避免大图/连续扫描阻塞主线程）
    @Published var isComputing: Bool = false

    /// 在后台线程执行评估，避免大图/连续扫描时阻塞主线程（C1）。
    /// 评估期间 isComputing 为真，UI 可禁用按钮并展示进度；结果在主线程回写。
    func run() {
        guard !isComputing else { return }      // 防止重入：评估未完成前忽略再次触发
        isComputing = true
        autoState = "正在评估…"

        // 捕获当前输入的值副本，后台读取期间不受 UI 实时编辑影响
        let d = design, v = vision, p = params, m = mode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = DesignReviewer.assess(design: d, vision: v, params: p, mode: m)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.result = r
                self.recordAssessment(r)
                self.isComputing = false
                self.autoState = "评估完成"
            }
        }
    }

    /// 评估完成后写入历史（疲劳利用率 / 缺陷超差数一目了然）
    private func recordAssessment(_ r: AssessmentResult) {
        let rej = r.imperfections.filter { $0.accepted == false }.count
        let summary = r.imperfections.map { $0.label }.joined(separator: "、")
        history.insert(HistoryEntry(date: Date(), kind: "评估",
            title: "\(r.fatigue.detailName) (\(r.fatigue.detailId))",
            utilization: r.fatigue.utilization, pass: r.fatigue.pass,
            defects: r.imperfections.count, rejected: rej, summary: summary), at: 0)
        if history.count > 50 { history.removeLast() }
    }

    /// 手动「保存当前照片缺陷快照」到历史（不触发完整评估）
    func snapshotPhoto() {
        let imps = vision.imperfections
        let rej = imps.filter { $0.accepted == false }.count
        let summary = imps.map { DefectTypes.label($0.type) }.joined(separator: "、")
        let jointLabel = vision.jointType
        history.insert(HistoryEntry(date: Date(), kind: "照片快照",
            title: "\(jointLabel) · \(imps.count) 处缺陷",
            utilization: nil, pass: nil,
            defects: imps.count, rejected: rej, summary: summary), at: 0)
        if history.count > 50 { history.removeLast() }
    }

    func addImperfection(location: CGPoint? = nil) {
        vision.imperfections.append(ImperfectionInput(type: "undercut", sizeMm: nil, poreMm: nil, location: location))
    }
    func removeImperfection(at i: Int) {
        guard vision.imperfections.indices.contains(i) else { return }
        vision.imperfections.remove(at: i)
    }

    /// 按「超差 > 未判定 > 合格，同类再按类别严重度（裂纹>未熔合>咬边>焊瘤>气孔）」重排缺陷列表。
    /// 仅改变顺序，不丢失任何数据；UI 全部用当前索引引用，重排后保持一致。
    func sortImperfections() {
        vision.imperfections.sort {
            let a = DefectTypes.acceptanceRank($0.accepted)
            let b = DefectTypes.acceptanceRank($1.accepted)
            if a != b { return a < b }
            return DefectTypes.typeRank($0.type) < DefectTypes.typeRank($1.type)
        }
    }

    /// LiDAR / 点测得到的真实尺度回填：写入 photoPxPerMm，并把已有自动框（bbox != nil）的
    /// 像素尺寸按「纵向-进图方向」换算成 mm。手动录入项（bbox == nil）不在此处理。
    func applyPhotoScale(_ pxPerMm: Double) {
        photoPxPerMm = pxPerMm
        for i in vision.imperfections.indices where vision.imperfections[i].bbox != nil {
            if let ps = vision.imperfections[i].pixelSize {
                vision.imperfections[i].sizeMm =
                    defectMeasurePx(type: vision.imperfections[i].type, pixelSize: ps) / pxPerMm
            }
        }
    }
}

// MARK: - 历史记录条目
struct HistoryEntry: Identifiable {
    let id = UUID()
    let date: Date
    let kind: String            // "评估" | "照片快照"
    let title: String
    let utilization: Double?    // 疲劳利用率（仅评估有）
    let pass: Bool?
    let defects: Int
    let rejected: Int
    let summary: String
}
