// DefectDetectionEngine.swift
// 双引擎并行检测路由：端侧 CoreML（离线 / 保密 / 零费用）+ 云端视觉（联网高精度兜底）。
// 输出统一为 [DetectedDefect]，下游 ISO5817 评级 / AR 标注 / 报告一行都不用改。
// 云端引擎当前为「协议占位」：endpoint 未配置时由路由层自动回落端侧；
// 待服务端选型（自建 YOLO 云端点 / 通用视觉大模型）确定后，在 CloudVisionEngine 内填实。

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

/// 云端视觉引擎：把照片发到服务端大模型 / 自建 YOLO 端点做检测。
/// 当前为协议占位——endpoint 从 UserDefaults("cloudVisionEndpoint") 读取，未配置即抛错，
/// 由路由层捕获并回落端侧。服务端选型确定后，在此填实 POST 图片 + roi、解析 [DetectedDefect]。
struct CloudVisionEngine: DefectDetectionEngine {
    func detect(in image: UIImage, roi: CGRect?, maxCount: Int) async throws -> [DetectedDefect] {
        guard let endpoint = UserDefaults.standard.string(forKey: "cloudVisionEndpoint"),
              !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw DetectionError.cloudNotConfigured
        }
        // TODO（服务端选型确定后填实）：
        // let jpeg = image.jpegData(compressionQuality: 0.82)!
        // var req = URLRequest(url: url); req.httpMethod = "POST"
        // req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type"); req.httpBody = jpeg
        // let (data, _) = try await URLSession.shared.data(for: req)
        // return try parseCloudResponse(data)   // JSON -> [DetectedDefect]
        throw DetectionError.cloudNotImplemented
    }
}

/// 路由层：按设置 + 网络可达决定用哪个引擎；云端不可用（无网 / 未配置 / 错误）自动回落端侧。
struct DetectionRouter {
    /// 端侧同步检测（逐 ROI 合并）。
    static func localDetect(in image: UIImage, rois: [CGRect], maxCount: Int = 16) -> [DetectedDefect] {
        var out: [DetectedDefect] = []
        let list = rois.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : rois
        for r in list {
            out += (try? LocalCoreMLEngine().detect(in: image, roi: r.isEmpty ? nil : r, maxCount: maxCount)) ?? []
        }
        return out
    }

    /// 云端异步检测。
    static func cloudDetect(in image: UIImage, rois: [CGRect], maxCount: Int = 16) async throws -> [DetectedDefect] {
        var out: [DetectedDefect] = []
        let list = rois.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : rois
        for r in list {
            out += try await CloudVisionEngine().detect(in: image, roi: r.isEmpty ? nil : r, maxCount: maxCount)
        }
        return out
    }

    /// 统一入口：返回 (缺陷, 来源, 提示)。云端失败自动回落端侧并给提示。
    static func detect(in image: UIImage, rois: [CGRect], maxCount: Int = 16, mode: DetectionEngineMode)
        async -> (defects: [DetectedDefect], source: String, note: String) {
        switch mode {
        case .local:
            return (localDetect(in: image, rois: rois, maxCount: maxCount), "local", "")
        case .cloud:
            do {
                let d = try await cloudDetect(in: image, rois: rois, maxCount: maxCount)
                return (d, "cloud", "")
            } catch {
                let fb = localDetect(in: image, rois: rois, maxCount: maxCount)
                return (fb, "local(fallback)", "云端不可用（\(errorDesc(error))），已自动回落端侧")
            }
        case .auto:
            let local = localDetect(in: image, rois: rois, maxCount: maxCount)
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
