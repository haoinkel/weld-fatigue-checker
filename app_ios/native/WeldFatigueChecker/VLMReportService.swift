// VLMReportService.swift
// 优化点 C：VLM 混合语义报告。
//
// 铁律（依据 焊接学报 2026 / GPT-4V 焊接实测仅 77% 且漏未熔合）：
//   VLM 只做「语义解释 + 处置建议」，绝不替代 YOLO 检测结果与 ISO 5817 评级。
//   检测器定位/分类/尺寸 与 ISO5817Grader 评级是权威输入；VLM 仅在其上叠加人类可读说明。
//
// 设计：
//   - WeldVLM 协议：explain(input:) async -> VLMReport
//   - RemoteVLMService：OpenAI 兼容 chat 接口（通义千问/Claude 等同构，改 baseURL 即可），
//     请求体由 VLMReportComposer 生成（ISO 5817 锚定的 system + user prompt），要求 JSON 输出。
//   - MockVLMService：离线/预览用，返回确定性结构，便于无网络时联调 UI。
//
// 安全：API Key 不入代码；由调用方从 Keychain/设置注入。本模块不缓存任何图像原文。
//
// 说明：本环境无 Mac，无法编译验证；仅用 Foundation + URLSession，无 ARKit/UIKit 依赖。

import Foundation

/// 一次 VLM 咨询的输入（纯数据，可由检测结果 + ISO 初评组装）
struct VLMSessionInput {
    let defects: [VLMDefectBrief]
    let plateThicknessMm: Double
    let standard: String            // 如 "ISO 5817:2023"
    let weldContext: String?        // 接头类型/工艺等自由文本（可选）
    let imagesBase64: [String]?     // 裁剪缺陷图 base64（多模态 VLM 可选附带）
}

struct VLMDefectBrief {
    let type: String
    let sizeMm: Double?
    let grade: String?
    let accepted: Bool?
}

struct VLMReport {
    let summary: String
    let items: [VLMItem]
    let raw: String
    let provider: String
}

struct VLMItem {
    let defectType: String
    let interpretation: String      // 判定依据（对应 ISO 5817 哪一条）+ 可能成因
    let recommendation: String      // 处置建议（打磨/补焊/返修/拒收）
}

protocol WeldVLM {
    func explain(input: VLMSessionInput) async throws -> VLMReport
}

enum VLMError: Error { case parse, transport }

/// 远端 VLM（OpenAI 兼容 schema）。通义千问/Claude 等同构，仅 baseURL/model 不同。
struct RemoteVLMService: WeldVLM {
    var baseURL: String
    var apiKey: String
    var model: String
    var provider: String

    func explain(input: VLMSessionInput) async throws -> VLMReport {
        let userPrompt = VLMReportComposer.buildPrompt(input: input)
        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": VLMReportComposer.systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "temperature": 0.2,
            "response_format": ["type": "json_object"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String, !content.isEmpty else {
            throw VLMError.parse
        }
        return VLMReportComposer.parse(report: content, provider: provider, raw: content)
    }
}

/// 离线模拟服务：无网络时联调 UI 用，不调用任何外部 API。
struct MockVLMService: WeldVLM {
    func explain(input: VLMSessionInput) async throws -> VLMReport {
        let items = input.defects.map { d in
            VLMItem(defectType: d.type,
                    interpretation: "（离线模拟）检测到 \(d.type)，请按 ISO 5817 由持证人员复核。",
                    recommendation: "结合 UT/RT/MT/PT 等无损检测确认后处置。")
        }
        return VLMReport(summary: "（离线模拟报告，未连接真实 VLM）", items: items, raw: "", provider: "mock")
    }
}

enum VLMProvider {
    /// 工厂：按常用端点快速构造。baseURL 也可直接传任意 OpenAI 兼容地址。
    static func make(baseURL: String, apiKey: String, model: String, provider: String = "openai") -> RemoteVLMService {
        RemoteVLMService(baseURL: baseURL, apiKey: apiKey, model: model, provider: provider)
    }
}

/// Prompt 与响应解析（与 ml/vlm_eval/prompt_templates.md 同源，便于在 AI Studio 复现验证）
enum VLMReportComposer {

    static let systemPrompt = """
    你是一名资深焊接检验师（CSWIP / ISO 17637 目视(VT)视角）。你将收到一份由端侧 AI 视觉模型(YOLOv8)对焊缝外观照片的检测结果，
    包含：缺陷类型、实测尺寸(mm)、ISO 5817 初评等级与合格性结论。你的任务：
    1) 仅做语义解释与处置建议，不得推翻或修改检测器的缺陷类型 / 尺寸 / 等级（检测结果是权威输入，你无权改写）；
    2) 对每个缺陷给出：判定依据（对应 ISO 5817:2023 哪一条）、可能的工艺成因、处置建议（打磨 / 补焊 / 返修 / 拒收）；
    3) 给出整体焊接质量小结，以及后续无损检测(UT/RT/MT/PT)的建议项；
    4) 明确声明：本建议为 AI 辅助，不替代认证检验与无损检测结论。
    输出严格 JSON：{"summary":"...","items":[{"defect_type":"...","interpretation":"...","recommendation":"..."}]}
    """

    static func buildPrompt(input: VLMSessionInput) -> String {
        var lines: [String] = []
        lines.append("标准：\(input.standard)；母材厚度 t = \(String(format: "%.1f", input.plateThicknessMm)) mm。")
        if let c = input.weldContext, !c.isEmpty { lines.append("工况/接头：\(c)") }
        lines.append("检测结果（共 \(input.defects.count) 项）：")
        for (i, d) in input.defects.enumerated() {
            let size = d.sizeMm.map { String(format: "%.2f mm", $0) } ?? "未测"
            let g = d.grade ?? "-"
            let acc = d.accepted.map { $0 ? "合格" : "超差" } ?? "未评"
            lines.append("  \(i + 1). \(d.type)  实测=\(size)  初评等级=\(g)  结论=\(acc)")
        }
        lines.append("请严格按 system 指令输出 JSON 报告（不得修改上面任何检测结果）。")
        return lines.joined(separator: "\n")
    }

    /// 解析 VLM 返回的 JSON 文本；若不是合法 JSON，则整段作为 summary 返回（不崩溃）。
    static func parse(report: String, provider: String, raw: String) -> VLMReport {
        guard let data = report.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return VLMReport(summary: report, items: [], raw: raw, provider: provider)
        }
        let summary = obj["summary"] as? String ?? ""
        let itemsRaw = obj["items"] as? [[String: Any]] ?? []
        let items = itemsRaw.compactMap { m -> VLMItem? in
            guard let t = m["defect_type"] as? String else { return nil }
            return VLMItem(defectType: t,
                           interpretation: m["interpretation"] as? String ?? "",
                           recommendation: m["recommendation"] as? String ?? "")
        }
        return VLMReport(summary: summary, items: items, raw: raw, provider: provider)
    }
}
