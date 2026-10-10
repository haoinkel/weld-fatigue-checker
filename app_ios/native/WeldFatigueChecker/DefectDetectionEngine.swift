// DefectDetectionEngine.swift
// 双引擎并行检测路由：端侧 CoreML（离线 / 保密 / 零费用）+ 云端视觉（联网高精度兜底）。
// 输出统一为 [DetectedDefect]，下游 ISO5817 评级 / AR 标注 / 报告一行都不用改。
//
// 云端引擎已填实：对接通用视觉大模型（默认通义 Qwen-VL，OpenAI 兼容格式亦兼容 GPT-4V 等）。
// endpoint / apiKey / model 从 UserDefaults 读取；apiKey 未配置时由路由层自动回落端侧。
// 注意：云端仅作「高精度粗筛兜底」——尺寸 / ISO 5817 评级仍以端侧 LiDAR + ISO5817Grader 为准；
// 照片 / ROI 会经第三方服务端处理，工业保密件请谨慎开启云端模式。

import UIKit

/// 检测引擎模式：手动选择，云端无网时自动回落端侧。
enum DetectionEngineMode: String, CaseIterable {
    case local, cloud, auto
    var label: String {
        switch self {
        case .local: return "端侧（离线）"
        case .cloud: return "云端（需联网）"
        case .auto:  return "自动（端侧+补检）"
        }
    }
}

enum DetectionError: Error {
    case cloudNotConfigured
    case cloudNotImplemented
    case offline
}

/// 统一检测引擎协议：任何引擎都返回 [DetectedDefect]，上游无需感知来源。
protocol DefectDetectionEngine {
    func detect(in image: UIImage, roi: CGRect?, maxCount: Int) async throws -> [DetectedDefect]
}

/// 端侧引擎：包现有的 MLDefectDetector（含 tiled 推理 + CV 规则回退），原有逻辑原样保留。
struct LocalCoreMLEngine: DefectDetectionEngine {
    func detect(in image: UIImage, roi: CGRect?, maxCount: Int) async throws -> [DetectedDefect] {
        MLDefectDetector.detect(in: image, maxCount: maxCount, roi: roi)
    }
}

/// 云端视觉引擎：把照片（ROI 裁图）发到通用视觉大模型端点做检测。
/// 请求体为 OpenAI chat/completions 多模态格式，默认通义 DashScope 兼容模式；
/// 同样兼容 GPT-4V 等任意 OpenAI 兼容端点，只需在设置里换 endpoint + model + apiKey。
/// apiKey 未配置即抛 cloudNotConfigured，由路由层捕获并自动回落端侧。
struct CloudVisionEngine: DefectDetectionEngine {
    /// 上传前最长边上限（px）。1280 曾致小缺陷（气孔/细咬边）漏检、精度回退（真机反馈 2026-10-10），
    /// 回调到 2048：像素面积是 1280 的 2.56 倍、细节显著保留，上传体积仍比原图 4032px 省 ~4 倍，加速大头不受影响。
    /// ROI 裁图通常本就小于 2048，不会被二次缩放。
    static let uploadMaxSide: CGFloat = 2048

    func detect(in image: UIImage, roi: CGRect?, maxCount: Int) async throws -> [DetectedDefect] {
        let cfg = CloudVisionConfig.load()
        guard !cfg.apiKey.isEmpty else { throw DetectionError.cloudNotConfigured }
        // 裁到 ROI（若无 ROI 用全图），再缩放到上传上限 —— 减少上传量 + 加速视觉 prefill
        let sent = roi.map { Self.crop(image, roi: $0) } ?? image
        let sentImg = Self.downscale(sent, maxSide: Self.uploadMaxSide)
        guard let url = URL(string: cfg.endpoint),
              let body = Self.requestBody(image: sentImg, cfg: cfg) else {
            throw DetectionError.cloudNotConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DetectionError.cloudNotImplemented
        }
        guard let raw = String(data: data, encoding: .utf8) else { throw DetectionError.cloudNotImplemented }
        // sentImg.size 为模型实际看到的像素尺寸（绝对像素量纲归一化用）；image 为原始整图（bbox 映射用）
        return try Self.parse(raw, image: image, sentSize: sentImg.size, maxCount: maxCount, roi: roi)
    }

    // MARK: - 缩放（上传前降分辨率，不影响归一化坐标逻辑）
    static func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let w = img.size.width, h = img.size.height
        let longest = max(w, h)
        guard longest > maxSide else { return img }
        let scale = maxSide / longest
        let newW = max(1, Int(w * scale)), newH = max(1, Int(h * scale))
        let fmt = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH))
        return fmt.image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
        }
    }

    // MARK: - 请求体构造（OpenAI 兼容多模态）
    /// 入参 image 应为已裁好/缩好的送检图；bbox 归一化 0~1 由模型相对此图输出。
    static func requestBody(image: UIImage, cfg: CloudVisionConfig) -> Data? {
        guard let jpeg = image.jpegData(compressionQuality: 0.82) else { return nil }
        let b64 = jpeg.base64EncodedString()
        let sys = "你是一名资深焊接检验师(CWI)。仅识别焊缝表面可见缺陷；内部缺陷(深裂纹/深层未熔合)不可见，不要臆测。"
        let usr = "请严格输出 JSON，不要任何额外文字：{\"defects\":[{\"type\":\"标准英文名(undercut/porosity/crack/lack_of_fusion/excess_weld_metal/overlap/excessive_convexity/spatter/slag/incomplete_penetration/misalignment)\",\"confidence\":0到1,\"estSizeMm\":数值(缺陷主尺寸毫米),\"severity\":\"low|medium|high\",\"bbox\":[x,y,w,h]}]}。bbox 为必填项：相对本张送检图像宽高的归一化坐标，左上角为原点，四个值均为 0~1 的小数，w/h 为框宽高（例：[0.32,0.15,0.18,0.42]）。若无缺陷返回 {\"defects\":[]}。"
        // 输出只是小 JSON，限制 max_tokens 避免模型冗长生成拖慢首包
        // Thinking 版模型（模型名含 "-Thinking"）：思考 token 计入输出预算，给更大 max_tokens 防 JSON 截断，且开启思考拿推理精度
        let isThinkingModel = cfg.model.localizedCaseInsensitiveContains("-Thinking")
        var payload: [String: Any] = [
            "model": cfg.model,
            "temperature": 0.2,
            "max_tokens": isThinkingModel ? 2048 : 1280,
            "messages": [
                ["role": "system", "content": sys],
                ["role": "user", "content": [
                    ["type": "text", "text": usr],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                ]]
            ]
        ]
        if cfg.endpoint.contains("siliconflow") {
            // 按模型名自适应：-Thinking 开思考（推理精度），其余关思考（加速）
            payload["chat_template_kwargs"] = ["enable_thinking": isThinkingModel]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - 响应解析
    /// roi：本次送检用的 ROI（整图归一化 0~1）。云端看到的是 ROI 裁图，模型返回的 bbox 相对裁图，
    /// 必须映射回整图坐标，否则照片叠层画错位置/画出画面外（真机实证）。
    static func parse(_ raw: String, image: UIImage, sentSize: CGSize, maxCount: Int, roi: CGRect? = nil) throws -> [DetectedDefect] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw DetectionError.cloudNotImplemented
        }
        // 兼容模型在 JSON 外包裹 ```json 代码块的情况
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var jstr = trimmed
        if let s = trimmed.range(of: "```json") {
            let after = trimmed[s.upperBound...]
            if let e = after.range(of: "```") { jstr = String(after[after.startIndex..<e.lowerBound]) }
            else { jstr = String(after) }
        }
        guard let first = jstr.firstIndex(of: "{"), let last = jstr.lastIndex(of: "}") else {
            throw DetectionError.cloudNotImplemented
        }
        let sub = String(jstr[first...last])
        guard let d2 = sub.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let arr = obj["defects"] as? [[String: Any]] else {
            throw DetectionError.cloudNotImplemented
        }
        var out: [DetectedDefect] = []
        let iw = Double(image.size.width), ih = Double(image.size.height)
        for d in arr {
            let rawType = (d["type"] as? String) ?? "defect"
            let type = Self.mapType(rawType)
            let est = (d["estSizeMm"] as? NSNumber)?.doubleValue ?? 0
            // bbox 统一为整图归一化 0~1（兼容 0~1 / 0~1000 / 绝对像素三种量纲 + ROI 映射回整图）
            let nums = (d["bbox"] as? [NSNumber])?.map { $0.doubleValue } ?? []
            let rect = Self.normalizedBBox(nums, sentSize: sentSize, roi: roi)
                ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            // 云端给的是绝对 mm 估算，直接进 DefectMetric（优先于像素尺度估算）
            let metric: DefectMetric? = est > 0 ? DefectMetric(lengthMm: est, widthMm: est, standoffM: 0, method: .scaleBased) : nil
            out.append(DetectedDefect(rect: rect, type: type, pixelSize: CGSize(width: iw, height: ih), metric: metric))
            if out.count >= maxCount { break }
        }
        return out
    }

    /// 模型 bbox 量纲自适应 → 整图归一化 0~1 矩形。
    /// 兼容三种常见输出：①0~1 归一化（按提示词要求）；②0~1000（Qwen 系 grounding 原生格式）；
    /// ③绝对像素（相对本次送检的 ROI 裁图）。识别失败的返回 nil（调用方画全图占位框）。
    static func normalizedBBox(_ v: [Double], sentSize: CGSize, roi: CGRect?) -> CGRect? {
        guard v.count == 4 else { return nil }
        var x = v[0], y = v[1], w = v[2], h = v[3]
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        let m = max(x, y, w, h)
        // 模型实际看到的送检图像素尺寸（已缩放到 uploadMaxSide），绝对像素量纲归一化用它
        let sentW = sentSize.width
        let sentH = sentSize.height
        if m > 1.5 {
            if x + w <= sentW + 2, y + h <= sentH + 2, m <= max(sentW, sentH) + 1 {
                // ③绝对像素（相对送检裁图）
                x /= sentW; y /= sentH; w /= sentW; h /= sentH
            } else if m <= 1000 {
                // ②Qwen 系 0~1000 grounding
                x /= 1000; y /= 1000; w /= 1000; h /= 1000
            } else {
                return nil
            }
        }
        // 裁图内归一化 → 整图归一化（并夹取到 0~1，容忍模型轻微出界）
        func cl(_ t: Double) -> Double { min(1, max(0, t)) }
        if let r = roi, !r.isEmpty {
            return CGRect(x: cl(r.minX + x * r.width), y: cl(r.minY + y * r.height),
                          width: min(1 - cl(r.minX + x * r.width), w * r.width),
                          height: min(1 - cl(r.minY + y * r.height), h * r.height))
        }
        return CGRect(x: cl(x), y: cl(y), width: min(1 - cl(x), w), height: min(1 - cl(y), h))
    }

    /// 云端返回的缺陷类型名 → 本工程标准类型（对齐 ISO5817Grader.aliases）。
    static func mapType(_ raw: String) -> String {
        let s = raw.lowercased()
        let table: [([String], String)] = [
            (["undercut", "咬边"], "undercut"),
            (["porosity", "pore", "气孔"], "porosity"),
            (["crack", "裂纹", "crater"], "crack"),
            (["lack_of_fusion", "unfused", "incomplete_fusion", "未熔合"], "lack_of_fusion"),
            (["excess_weld_metal", "excessive_convexity", "凸度", "余高"], "excess_weld_metal"),
            (["overlap", "满溢", "焊瘤"], "overlap"),
            (["spatter", "飞溅"], "spatter"),
            (["slag", "夹渣"], "slag"),
            (["incomplete_penetration", "lack_of_penetration", "未焊透"], "incomplete_penetration"),
            (["misalignment", "错边"], "misalignment")
        ]
        for (keys, val) in table {
            if keys.contains(where: { s.contains($0) }) { return val }
        }
        return raw
    }

    /// 按归一化 ROI 裁图（聚焦焊缝 + 减少上传数据量）。
    static func crop(_ img: UIImage, roi: CGRect) -> UIImage {
        let scale = img.scale
        let px = CGRect(x: roi.origin.x * img.size.width * scale,
                        y: roi.origin.y * img.size.height * scale,
                        width: max(1, roi.width * img.size.width * scale),
                        height: max(1, roi.height * img.size.height * scale))
        guard let cg = img.cgImage?.cropping(to: px) else { return img }
        return UIImage(cgImage: cg, scale: scale, orientation: img.imageOrientation)
    }
}

/// 路由层：按设置 + 网络可达决定用哪个引擎；云端不可用（无网 / 未配置 / 错误）自动回落端侧。
struct DetectionRouter {
    /// 端侧同步检测（逐 ROI 合并）。
    static func localDetect(in image: UIImage, rois: [CGRect], maxCount: Int = 16) async -> [DetectedDefect] {
        var out: [DetectedDefect] = []
        let list = rois.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : rois
        for r in list {
            out += (try? await LocalCoreMLEngine().detect(in: image, roi: r.isEmpty ? nil : r, maxCount: maxCount)) ?? []
        }
        return out
    }

    /// 云端异步检测。多 ROI 用任务组并行请求（各区域相互独立），显著缩短多框总耗时。
    static func cloudDetect(in image: UIImage, rois: [CGRect], maxCount: Int = 16) async throws -> [DetectedDefect] {
        let list = rois.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : rois
        var out: [DetectedDefect] = []
        var err: Error?
        await withThrowingTaskGroup(of: [DetectedDefect].self) { group in
            for r in list {
                group.addTask {
                    try await CloudVisionEngine().detect(in: image, roi: r.isEmpty ? nil : r, maxCount: maxCount)
                }
            }
            do {
                for try await res in group { out += res }
            } catch {
                err = error
            }
        }
        if out.isEmpty, let e = err { throw e }
        return out
    }

    /// 统一入口：返回 (缺陷, 来源, 提示)。云端失败自动回落端侧并给提示。
    static func detect(in image: UIImage, rois: [CGRect], maxCount: Int = 16, mode: DetectionEngineMode)
        async -> (defects: [DetectedDefect], source: String, note: String) {
        switch mode {
        case .local:
            return (await localDetect(in: image, rois: rois, maxCount: maxCount), "local", "")
        case .cloud:
            do {
                let d = try await cloudDetect(in: image, rois: rois, maxCount: maxCount)
                return (d, "cloud", "")
            } catch {
                let fb = await localDetect(in: image, rois: rois, maxCount: maxCount)
                return (fb, "local(fallback)", "云端不可用（\(errorDesc(error))），已自动回落端侧")
            }
        case .auto:
            let local = await localDetect(in: image, rois: rois, maxCount: maxCount)
            if isLowConfidence() {   // 端侧低置信 → 云端补检
                if let cloud = try? await cloudDetect(in: image, rois: rois, maxCount: maxCount), !cloud.isEmpty {
                    return (cloud, "cloud", "端侧低置信，已用云端补检")
                }
            }
            return (local, "local", "")
        }
    }

    /// 端侧低置信判定：MLDefectDetector 最近一次 Top3 全为 good_weld（负类）= 没认出缺陷特征。
    static func isLowConfidence() -> Bool {
        let top = MLDefectDetector.lastRawScores.prefix(3)
        return top.isEmpty || top.allSatisfy { $0.cls == "good_weld" }
    }

    static func errorDesc(_ e: Error) -> String {
        if let d = e as? DetectionError {
            switch d {
            case .cloudNotConfigured: return "未配置云端端点"
            case .cloudNotImplemented: return "云端接口未实现"
            case .offline: return "离线"
            }
        }
        return String(describing: e)
    }
}

/// 云端视觉配置：endpoint / apiKey / model 从 UserDefaults 读取。
/// 默认 endpoint 为通义 DashScope OpenAI 兼容模式（qwen-vl-max），该格式同时兼容 GPT-4V 等。
struct CloudVisionConfig {
    var endpoint: String
    var apiKey: String
    var model: String
    static let `default` = CloudVisionConfig(
        endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        apiKey: "",
        model: "qwen-vl-max")
    static func load() -> CloudVisionConfig {
        let d = UserDefaults.standard
        return CloudVisionConfig(
            endpoint: d.string(forKey: "cloudVisionEndpoint") ?? CloudVisionConfig.default.endpoint,
            apiKey: d.string(forKey: "cloudVisionApiKey") ?? "",
            model: d.string(forKey: "cloudVisionModel") ?? CloudVisionConfig.default.model)
    }
}
