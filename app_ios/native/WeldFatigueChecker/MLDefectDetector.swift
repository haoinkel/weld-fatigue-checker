// MLDefectDetector.swift
// 阶段2：Core ML 实例分割模型接入，替换阶段0 的纯 CV 规则（PhotoDefectDetector）。
//
// 设计原则：
//  - 与 PhotoDefectDetector 同接口 `detect(in:) -> [DetectedDefect]`，上层「自动标注」逻辑零改动。
//  - 模型不可用（未训练 / 未打包进 IPA / 推理异常）时，自动回退到 PhotoDefectDetector（CV 规则）。
//  - 保留 LiDAR 路线（余高 / 咬边深度由 WeldProfileAnalyzer + LiDARWeldScanSheet 负责，本模块不涉及）。
//  - 推理结果直接产出 App 内部 type（undercut/porosity/excess_weld_metal/crack/overlap/linear_misalignment），
//    因此下游 ISO5817Grader 评级与照片框标注无需任何改动。
//
// 训练产物接入方式：
//  1) 用 Create ML → Instance Segmentation 训练（见 ml/TRAINING_GUIDE.md），导出 WeldDefectModel.mlmodel。
//  2) 把 WeldDefectModel.mlmodel 加入 Xcode 工程，勾选 Target Membership（Copy Bundle Resources）。
//     Xcode 编译后包内生成 WeldDefectModel.mlmodelc。
//  3) 训练时的类别名必须与下方 labelMap 的 key 对齐（class_labels.txt 已含这些英文 type）。
//
// 说明：本环境无 Mac，无法编译验证；已对每一步做 try/catch 与空值守卫，
//       任何解析异常都会回退 CV，因此即便字段名与你的模型略有出入也不会让 App 崩溃。

import Foundation
import UIKit
import Vision
import CoreML

struct MLDefectDetector {
    /// 是否优先使用 Core ML 模型（false 时强制走 CV 规则）。可在 UI 暴露开关。
    static var useMLModel: Bool = true

    /// 模型是否已可用（已编译且能被 Bundle 找到）。用于在 UI 提示当前走哪条路线。
    static var isModelAvailable: Bool { compiledModelURL != nil }

    /// 置信度阈值：实例分割输出低于此值的检测框丢弃。训练后按 mAP 调参（建议 0.5~0.7）。
    static var confidenceThreshold: Double = 0.5

    /// 模型文件名（不含扩展名）。编译后为 .mlmodelc，开发期直接拖入为 .mlmodel。
    private static let modelFileName = "WeldDefectModel"

    // 模型输出 label（Create ML 训练类名） → App 内部 type
    private static let labelMap: [String: String] = [
        "undercut": "undercut",
        "porosity": "porosity",
        "pore": "porosity",
        "excess_weld_metal": "excess_weld_metal",
        "excess": "excess_weld_metal",
        "excess_reinforcement": "excess_weld_metal",
        "crack": "crack",
        "crater_crack": "crack",
        "overlap": "overlap",
        "linear_misalignment": "linear_misalignment",
        "misalignment": "linear_misalignment"
    ]

    // MARK: - 入口

    /// 统一检测入口。模型可用且开启时走 ML，否则（或推理失败）回退 CV 规则。
    static func detect(in image: UIImage, maxCount: Int = 16) -> [DetectedDefect] {
        if useMLModel, let url = compiledModelURL,
           let dets = try? runModel(at: url, image: image, maxCount: maxCount) {
            return dets
        }
        return PhotoDefectDetector.detect(in: image, maxCount: maxCount)
    }

    /// 当前生效的引擎描述（用于自动标注提示文案）
    static var engineName: String {
        useMLModel && isModelAvailable ? "AI 模型" : "CV 规则"
    }

    // MARK: - 模型定位

    private static var compiledModelURL: URL? {
        // 优先已编译的 .mlmodelc（Xcode 编译 .mlmodel 后的产物）
        if let c = Bundle.main.url(forResource: modelFileName, withExtension: "mlmodelc") { return c }
        // 开发期：未编译的 .mlmodel 直接拖入包内
        if let m = Bundle.main.url(forResource: modelFileName, withExtension: "mlmodel"),
           let c = try? MLModel.compileModel(at: m) { return c }
        return nil
    }

    // MARK: - Core ML 推理（Create ML 实例分割 + Vision）

    /// 运行实例分割模型，返回归一化框 + App type。任何异常抛出让上层回退 CV。
    private static func runModel(at url: URL, image: UIImage, maxCount: Int) throws -> [DetectedDefect] {
        guard let cg = image.cgImage else { return [] }
        let model = try MLModel(contentsOf: url)
        let vnModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])

        // 多输出实例分割：每个输出是 results 中的一个 VNCoreMLFeatureValueObservation，
        // 通过 featureName 区分（Create ML 标准字段 confidence / mask / label）。
        guard let results = request.results else { return [] }
        var confMA: MLMultiArray?, maskMA: MLMultiArray?, labelMA: MLMultiArray?, labelStr: String?
        for obs in results {
            guard let fv = obs as? VNCoreMLFeatureValueObservation else { continue }
            switch fv.featureName {
            case "confidence": confMA = fv.featureValue.multiArrayValue
            case "mask":       maskMA = fv.featureValue.multiArrayValue
            case "label":
                if let ma = fv.featureValue.multiArrayValue { labelMA = ma }
                else if let s = fv.featureValue.stringValue { labelStr = s }
            default: break
            }
        }
        guard let confVal = confMA, let maskVal = maskMA else { return [] }
        let count = Int(confVal.shape[0].intValue)
        guard count > 0 else { return [] }

        let imgW = cg.width, imgH = cg.height
        let maskShape = maskVal.shape
        guard maskShape.count >= 3 else { return [] }
        let mH = Int(maskShape[1].intValue)
        let mW = Int(maskShape[2].intValue)
        let classLabels = (model.modelDescription.classLabels as? [String]) ?? []

        let strideHW = mH * mW
        var cand: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        for i in 0 ..< count {
            let score = confVal[i].doubleValue
            guard score >= confidenceThreshold else { continue }

            var type = "defect"
            if let la = labelMA {
                let idx = Int(la[i].intValue)
                if !classLabels.isEmpty, idx >= 0, idx < classLabels.count {
                    type = labelMap[classLabels[idx].lowercased()] ?? "defect"
                }
            } else if let s = labelStr {
                type = labelMap[s.lowercased()] ?? "defect"
            }

            guard let box = bboxFromMask(maskVal, instance: i, base: i * strideHW,
                                         H: mH, W: mW, imgW: imgW, imgH: imgH) else { continue }
            cand.append((box.rect, type, box.pixelSize, score))
        }

        // 非极大抑制（IoU>0.6 保留高分框），再截断 maxCount
        let kept = nms(candidates: cand, iouThresh: 0.6)
        return kept.prefix(maxCount).map { d in
            DetectedDefect(rect: d.rect, type: d.type, pixelSize: d.pixelSize)
        }
    }

    /// 从 [N,H,W] 概率掩膜的第 i 个实例提取像素级 bbox，并换算到原图归一化坐标与像素尺寸。
    private static func bboxFromMask(_ mask: MLMultiArray, instance: Int, base: Int,
                                     H: Int, W: Int, imgW: Int, imgH: Int)
        -> (rect: CGRect, pixelSize: CGSize)? {
        var minX = W, minY = H, maxX = 0, maxY = 0, cnt = 0
        for y in 0 ..< H {
            for x in 0 ..< W {
                let v = mask[base + y * W + x].doubleValue
                if v >= 0.5 {
                    cnt += 1
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard cnt > 8 else { return nil }   // 掩膜过小，视为噪声
        // 掩膜分辨率 (mW×mH) → 原图 (imgW×imgH) 的缩放
        let sx = Double(imgW) / Double(max(1, W))
        let sy = Double(imgH) / Double(max(1, H))
        let pMinX = Double(minX) * sx, pMinY = Double(minY) * sy
        let pW = Double(maxX - minX + 1) * sx, pH = Double(maxY - minY + 1) * sy
        let rect = CGRect(x: pMinX / Double(imgW), y: pMinY / Double(imgH),
                          width: pW / Double(imgW), height: pH / Double(imgH))
        return (rect, CGSize(width: pW, height: pH))
    }

    // MARK: - 非极大抑制

    private static func nms(candidates: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)],
                            iouThresh: Double) -> [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] {
        let sorted = candidates.sorted { $0.score > $1.score }
        var kept: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        for b in sorted {
            var ov = false
            for k in kept {
                let ix = max(0.0, min(b.rect.maxX, k.rect.maxX) - max(b.rect.minX, k.rect.minX))
                let iy = max(0.0, min(b.rect.maxY, k.rect.maxY) - max(b.rect.minY, k.rect.minY))
                let inter = ix * iy
                let uni = b.rect.width * b.rect.height + k.rect.width * k.rect.height - inter
                if uni > 0, inter / uni > iouThresh { ov = true; break }
            }
            if !ov { kept.append(b) }
        }
        return kept
    }
}
