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

    func run() {
        result = DesignReviewer.assess(design: design, vision: vision,
                                       params: params, mode: mode)
    }

    func addImperfection(location: CGPoint? = nil) {
        vision.imperfections.append(ImperfectionInput(type: "undercut", sizeMm: nil, poreMm: nil, location: location))
    }
    func removeImperfection(at i: Int) {
        guard vision.imperfections.indices.contains(i) else { return }
        vision.imperfections.remove(at: i)
    }
}
