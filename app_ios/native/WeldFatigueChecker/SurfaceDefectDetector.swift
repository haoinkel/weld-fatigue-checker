// SurfaceDefectDetector.swift
// 表面可见光焊缝缺陷检测（Core ML .mlpackage，WeldDefectSurfaceModel，7 类）。
//
// 与 MLDefectDetector（X 光模型 WeldDefectModel，5 类）完全并行、互不干扰：
//  - 同接口 `detect(in:) -> [DetectedDefect]`，上层「自动标注」逻辑零改动。
//  - 同一套 YOLOv8 nms=False 裸导出解码（4+nc 布局），decodeRawOutput 与 X 光模型逐行一致，
//    仅类表/类阈值/别名表不同。
//  - 模型不可用或未捆绑时，自动回退到 PhotoDefectDetector（CV 规则），与 X 光模型行为一致。
//
// 图源分流（见 MLDefectDetector.activeSource）：
//  - .surface（默认，可见光照片）→ 本检测器
//  - .xray（X 光片）→ MLDefectDetector（X 光模型）
//
// 训练产物（魔搭 ModelScope 导出，ml/modelscope_train_surface.ipynb cell 7）：
//  model.export(format='coreml', nms=False, quantize='w8a16', imgsz=640)
//  → 裸检测头输出 (1, 11, 8400)（4 框坐标 + 7 类分数，分数已 sigmoid）。
//  WeldDefectSurfaceModel.mlpackage 加入 Xcode 工程（Target Membership / Copy Bundle Resources）。
//
// 预处理对齐（重要）：训练用 letterbox（保持比例+灰 114 填充），故推理前先把图
// letterbox 方形化再喂 Vision（方形输入下 .scaleFill 无变形）；模型框坐标经 letterbox
// 逆映射回原图。本地 130 张标注图实测：letterbox 较直接拉伸 overlap 召回 29%→47%、
// unfused 40%→60%（ml/validate_surface_local.py 可复现）。
//
// 7 类顺序（必须与训练 data.yaml names 严格一致，Ultralytics 按索引导出）：
//  ['porosity','crack','overlap','spatters','good_weld','undercut','unfused']
//
// 注意 good_weld（合格焊道，负类）不作为「缺陷」上报：detect 在返回前过滤掉，
// 避免污染 ISO 5817 缺陷列表（它本就不是缺陷）。其余 6 类照常进入缺陷列表与评级流程。

import Foundation
import UIKit
import Vision
import CoreML
import CoreVideo
import simd

struct SurfaceDefectDetector {
    /// 是否优先使用 Core ML 模型（false 时强制走 CV 规则）。与 X 光模型共用 MLDefectDetector.useMLModel 开关。
    /// 读 MLDefectDetector 的全局开关，保证 UI 上「使用 AI 模型识别」一处切换同时控两个模型。
    private static var useMLModel: Bool { MLDefectDetector.useMLModel }

    /// 模型是否已可用（已编译且能被 Bundle 找到）。
    static var isModelAvailable: Bool { compiledModelURL != nil }

    /// 置信度阈值：YOLO 类分数低于此值的检测框丢弃。偏低有利于提升少样本类的召回。
    static var confidenceThreshold: Double = 0.45

    /// 按类分置信度阈值：基于本地 130 张标注图阈值扫描校准（letterbox 预处理，F1 最优点附近、安全类略偏保守）。
    /// spatters F1=0.79(P83%/R75%)；unfused 安全关键保持低阈值保召回；undercut/overlap/crack 弱类放低保召回。
    private static let perClassConfidenceThreshold: [String: Double] = [
        "porosity":  0.30,
        "crack":     0.30,
        "overlap":   0.25,
        "spatters":  0.30,
        "good_weld": 0.40,
        "undercut":  0.25,
        "unfused":   0.20,
    ]

    /// 检测灵敏度（真机诊断用）。与 X 光模型共用 MLDefectDetector.sensitivity 全局档位。
    private static func threshold(for cls: String?) -> Double {
        let base = (cls != nil) ? (perClassConfidenceThreshold[cls!] ?? confidenceThreshold) : confidenceThreshold
        switch MLDefectDetector.sensitivity {
        case .standard: return base
        case .high:     return base * 0.5
        case .max:      return max(0.05, base * 0.2)
        }
    }

    /// 诊断：最近一次 ML 推理中，原始分数最高的若干候选（阈值过滤前）。
    private static let diagLock = NSLock()
    private static var _lastRawScores: [(cls: String, score: Double)] = []
    static var lastRawScores: [(cls: String, score: Double)] {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastRawScores
    }
    static var lastRawScoresText: String {
        let s = lastRawScores.prefix(3)
        guard !s.isEmpty else { return "无任何候选（模型输出全为背景）" }
        return s.map { "\($0.cls) \(String(format: "%.2f", $0.score))" }.joined(separator: " / ")
    }

    private static var _lastLowConf: [(cls: String, score: Double)] = []
    static var lastLowConfScores: [(cls: String, score: Double)] {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastLowConf
    }
    static var lastLowConfText: String {
        let s = lastLowConfScores.sorted { $0.score > $1.score }.prefix(3)
        guard !s.isEmpty else { return "" }
        return s.map { "\($0.cls) \(String(format: "%.2f", $0.score))" }.joined(separator: " / ")
    }

    private static var _lastDroppedBox = 0
    static var lastDroppedBoxCount: Int {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastDroppedBox
    }

    private static var _lastInputSnapshot: UIImage?
    static var lastInputSnapshot: UIImage? {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastInputSnapshot
    }

    private static var _lastUsedML = false
    static var lastUsedML: Bool {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastUsedML
    }

    static var engineName: String {
        useMLModel && isModelAvailable ? "AI 模型" : "CV 规则"
    }

    /// 模型文件名（不含扩展名）。编译后为 .mlmodelc，开发期直接拖入为 .mlpackage。
    private static let modelFileName = "WeldDefectSurfaceModel"

    // 表面模型 7 类（顺序必须与训练 data.yaml names 完全一致）：
    // TARGET_CLASSES = ['porosity','crack','overlap','spatters','good_weld','undercut','unfused']
    // confidence 向量 argmax 索引 i 即对应 classNames[i]。
    private static let classNames = ["porosity", "crack", "overlap", "spatters", "good_weld", "undercut", "unfused"]

    // YOLO 类名 / 同义名 → App 内部 type（下游 ISO5817Grader 直接用 type 评级）。
    private static let labelMap: [String: String] = [
        "porosity":  "porosity",
        "pore":      "porosity",
        "air-hole":  "porosity",
        "crack":     "crack",
        "crater_crack": "crack",
        "overlap":   "overlap",
        "spatters":  "spatters",
        "spatter":   "spatters",
        "good_weld": "good_weld",
        "undercut":  "undercut",
        "bite-edge": "undercut",
        "unfused":   "unfused",
        "lack_of_fusion": "unfused",
    ]

    // MARK: - 入口

    /// 统一检测入口。模型可用且开启时走 ML，否则（或推理失败）回退 CV 规则。
    static func detect(in image: UIImage, maxCount: Int = 16, roi: CGRect? = nil,
                       depth: CVPixelBuffer? = nil, intrinsics: matrix_float3x3? = nil) -> [DetectedDefect] {
        let upright = Self.uprightImage(image)
        let applyROI: ([DetectedDefect]) -> [DetectedDefect] = { list in
            guard let r = roi else { return list }
            return list.filter { r.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        }
        let attachMetric: (DetectedDefect) -> DetectedDefect = { d in
            guard let dm = depth, let k = intrinsics,
                  let m = MetricSizer.fromDepth(rect: d.rect, depth: dm, intrinsics: k) else { return d }
            var out = DetectedDefect(rect: d.rect, type: d.type, pixelSize: d.pixelSize)
            out.metric = m
            return out
        }
        if useMLModel, let url = compiledModelURL {
            let big = upright.size.width > 700 || upright.size.height > 700
            if !big {
                // 小图：单遍 letterbox 推理（ROI 走内部裁剪缩放）
                if let roi, let dets = try? runModel(at: url, image: upright, maxCount: maxCount, roi: roi) {
                    diagLock.lock(); _lastUsedML = true; diagLock.unlock()
                    return applyROI(dets).filter { $0.type != "good_weld" }.map(attachMetric)
                }
                if let dets = try? runModel(at: url, image: upright, maxCount: maxCount, roi: nil) {
                    diagLock.lock(); _lastUsedML = true; diagLock.unlock()
                    return applyROI(dets).filter { $0.type != "good_weld" }.map(attachMetric)
                }
            } else {
                // 大尺寸实拍整图：切片推理（保留原生分辨率），根治整图压 640 漏检
                if let dets = try? runModelTiled(at: url, image: upright, maxCount: maxCount, roi: roi) {
                    diagLock.lock(); _lastUsedML = true; diagLock.unlock()
                    return applyROI(dets).filter { $0.type != "good_weld" }.map(attachMetric)
                }
                // 切片失败回退单遍
                if let dets = try? runModel(at: url, image: upright, maxCount: maxCount, roi: roi) {
                    diagLock.lock(); _lastUsedML = true; diagLock.unlock()
                    return applyROI(dets).filter { $0.type != "good_weld" }.map(attachMetric)
                }
            }
        }
        diagLock.lock(); _lastUsedML = false; diagLock.unlock()
        return applyROI(PhotoDefectDetector.detect(in: upright, maxCount: maxCount)).map(attachMetric)
    }

    /// 把 UIImage 重绘为"方向向上"的位图（消除 EXIF 方向与 CGImage 原始方向的差异）。
    private static func uprightImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 模型定位

    private static var compiledModelURL: URL? {
        if let c = Bundle.main.url(forResource: modelFileName, withExtension: "mlmodelc") { return c }
        if let m = Bundle.main.url(forResource: modelFileName, withExtension: "mlmodel"),
           let c = try? MLModel.compileModel(at: m) { return c }
        return nil
    }

    // MARK: - Core ML 推理（YOLOv8 检测 + Vision）

    private static let modelLock = NSLock()
    private static var _cachedRequest: VNCoreMLRequest?
    private static var _nmsThresholdOverridden = false
    static var nmsThresholdOverridden: Bool {
        modelLock.lock(); defer { modelLock.unlock() }
        return _nmsThresholdOverridden
    }

    private static func cachedRequest(for url: URL) throws -> VNCoreMLRequest {
        modelLock.lock(); defer { modelLock.unlock() }
        if let r = _cachedRequest { return r }
        let cfg = MLModelConfiguration()
        if #available(iOS 16.0, *) {
            cfg.computeUnits = .cpuAndNeuralEngine
        }
        _nmsThresholdOverridden = true
        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: cfg)
        } catch {
            _nmsThresholdOverridden = false
            let plain = MLModelConfiguration()
            if #available(iOS 16.0, *) { plain.computeUnits = .cpuAndNeuralEngine }
            model = try MLModel(contentsOf: url, configuration: plain)
        }
        let vnModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        _cachedRequest = request
        return request
    }

    /// 运行 YOLOv8 检测模型，返回归一化框 + App type。
    private static func runModel(at url: URL, image: UIImage, maxCount: Int, roi: CGRect? = nil) throws -> [DetectedDefect] {
        guard let cgFull = image.cgImage else { return [] }
        let fullW = Double(cgFull.width), fullH = Double(cgFull.height)

        var cropPix: CGRect? = nil
        var sourceCG = cgFull
        if let roi {
            let x0 = max(0.0, roi.minX - roi.width * 0.10)
            let y0 = max(0.0, roi.minY - roi.height * 0.10)
            let x1 = min(1.0, roi.maxX + roi.width * 0.10)
            let y1 = min(1.0, roi.maxY + roi.height * 0.10)
            let pix = CGRect(x: x0 * fullW, y: y0 * fullH,
                             width: (x1 - x0) * fullW, height: (y1 - y0) * fullH)
            guard pix.width >= 24, pix.height >= 24,
                  let cropped = cgFull.cropping(to: pix) else { return [] }
            cropPix = pix
            sourceCG = cropped
        }

        let enhanced = ImagePreprocessor.enhance(sourceCG) ?? sourceCG

        var cg: CGImage = enhanced
        var lbSide = 0.0, lbOffX = 0.0, lbOffY = 0.0, lbCropW = 0.0, lbCropH = 0.0
        // 全图与 ROI 裁剪统一 letterbox 方形化（灰 114 填充、保持比例居中）：
        // 训练用 letterbox，App 原 .scaleFill 直接拉伸非方图会使定位系统性偏移
        // （本地 130 张实测：overlap 召回 29%→47%、unfused 40%→60%）。
        // 方形输入下 .scaleFill 无变形，等价 letterbox，无需改 Vision 选项。
        {
            let cw = enhanced.width, ch = enhanced.height
            let side = max(cw, ch)
            let offX = (side - cw) / 2, offY = (side - ch) / 2
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = true
            let boxed = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { ctx in
                UIColor(red: 114.0 / 255.0, green: 114.0 / 255.0, blue: 114.0 / 255.0, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
                UIImage(cgImage: enhanced).draw(in: CGRect(x: offX, y: offY, width: cw, height: ch))
            }
            if let boxedCG = boxed.cgImage {
                cg = boxedCG
                lbSide = Double(side); lbOffX = Double(offX); lbOffY = Double(offY)
                lbCropW = Double(cw); lbCropH = Double(ch)
            }
        }()

        diagLock.lock(); _lastInputSnapshot = UIImage(cgImage: cg); diagLock.unlock()

        let request = try cachedRequest(for: url)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }

        var out: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        var rawAll: [(cls: String, score: Double)] = []
        var lowConf: [(cls: String, score: Double)] = []
        var droppedBox = 0

        if let raw = rawMultiArray(from: results) {
            (out, rawAll, lowConf, droppedBox) = Self.decodeRawOutput(raw, maxCount: maxCount)
        }

        diagLock.lock()
        _lastRawScores = rawAll.sorted { $0.score > $1.score }.prefix(5).map { $0 }
        _lastLowConf = lowConf.sorted { $0.score > $1.score }.prefix(5).map { $0 }
        _lastDroppedBox = droppedBox
        diagLock.unlock()

        return out.prefix(maxCount).map { d -> DetectedDefect in
            // letterbox 逆映射（全图与 ROI 统一）：模型框（640 空间归一化）→ 源图（裁剪或全图）归一化
            let lx = lbSide > 0 ? (d.rect.minX * lbSide - lbOffX) / lbCropW : d.rect.minX
            let ly = lbSide > 0 ? (d.rect.minY * lbSide - lbOffY) / lbCropH : d.rect.minY
            let lw = lbSide > 0 ? d.rect.width * lbSide / lbCropW : d.rect.width
            let lh = lbSide > 0 ? d.rect.height * lbSide / lbCropH : d.rect.height
            if let pix = cropPix {
                let fx = max(0.0, (pix.minX + lx * pix.width) / fullW)
                let fy = max(0.0, (pix.minY + ly * pix.height) / fullH)
                let fw = min(max(0.0, lw * pix.width / fullW), 1.0 - fx)
                let fh = min(max(0.0, lh * pix.height / fullH), 1.0 - fy)
                return DetectedDefect(rect: CGRect(x: fx, y: fy, width: fw, height: fh),
                                      type: d.type,
                                      pixelSize: CGSize(width: fw * fullW, height: fh * fullH))
            }
            let fx = max(0.0, min(1.0, lx)), fy = max(0.0, min(1.0, ly))
            let fw = max(0.0, min(lw, 1.0 - fx)), fh = max(0.0, min(lh, 1.0 - fy))
            return DetectedDefect(rect: CGRect(x: fx, y: fy, width: fw, height: fh),
                                  type: d.type,
                                  pixelSize: CGSize(width: fw * fullW, height: fh * fullH))
        }
    }

    /// 从 Vision 结果里取出 nms=False 裸导出多头 (1, 4+nc, 8400)。整图/切片推理共用。
    private static func rawMultiArray(from results: [Any]?) -> MLMultiArray? {
        let chCount = 4 + classNames.count
        guard let results else { return nil }
        for obs in results {
            guard let fv = obs as? VNCoreMLFeatureValueObservation,
                  let ma = fv.featureValue.multiArrayValue else { continue }
            let s = ma.shape
            if (s.count == 3 && s[0].intValue == 1 && s[1].intValue == chCount && s[2].intValue > 1000)
                || (s.count == 2 && s[0].intValue == chCount && s[1].intValue > 1000) {
                return ma
            }
        }
        return nil
    }

    /// 大图切片推理：把源图按原生分辨率切成 640×640（步长 512、重叠 128）瓦片，逐片喂模型，
    /// 再跨片 NMS 合并。瓦片内缺陷保持原生 259~430px（与棚拍域同尺度），彻底解决整图压 640 后
    /// 缺陷缩到 ~40px 被忽略的漏检（crop 实验已证：气孔裁剪后 conf 0.76 稳定检出）。
    /// 切图参数与训练脚本 ml/make_raw_mine_tiles.py（step512/overlap128）一致，保证推理↔训练对齐。
    /// 单遍(小图/ROI 缩放)仍走 runModel；本函数专治大尺寸实拍整图。
    private static func runModelTiled(at url: URL, image: UIImage, maxCount: Int, roi: CGRect? = nil) throws -> [DetectedDefect] {
        guard let cgFull = image.cgImage else { return [] }
        let fullW = Double(cgFull.width), fullH = Double(cgFull.height)

        // 有效源区域（ROI 先裁剪放大，否则整图）
        var sourceCG = cgFull
        var regionOrigin = CGPoint(x: 0, y: 0)
        var regionSize = CGSize(width: fullW, height: fullH)
        if let roi {
            let x0 = max(0.0, roi.minX - roi.width * 0.10)
            let y0 = max(0.0, roi.minY - roi.height * 0.10)
            let x1 = min(1.0, roi.maxX + roi.width * 0.10)
            let y1 = min(1.0, roi.maxY + roi.height * 0.10)
            let pix = CGRect(x: x0 * fullW, y: y0 * fullH,
                             width: (x1 - x0) * fullW, height: (y1 - y0) * fullH)
            if let cropped = cgFull.cropping(to: pix) {
                sourceCG = cropped; regionOrigin = CGPoint(x: pix.minX, y: pix.minY)
                regionSize = CGSize(width: pix.width, height: pix.height)
            }
        }
        let enhanced = ImagePreprocessor.enhance(sourceCG) ?? sourceCG
        let srcW = Double(enhanced.width), srcH = Double(enhanced.height)
        let T = 640, S = 512
        diagLock.lock(); _lastInputSnapshot = UIImage(cgImage: enhanced); diagLock.unlock()

        // 区域任一边 < 瓦片尺寸时无法切图（多为用户在大图上画了很小的 ROI），
        // 转单遍 letterbox（runModel 内部已对 ROI 裁剪放大，尺度仍可接受），避免越界返回空导致静默漏检。
        if srcW < Double(T) || srcH < Double(T) {
            return try runModel(at: url, image: image, maxCount: maxCount, roi: roi)
        }

        let cols = max(1, Int(ceil((srcW - Double(T)) / Double(S))) + 1)
        let rows = max(1, Int(ceil((srcH - Double(T)) / Double(S))) + 1)
        let req = try cachedRequest(for: url)
        var all: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        for r in 0 ..< rows {
            for c in 0 ..< cols {
                let ox = min(Double(c * S), srcW - Double(T))
                let oy = min(Double(r * S), srcH - Double(T))
                guard let tileCG = enhanced.cropping(to: CGRect(x: ox, y: oy,
                                                                width: Double(T), height: Double(T))) else { continue }
                let handler = VNImageRequestHandler(cgImage: tileCG, options: [:])
                try handler.perform([req])
                guard let raw = rawMultiArray(from: req.results) else { continue }
                let (out, _, _, _) = Self.decodeRawOutput(raw, maxCount: maxCount)
                for d in out {
                    // d.rect 为瓦片 640 空间归一化 → 瓦片像素 → 源区域像素 → 全图归一化
                    let px0 = ox + d.rect.minX * Double(T)
                    let py0 = oy + d.rect.minY * Double(T)
                    let pw = d.rect.width * Double(T), ph = d.rect.height * Double(T)
                    let rx = px0 / srcW, ry = py0 / srcH
                    let rw = pw / srcW, rh = ph / srcH
                    let fx = regionOrigin.x + rx * regionSize.width
                    let fy = regionOrigin.y + ry * regionSize.height
                    let fw = rw * regionSize.width, fh = rh * regionSize.height
                    let rectFull = CGRect(x: fx / fullW, y: fy / fullH,
                                          width: fw / fullW, height: fh / fullH)
                    all.append((rectFull, d.type, CGSize(width: fw, height: fh), d.score))
                }
            }
        }
        let kept = nms(candidates: all, iouThresh: 0.6)
        return Array(kept.prefix(maxCount))
    }

    // MARK: - 非极大抑制

    private static func matDims(_ ma: MLMultiArray) -> (m: Int, k: Int)? {
        let s = ma.shape
        if s.count == 2 { return (Int(s[0].intValue), Int(s[1].intValue)) }
        if s.count == 3, s[0].intValue == 1 { return (Int(s[1].intValue), Int(s[2].intValue)) }
        return nil
    }

    /// 解码 nms=False 裸导出输出：(1, 4+nc, 8400)。行 0..3 = cx,cy,w,h；行 4..(4+nc) = 各类分数。
    private static func decodeRawOutput(_ ma: MLMultiArray, maxCount: Int)
        -> (out: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)],
            rawAll: [(cls: String, score: Double)],
            lowConf: [(cls: String, score: Double)],
            droppedBox: Int) {
        let nc = classNames.count
        let anchors = ma.shape.last?.intValue ?? 0
        let strides = ma.strides
        let stCh = strides.count >= 2 ? strides[strides.count - 2].intValue : anchors
        let stAn = strides.count >= 1 ? strides[strides.count - 1].intValue : 1
        let side = 640.0

        var rawAll: [(cls: String, score: Double)] = []
        var lowConf: [(cls: String, score: Double)] = []
        var cands: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        var droppedBox = 0

        for a in 0 ..< anchors {
            var best = -1, bestScore = 0.0
            for c in 0 ..< nc {
                let s = ma[(4 + c) * stCh + a * stAn].doubleValue
                if s > bestScore { bestScore = s; best = c }
            }
            guard best >= 0, bestScore > 0.01, bestScore.isFinite else { continue }
            let clsName = classNames[best]
            rawAll.append((clsName, bestScore))

            let cx = ma[0 * stCh + a * stAn].doubleValue / side
            let cy = ma[1 * stCh + a * stAn].doubleValue / side
            let w  = ma[2 * stCh + a * stAn].doubleValue / side
            let h  = ma[3 * stCh + a * stAn].doubleValue / side
            guard w.isFinite, h.isFinite, cx.isFinite, cy.isFinite else { droppedBox += 1; continue }

            let x = cx - w / 2, y = cy - h / 2
            let minX = max(0.0, min(1.0, x)), minY = max(0.0, min(1.0, y))
            let maxX = max(0.0, min(1.0, x + w)), maxY = max(0.0, min(1.0, y + h))
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard rect.width > 0, rect.height > 0 else { droppedBox += 1; continue }

            if bestScore >= threshold(for: clsName) {
                let type = labelMap[clsName] ?? clsName
                cands.append((rect, type, CGSize(width: w * side, height: h * side), bestScore))
            } else if bestScore >= 0.05 {
                lowConf.append((clsName, bestScore))
            }
        }

        let kept = Array(nms(candidates: cands, iouThresh: 0.6).prefix(maxCount))
        return (kept,
                rawAll.sorted { $0.score > $1.score },
                lowConf.sorted { $0.score > $1.score },
                droppedBox)
    }

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
