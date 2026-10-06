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
//       model.export(format='coreml', nms=False, imgsz=640)
//       # nms=False：导出裸检测头输出 (1, 9, 8400)（4 框坐标 + 5 类分数，分数已 sigmoid）。
//       # 关键：mlprogram + IOSDetectModel + 内嵌 NMS 的 pipeline 导出在真机输出异常
//       # （同输入 ONNX Top 0.45~0.78 而 CoreML 全零），故改为裸导出 + App 端解码 + NMS（见 decodeRawOutput）。
//     产物 WeldDefectModel.mlpackage（YOLO 检测输出，非实例分割掩膜）。
//  2) 把 WeldDefectModel.mlpackage 加入 Xcode 工程，勾选 Target Membership（Copy Bundle Resources）。
//     Xcode 编译后包内生成 WeldDefectModel.mlmodelc，运行时由 compiledModelURL 找到。
//  3) 训练类别顺序必须与下方 classNames 完全一致（Ultralytics 按 data.yaml names 导出）：
//     ['porosity','crack','undercut','overlap','unfused']。
//
// Core ML 输出解析（当前部署 = YOLOv8 + nms=False 裸导出，VNCoreMLRequest 返回）：
//  - 单一特征输出 MLMultiArray，形状 (1, 9, 8400) 或 (9, 8400)：
//      行 0..3 = cx,cy,w,h（模型输入 640 像素单位，归一化 = /640）；
//      行 4..8 = 各类分数（模型内已 sigmoid，0..1）。
//  NMS 不在模型内（nms=False），由 decodeRawOutput 内 App 端 NMS（iou 0.6）完成。
//  兼容保留：若模型为 nms=True pipeline 双输出（coordinates + confidence），走路径 B 兜底。
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

    /// 检测图源（按物理输入类型分流）：
    ///  - .surface（可见光照片）→ 表面模型 WeldDefectSurfaceModel（7 类，iPad 相机/相册主用）
    ///  - .xray（X 光片）→ X 光模型 WeldDefectModel（5 类，旧管线）
    /// PhotoCheckView 提供「检测图源」切换；默认 .surface 以匹配可见光输入。
    enum Source: Int {
        case xray = 0
        case surface = 1
    }
    static var activeSource: Source = .surface

    /// 模型是否已可用（已编译且能被 Bundle 找到）。随 activeSource 反映对应模型。
    static var isModelAvailable: Bool {
        activeSource == .surface ? SurfaceDefectDetector.isModelAvailable : (compiledModelURL != nil)
    }

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

    /// 检测灵敏度（真机诊断用）：现场照片与训练集分布差异大时原始分数偏低，
    /// 可降阈值先看召回。standard=按标定阈值；high=×0.5；max=×0.2（下限 0.05）。
    enum Sensitivity: Int {
        case standard = 0, high, max
        var label: String {
            switch self {
            case .standard: return "标准"
            case .high:     return "灵敏"
            case .max:      return "极灵敏"
            }
        }
    }
    static var sensitivity: Sensitivity = .standard

    private static func threshold(for cls: String?) -> Double {
        let base = (cls != nil) ? (perClassConfidenceThreshold[cls!] ?? confidenceThreshold) : confidenceThreshold
        switch sensitivity {
        case .standard: return base
        case .high:     return base * 0.5
        case .max:      return max(0.05, base * 0.2)
        }
    }

    /// 诊断：最近一次 ML 推理中，原始分数最高的若干候选（阈值过滤前）。
    /// 空结果时上层把它展示出来 —— 区分「模型完全没看到」vs「分数低被阈值卡住」。
    /// （多线程访问加锁；仅诊断用途。）
    private static let diagLock = NSLock()
    static var _lastRawScores: [(cls: String, score: Double)] = []
    static var lastRawScores: [(cls: String, score: Double)] {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastRawScores
    }
    static var lastRawScoresText: String {
        let s = lastRawScores.prefix(3)
        guard !s.isEmpty else { return "无任何候选（模型输出全为背景）" }
        return s.map { "\($0.cls) \(String(format: "%.2f", $0.score))" }.joined(separator: " / ")
    }

    /// 诊断：最近一次推理中"分数≥0.05 但低于当前档阈值"的候选（低分疑似）。
    /// 0 检出时上层展示 —— 让用户看到模型"隐约看到了什么"，切到极灵敏即可显示这些候选框。
    static var _lastLowConf: [(cls: String, score: Double)] = []
    static var lastLowConfScores: [(cls: String, score: Double)] {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastLowConf
    }
    static var lastLowConfText: String {
        let s = lastLowConfScores.sorted { $0.score > $1.score }.prefix(3)
        guard !s.isEmpty else { return "" }
        return s.map { "\($0.cls) \(String(format: "%.2f", $0.score))" }.joined(separator: " / ")
    }

    /// 诊断：最近一次推理中"分数达标但输出框无效（宽/高≤0 或 NaN）"而被丢弃的候选数。
    /// 出现 >0 说明模型对该输入的坐标输出异常（域外输入的典型表现）——
    /// 这解释了「Top 分数看着够高（如 0.2 > 极灵敏阈值 0.09）却 0 检出」的矛盾：
    /// 分数过了阈值，框坐标无效，在 rect 守卫处被静默丢弃。
    static var _lastDroppedBox = 0
    static var lastDroppedBoxCount: Int {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastDroppedBox
    }

    /// 诊断：最近一次推理实际送入模型的输入图（ROI 聚焦时=裁剪+letterbox+CLAHE 后）。
    /// 上层展示缩略图，让用户直接核查"模型看到的是什么"（框错位/裁剪区错误一目了然）。
    static var _lastInputSnapshot: UIImage?
    static var lastInputSnapshot: UIImage? {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastInputSnapshot
    }

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
        // 图源分流：可见光照片 → 表面模型；X 光片 → 本（X 光）模型。
        // SurfaceDefectDetector 的诊断值随后同步到本结构体，使读取 MLDefectDetector.* 的 UI 无需改动。
        if activeSource == .surface {
            let dets = SurfaceDefectDetector.detect(in: image, maxCount: maxCount, roi: roi, depth: depth, intrinsics: intrinsics)
            syncSurfaceDiagnostics()
            return dets
        }
        // 方向归一（问题2 伴生修复）：VNImageRequestHandler 只认 CGImage 原始像素方向，
        // 而 UI 侧（照片画布 / 框选 ROI / bbox 叠层 / 标定）全部按 UIImage.orientation
        // 转正后的方向绘制。带 EXIF 方向的照片（相机竖拍/相册导入）不转正时，
        // 推理坐标与显示坐标相差一个旋转 → 框错位、ROI 过滤全错。
        let upright = Self.uprightImage(image)
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
        if useMLModel, let url = compiledModelURL {
            // ROI 聚焦推理（问题2 治本，2026-10-03）：训练集全部为"焊道特写"图，
            // 而照片页是 12MP 全场景照片 scaleFill 到 640×640 —— 缺陷在模型输入里只占
            // 极小像素且内容被压扁，分数普遍低于阈值，表现为"明显焊瘤也检不出"。
            // 改为把用户框选的 ROI 裁剪出来（外扩 10% 上下文）单独送模型：
            // 输入分布对齐训练集"特写"，缺陷在 640 输入中的占比提升一个量级。
            // runModel 内部已把框坐标映射回全图归一化坐标，故无需再按 ROI 过滤。
            if let roi, let dets = try? runModel(at: url, image: upright, maxCount: maxCount, roi: roi) {
                diagLock.lock(); _lastUsedML = true; diagLock.unlock()
                return dets.map(attachMetric)
            }
            if let dets = try? runModel(at: url, image: upright, maxCount: maxCount, roi: nil) {
                diagLock.lock(); _lastUsedML = true; diagLock.unlock()
                return applyROI(dets).map(attachMetric)
            }
        }
        diagLock.lock(); _lastUsedML = false; diagLock.unlock()
        return applyROI(PhotoDefectDetector.detect(in: upright, maxCount: maxCount)).map(attachMetric)
    }

    /// 把 UIImage 重绘为"方向向上"的位图（消除 EXIF 方向与 CGImage 原始方向的差异）。
    /// 已是 .up 时原样返回，零开销。
    private static func uprightImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1            // 位图像素 == image.size（与画布/标定的坐标基准一致）
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 诊断：最近一次 detect 实际使用的引擎（true=Core ML 成功推理；false=回退 CV 规则）。
    static var _lastUsedML = false
    static var lastUsedML: Bool {
        diagLock.lock(); defer { diagLock.unlock() }
        return _lastUsedML
    }

    /// 当 activeSource==.surface 时，把 SurfaceDefectDetector 的诊断值同步到本结构体，
    /// 使读取 MLDefectDetector.* 诊断的 UI（PhotoCheckView 等）无需改动。
    private static func syncSurfaceDiagnostics() {
        _lastRawScores = SurfaceDefectDetector.lastRawScores
        _lastLowConf = SurfaceDefectDetector.lastLowConfScores
        _lastDroppedBox = SurfaceDefectDetector.lastDroppedBoxCount
        _lastInputSnapshot = SurfaceDefectDetector.lastInputSnapshot
        _lastUsedML = SurfaceDefectDetector.lastUsedML
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

    /// 模型与请求缓存：MLModel(contentsOf:) 每次重新编译加载非常重（真机可感知卡顿），
    /// 进程内只加载一次。锁保护（照片页主线程 / 实时扫描相机队列并发调用）。
    private static let modelLock = NSLock()
    private static var _cachedRequest: VNCoreMLRequest?
    /// 模型内嵌 NMS 阈值(0.25)是否已被覆盖为 0.05（诊断展示用）
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
            // Neural Engine 优先（iOS 16+），避免与相机预览争 GPU 导致抖动
            cfg.computeUnits = .cpuAndNeuralEngine
        }
        // 关键：模型内嵌 NMS 的 confidenceThreshold 出厂默认 0.25。
        // 不覆盖时，原始分数 <0.25 的框在模型内部就被丢弃 —— 域外照片（暗光/粉笔字/角焊缝）
        // 分数普遍 <0.25 → 模型输出 0 框 → App 端"永远检不出"。
        // 已通过修改模型 spec（Data/com.apple.CoreML/model.mlmodel 二进制 protobuf）将该默认值
        // 永久改为 0.05：Xcode 26.6 SDK 的 MLParameterKey 既无 confidenceThreshold 静态成员、
        // 也无公开字符串初始化器（仅 init(coder:)），运行时覆盖编译不过，故改为模型内建、
        // 由 Xcode 编译 .mlmodel 时原样采用，跨版本稳定。真正的分级过滤交给 App 端
        // threshold(for:)（灵敏度可调）。
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
        // scaleFill：原图非等比拉伸到 640×640 模型输入；YOLO 输出归一化坐标直接对应原图
        // （拉伸逆映射恰好还原），故框位置正确（形状可能轻微失真，不影响分类/定位与尺寸换算）。
        request.imageCropAndScaleOption = .scaleFill
        _cachedRequest = request
        return request
    }

    /// 运行 YOLOv8 检测模型（Core ML NMS 导出），返回归一化框 + App type。
    /// roi 非 nil 时走"ROI 聚焦"路径：只对 ROI 裁剪区（外扩 10% 上下文）推理，
    /// 并把框坐标映射回全图归一化坐标（pixelSize 亦按全图像素计）。
    /// 任何异常抛出让上层回退 CV。
    private static func runModel(at url: URL, image: UIImage, maxCount: Int, roi: CGRect? = nil) throws -> [DetectedDefect] {
        guard let cgFull = image.cgImage else { return [] }
        let fullW = Double(cgFull.width), fullH = Double(cgFull.height)

        // ROI 聚焦裁剪（问题2 治本）：见 detect() 注释。外扩 10% 给模型留焊道边界上下文
        // （咬边等缺陷正好位于焊道边缘），外扩区检出的框同样映射回全图参与展示。
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

        // 优化点 A（默认关闭，见 ImagePreprocessor.isEnabled 注释）：CLAHE 与训练分布
        // 不符（训练无此步），真机实验证实会诱发满图气孔误报。enhance 返回 nil 时回退原图。
        // 增强作用在（裁剪后的）小图上——与 ImagePreprocessor 注释
        // "处理对象为 ROI 裁剪后的小图"的本意一致，逐像素开销可忽略。
        let enhanced = ImagePreprocessor.enhance(sourceCG) ?? sourceCG

        // ROI 裁剪路径：把（增强后的）裁剪图 letterbox 到正方形再送模型。
        // 依据：训练期 Ultralytics 默认 letterbox 预处理（保持长宽比 + 114 灰边），
        // 此前 scaleFill 把细长 ROI（如 1:2.5）强行拉伸成正方形，形态失真会压低分数；
        // letterbox 让推理输入分布对齐训练分布。
        var cg: CGImage = enhanced
        var lbSide = 0.0, lbOffX = 0.0, lbOffY = 0.0, lbCropW = 0.0, lbCropH = 0.0
        if cropPix != nil {
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
        }

        // 诊断快照：记录"模型实际看到的输入"
        diagLock.lock(); _lastInputSnapshot = UIImage(cgImage: cg); diagLock.unlock()

        let request = try cachedRequest(for: url)

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }

        // 结果/诊断容器：两条解析路径共用
        var out: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        var rawAll: [(cls: String, score: Double)] = []
        var lowConf: [(cls: String, score: Double)] = []
        var droppedBox = 0   // 诊断：分数达标但框无效（退化/NaN）被丢弃的候选数

        // —— 路径 A（当前部署）：裸输出 (1, 4+nc, 8400)，nms=False 导出 ——
        // 2026-10-04：内嵌 NMS pipeline 导出（mlprogram + IOSDetectModel）真机输出异常：
        // 同一输入本地 ONNX Top 分数 0.45~0.78，CoreML pipeline 版却无任何候选，且无 Mac
        // 环境无法调试其内部排布。改用 nms=False 裸导出：张量布局与 ONNX 完全一致
        // （行 0..3 = cx,cy,w,h @640px；行 4..8 = 各类 sigmoid 分数），解码+阈值+NMS 全部
        // 在 App 端完成，算法已用本地 ONNX 等价验证（气孔 0.476 / 未熔合 0.771 正确命中）。
        let chCount = 4 + classNames.count
        var rawMA: MLMultiArray? = nil
        for obs in results {
            guard let fv = obs as? VNCoreMLFeatureValueObservation,
                  let ma = fv.featureValue.multiArrayValue else { continue }
            let s = ma.shape
            // (1, 9, 8400) 或 (9, 8400)：末维>1000 区别于 pipeline 的 confidence (M,5)
            if (s.count == 3 && s[0].intValue == 1 && s[1].intValue == chCount && s[2].intValue > 1000)
                || (s.count == 2 && s[0].intValue == chCount && s[1].intValue > 1000) {
                rawMA = ma
                break
            }
        }
        if let raw = rawMA {
            (out, rawAll, lowConf, droppedBox) = Self.decodeRawOutput(raw, maxCount: maxCount)
        }

        if rawMA == nil {
        // —— 路径 B（兼容保留）：NMS pipeline 双输出 coordinates (M,4) + confidence (M,nc) ——
        // 兼容带 batch 维的导出（(1,M,4)/(1,M,nc)）—— 旧实现按 shape[0]=M/shape[1]=nc 读取，
        // 遇 batch 维时 count=1、nc=M ≠ 类别数 → 静默返回空，真机表现即"永远检不出"。
        var coordsMA: MLMultiArray?
        var confMA: MLMultiArray?
        for obs in results {
            guard let fv = obs as? VNCoreMLFeatureValueObservation else { continue }
            let ma = fv.featureValue.multiArrayValue
            switch fv.featureName {
            case "coordinates": coordsMA = ma
            case "confidence":  confMA = ma
            default:
                // 形状兜底：featureName 不符时按形状推断（最后一维 4=坐标 / =nc=置信）
                if let ma, let d = Self.matDims(ma) {
                    if d.k == 4 { coordsMA = coordsMA ?? ma }
                    else if d.k == classNames.count { confMA = confMA ?? ma }
                }
            }
        }
        guard let coords = coordsMA, let conf = confMA,
              let cd = Self.matDims(coords), cd.k == 4,
              let fd = Self.matDims(conf) else { return [] }

        let count = cd.m
        // 置信度列数：严格等于类别数；或为类别数+1（个别导出会附加背景列，取末列忽略）
        var nc = fd.k
        let confOffset = 0
        if nc == classNames.count + 1 {
            nc = classNames.count   // 背景列在末尾（Ultralytics v5 风格），忽略
        }
        guard count > 0, nc == classNames.count, fd.m == count else { return [] }

        let imgW = Double(cg.width), imgH = Double(cg.height)

        for i in 0 ..< count {
            // confidence[i] = (nc,) 类分数向量，取 argmax 作为类别与分数
            var best = -1, bestScore = 0.0
            for c in 0 ..< nc {
                let s = conf[confOffset + i * fd.k + c].doubleValue
                if s > bestScore { bestScore = s; best = c }
            }
            let clsName = (best >= 0 && best < classNames.count) ? classNames[best] : nil
            if let clsName, bestScore > 0.01 {
                rawAll.append((clsName, bestScore))   // 诊断：阈值过滤前的原始候选
            }
            let passed = best >= 0 && bestScore >= threshold(for: clsName)
            if !passed, let clsName, bestScore >= 0.05 {
                lowConf.append((clsName, bestScore))  // 诊断：低分疑似（≥0.05、低于当前档阈值）
            }
            guard passed else { continue }

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
            guard rect.width > 0, rect.height > 0 else { droppedBox += 1; continue }

            let type: String = (best < classNames.count) ? (labelMap[classNames[best]] ?? classNames[best]) : "defect"
            let pixelSize = CGSize(width: w * imgW, height: h * imgH)
            out.append((rect, type, pixelSize, bestScore))
        }
        }   // 路径 B（NMS pipeline 兼容）结束

        // 应用层 NMS 已由路径 A decodeRawOutput 内置（iou 0.6）；路径 B 依赖模型内嵌 NMS。

        // 记录诊断（阈值过滤前的原始 Top 候选 + 低分疑似，降序取前 5）
        diagLock.lock()
        _lastRawScores = rawAll.sorted { $0.score > $1.score }.prefix(5).map { $0 }
        _lastLowConf = lowConf.sorted { $0.score > $1.score }.prefix(5).map { $0 }
        _lastDroppedBox = droppedBox
        diagLock.unlock()

        // crop 路径：把"letterbox 内归一化框"→"crop 归一化框"→"全图归一化框"，pixelSize 用全图像素
        // （letterbox 绘制失败的兜底：lbSide==0 时框坐标本就是 crop 归一化，直接映射）
        return out.prefix(maxCount).map { d -> DetectedDefect in
            if let pix = cropPix {
                let lx = lbSide > 0 ? (d.rect.minX * lbSide - lbOffX) / lbCropW : d.rect.minX
                let ly = lbSide > 0 ? (d.rect.minY * lbSide - lbOffY) / lbCropH : d.rect.minY
                let lw = lbSide > 0 ? d.rect.width * lbSide / lbCropW : d.rect.width
                let lh = lbSide > 0 ? d.rect.height * lbSide / lbCropH : d.rect.height
                // crop 归一化 → 全图归一化（越界裁剪到 [0,1]）
                let fx = max(0.0, (pix.minX + lx * pix.width) / fullW)
                let fy = max(0.0, (pix.minY + ly * pix.height) / fullH)
                let fw = min(max(0.0, lw * pix.width / fullW), 1.0 - fx)
                let fh = min(max(0.0, lh * pix.height / fullH), 1.0 - fy)
                return DetectedDefect(rect: CGRect(x: fx, y: fy, width: fw, height: fh),
                                      type: d.type,
                                      pixelSize: CGSize(width: fw * fullW, height: fh * fullH))
            }
            return DetectedDefect(rect: d.rect, type: d.type, pixelSize: d.pixelSize)
        }
    }

    // MARK: - 非极大抑制（仅 nms=False 导出时使用）

    /// 输出形状归一化：(M,k) 或带 batch 维的 (1,M,k) → (行数 m, 列数 k)；其余布局返回 nil。
    /// 假设默认连续内存布局（Core ML 输出均为默认 stride，batch=1 时行偏移恰为 i*k+j）。
    private static func matDims(_ ma: MLMultiArray) -> (m: Int, k: Int)? {
        let s = ma.shape
        if s.count == 2 { return (Int(s[0].intValue), Int(s[1].intValue)) }
        if s.count == 3, s[0].intValue == 1 { return (Int(s[1].intValue), Int(s[2].intValue)) }
        return nil
    }

    /// 解码 nms=False 裸导出输出：(1, 4+nc, 8400) 或 (4+nc, 8400)。
    /// 行 0..3 = cx,cy,w,h（模型输入 640 像素单位）；行 4..(4+nc) = 各类 sigmoid 分数。
    /// 阈值过滤（threshold(for:) 分级灵敏度）+ App 端 NMS（iou 0.6）。
    /// 诊断口径与 pipeline 路径一致：rawAll=分数>0.01 全部候选；lowConf=≥0.05 但低于当前档阈值。
    private static func decodeRawOutput(_ ma: MLMultiArray, maxCount: Int)
        -> (out: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)],
            rawAll: [(cls: String, score: Double)],
            lowConf: [(cls: String, score: Double)],
            droppedBox: Int) {
        let nc = classNames.count
        let anchors = ma.shape.last?.intValue ?? 0
        // 线性索引步长（默认连续布局 (1,9,8400) → strides (75600, 8400, 1)）
        let strides = ma.strides
        let stCh = strides.count >= 2 ? strides[strides.count - 2].intValue : anchors
        let stAn = strides.count >= 1 ? strides[strides.count - 1].intValue : 1
        let side = 640.0   // 模型输入边长（原始 xywh 以此为单位，归一化 = /640）

        var rawAll: [(cls: String, score: Double)] = []
        var lowConf: [(cls: String, score: Double)] = []
        var cands: [(rect: CGRect, type: String, pixelSize: CGSize, score: Double)] = []
        var droppedBox = 0

        for a in 0 ..< anchors {
            var best = -1, bestScore = 0.0
            for c in 0 ..< nc {
                // 注意：nms=False 裸导出布局为 (cx,cy,w,h, cls0..clsN)，
                // 类分数在通道 4..(4+nc)，前 4 通道是框坐标（像素级大值）。
                // 误把坐标通道当类分数是真机满图高分乱报的根因。
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

        // App 端 NMS（此前由模型内嵌 NMS 承担；iou 0.6），按分数降序保留
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
