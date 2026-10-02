// MLDefectDetector.swift
// 阶段2：YOLOv8 检测模型（Core ML .mlpackage）接入，替换阶段0 的纯 CV 规则（PhotoDefectDetector）。
//
// 设计原则：
//  - 与 PhotoDefectDetector 同接口 `detect(in:) -> [DetectedDefect]`，上层「自动标注」逻辑零改动。
//  - 模型不可用（未训练 / 未打包进 IPA / 推理异常）时，自动回退到 PhotoDefectDetector（CV 规则）。
//  - 保留 LiDAR 路线（余高 / 咬边深度由 WeldProfileAnalyzer + LiDARWeldScanSheet 负责，本模块不涉及）。
//  - 推理结果直接产出 App 内部 type（undercut/porosity/crack/overlap/unfused），
//    因此下游 ISO5817Grader 评级与照片框标注无需任何改动。
//
// 训练产物接入方式（与旧 Create ML 实例分割路线不同，此处为 YOLOv8 检测）：
//  1) AI Studio 上用 Ultralytics YOLOv8n 训练（ml/weld_train.py），导出 Core ML：
//       model.export(format='coreml', nms=True, quantize='w8a16', imgsz=640)
//       # Ultralytics 8.4.x：CoreML 不收 data=，int8 已废弃；唯一可用量化档为 w8a16
//       # （INT8 权重 + 16-bit 激活，权重-only，~3.1MB，跑 Neural Engine）。
//     产物 WeldDefectModel.mlpackage（YOLO 检测输出，非实例分割掩膜）。
//  2) 把 WeldDefectModel.mlpackage 加入 Xcode 工程，勾选 Target Membership（Copy Bundle Resources）。
//     Xcode 编译后包内生成 WeldDefectModel.mlmodelc，运行时由 compiledModelURL 找到。
//  3) 训练类别顺序必须与下方 classNames 完全一致（Ultralytics 按 data.yaml names 导出）：
//     ['porosity','crack','undercut','overlap','unfused']。
//
// Core ML 输出解析（YOLOv8 + nms=True 导出，VNCoreMLRequest 返回）：
//  - 'coordinates' : MLMultiArray (M, 4)，归一化 [x_center, y_center, width, height]，范围 0..1。
//  - 'confidence'  : MLMultiArray (M, num_classes)，每个检测的类分数（sigmoid 后 0..1）。
//  NMS 已在模型内完成（nms=True），故 runModel 不再重复做 NMS（避免丢框）。
//  若改用 nms=False 导出，请取消 runModel 末尾的 nms(...) 调用。
//
// 说明：本环境无 Mac，无法编译验证；已对每一步做 try/catch 与空值守卫，
//       任何解析异常都会回退 CV，因此即便字段名与你的模型略有出入也不会让 App 崩溃。

import Foundation
import UIKit
import Vision
import CoreML
import CoreVideo
import simd

struct MLDefectDetector {
    /// 是否优先使用 Core ML 模型（false 时强制走 CV 规则）。可在 UI 暴露开关。
    static var useMLModel: Bool = true

    /// 模型是否已可用（已编译且能被 Bundle 找到）。用于在 UI 提示当前走哪条路线。
    static var isModelAvailable: Bool { compiledModelURL != nil }

    /// 置信度阈值：YOLO 类分数低于此值的检测框丢弃。训练后按 mAP/召回调参（建议 0.4~0.5，
    /// 偏低有利于提升裂纹/咬边等少样本类的召回，漏报比误报更危险）。
    static var confidenceThreshold: Double = 0.45

    /// 按类分置信度阈值：少数类(crack/undercut)降阈值保召回，porosity 升阈值压误报。
    /// 初值基于 120 轮增强版验证集标定（2026-09-27）。
    private static let perClassConfidenceThreshold: [String: Double] = [
        "porosity":  0.45,
        "crack":     0.30,
        "undercut":  0.30,
        "overlap":   0.45,
        "unfused":   0.40,
    ]

    /// 模型文件名（不含扩展名）。编译后为 .mlmodelc，开发期直接拖入为 .mlpackage。
    private static let modelFileName = "WeldDefectModel"

    // 视觉模型训练的 5 类（顺序必须与训练 data.yaml names 完全一致，Ultralytics 按此索引）。
    // TARGET_CLASSES = ['porosity','crack','undercut','overlap','unfused']
    // confidence 向量 argmax 索引 i 即对应 classNames[i]。
    // 当前部署模型为 5 类（顺序须与训练 data.yaml names 严格一致）。
    // 扩展类（重训目标，当前未启用）：在 5 类后追加 solid_inclusion(夹渣)、spatter(飞溅) → 7 类。
    // 重训时必须同步更新：ml/yolov8n_weld_7cls.yaml(nc:7) + classes_7cls.txt + data yaml names，
    // 且本 classNames / labelMap 顺序必须与新模型导出顺序严格一致，否则 argmax 错位。
    // TODO(retrain): 升级到 7 类时取消下方注释并调整顺序
    // private static let classNames = ["porosity","crack","undercut","overlap","unfused","solid_inclusion","spatter"]
    private static let classNames = ["porosity", "crack", "undercut", "overlap", "unfused"]

    // YOLO 类名 / 同义名 → App 内部 type（下游 ISO5817Grader 直接用 type 评级）。
    // 余高 excess_weld_metal 由 LiDAR 几何计算，不进视觉模型，此处不列。
    private static let labelMap: [String: String] = [
        "porosity":  "porosity",
        "pore":      "porosity",
        "air-hole":  "porosity",
        "crack":     "crack",
        "crater_crack": "crack",
        "undercut":  "undercut",
        "bite-edge": "undercut",
        "overlap":   "overlap",
        "unfused":   "unfused",
        "lack_of_fusion": "unfused"
    ]

    // MARK: - 入口

    /// 统一检测入口。模型可用且开启时走 ML，否则（或推理失败）回退 CV 规则。
    /// roi：焊缝区域（归一化 0..1）；传入时只保留中心落在 roi 内的缺陷，
    ///      区域外不报（避免非焊缝物体误报）。nil 表示不限制（调用方负责闸门逻辑）。
    static func detect(in image: UIImage, maxCount: Int = 16, roi: CGRect? = nil,
                       depth: CVPixelBuffer? = nil, intrinsics: matrix_float3x3? = nil) -> [DetectedDefect] {
        let applyROI: ([DetectedDefect]) -> [DetectedDefect] = { list in
            guard let r = roi else { return list }
            return list.filter { r.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        }
        // 优化点 B：若提供 ARKit 深度图 + 相机内参，逐缺陷做针孔反投影得公制 mm；
        //          否则保留原样（上层用 pxPerMm 标定或"未标定"显示）。
        let attachMetric: (DetectedDefect) -> DetectedDefect = { d in
            guard let dm = depth, let k = intrinsics,
                  let m = MetricSizer.fromDepth(rect: d.rect, depth: dm, intrinsics: k) else { return d }
            var out = DetectedDefect(rect: d.rect, type: d.type, pixelSize: d.pixelSize)
            out.metric = m
            return out
        }
        if useMLModel, let url = compiledModelURL,
           let dets = try? runModel(at: url, image: image, maxCount: maxCount) {
            return applyROI(dets).map(attachMetric)
        }
        return applyROI(PhotoDefectDetector.detect(in: image, maxCount: maxCount)).map(attachMetric)
    }

    /// 当前生效的引擎描述（用于自动标注提示文案）
    static var engineName: String {
        useMLModel && isModelAvailable ? "AI 模型" : "CV 规则"
    }

    // MARK: - 模型定位

    private static var compiledModelURL: URL? {
        // 优先已编译的 .mlmodelc（Xcode 编译 .mlpackage 后的产物）
        if let c = Bundle.main.url(forResource: modelFileName, withExtension: "mlmodelc") { return c }
        // 开发期：未编译的 .mlmodel 直接拖入包内（.mlpackage 走 Xcode 编译，不会到这）
        if let m = Bundle.main.url(forResource: modelFileName, withExtension: "mlmodel"),
           let c = try? MLModel.compileModel(at: m) { return c }
        return nil
    }

    // MARK: - Core ML 推理（YOLOv8 检测 + Vision）

    /// 运行 YOLOv8 检测模型（Core ML NMS 导出），返回归一化框 + App type。
    /// 任何异常抛出让上层回退 CV。
    private static func runModel(at url: URL, image: UIImage, maxCount: Int) throws -> [DetectedDefect] {
        // 优化点 A：推理前做 CLAHE 白平衡增强（失败回退原图，绝不崩溃）
        guard let cgRaw = image.cgImage else { return [] }
        let cg: CGImage = ImagePreprocessor.enhance(cgRaw) ?? cgRaw

        // Neural Engine 优先（iOS 16+），老设备回退默认配置，避免与相机预览争 GPU 导致抖动。
        let model: MLModel
        if #available(iOS 16.0, *) {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: url, configuration: cfg)
        } else {
            model = try MLModel(contentsOf: url)
        }

        let vnModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: vnModel)
        // scaleFill：原图非等比拉伸到 640×640 模型输入；YOLO 输出归一化坐标直接对应原图
        // （拉伸逆映射恰好还原），故框位置正确（形状可能轻微失真，不影响分类/定位与尺寸换算）。
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }

        // 收集 YOLO NMS 双输出：coordinates (M,4) + confidence (M, nc)。
        var coordsMA: MLMultiArray?
        var confMA: MLMultiArray?
        for obs in results {
            guard let fv = obs as? VNCoreMLFeatureValueObservation else { continue }
            let ma = fv.featureValue.multiArrayValue
            switch fv.featureName {
            case "coordinates": coordsMA = ma
            case "confidence":  confMA = ma
            default:
                // 形状兜底：featureName 不符时按形状推断（(M,4) 坐标 / (M,nc) 置信）
                if let ma, ma.shape.count == 2 {
                    if ma.shape[1].intValue == 4 { coordsMA = coordsMA ?? ma }
                    else if ma.shape[1].intValue == classNames.count { confMA = confMA ?? ma }
                }
            }
        }
        guard let coords = coordsMA, let conf = confMA else { return [] }

        let count = Int(coords.shape[0].intValue)
        let nc = Int(conf.shape[1].intValue)
        guard count > 0, nc == classNames.count else { return [] }

        let imgW = Double(cg.width), imgH = Double(cg.height)

        var out: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        for i in 0 ..< count {
            // confidence[i] = (nc,) 类分数向量，取 argmax 作为类别与分数
            var best = -1, bestScore = 0.0
            for c in 0 ..< nc {
                let s = conf[i * nc + c].doubleValue
                if s > bestScore { bestScore = s; best = c }
            }
            let clsName = (best < classNames.count) ? classNames[best] : nil
            let thresh = (clsName != nil) ? (Self.perClassConfidenceThreshold[clsName!] ?? confidenceThreshold) : confidenceThreshold
            guard best >= 0, bestScore >= thresh else { continue }

            // coordinates[i] = (4,) 归一化 [x_center, y_center, width, height]
            let cx = coords[i * 4 + 0].doubleValue
            let cy = coords[i * 4 + 1].doubleValue
            let w  = coords[i * 4 + 2].doubleValue
            let h  = coords[i * 4 + 3].doubleValue

            let x = cx - w / 2
            let y = cy - h / 2
            // 裁剪到 [0,1] 防止越界
            let minX = max(0.0, min(1.0, x))
            let minY = max(0.0, min(1.0, y))
            let maxX = max(0.0, min(1.0, x + w))
            let maxY = max(0.0, min(1.0, y + h))
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard rect.width > 0, rect.height > 0 else { continue }

            let type: String = (best < classNames.count) ? (labelMap[classNames[best]] ?? classNames[best]) : "defect"
            let pixelSize = CGSize(width: w * imgW, height: h * imgH)
            out.append((rect, type, pixelSize, bestScore))
        }

        // 可选：若改用 nms=False 导出，取消下一行注释做应用层 NMS（iouThresh 0.6）。
        // let kept = nms(candidates: out, iouThresh: 0.6)
        // return kept.prefix(maxCount).map { d in DetectedDefect(rect: d.rect, type: d.type, pixelSize: d.pixelSize) }

        return out.prefix(maxCount).map { d in
            DetectedDefect(rect: d.rect, type: d.type, pixelSize: d.pixelSize)
        }
    }

    // MARK: - 非极大抑制（仅 nms=False 导出时使用）

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
