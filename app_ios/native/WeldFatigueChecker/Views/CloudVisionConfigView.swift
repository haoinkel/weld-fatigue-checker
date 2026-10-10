import SwiftUI

/// 云端视觉服务端配置卡（可折叠）：云端 endpoint / API Key / 视觉模型预设三选一。
/// 写入全局 UserDefaults，照片页 / 实时扫描 / LiDAR 三条链路共用同一套配置。
struct CloudVisionConfigView: View {
    @State private var expanded: Bool = false

    private var hasCloudKey: Bool {
        !(UserDefaults.standard.string(forKey: "cloudVisionApiKey") ?? "").isEmpty
    }
    private var summary: String {
        guard hasCloudKey else { return "未配置 · 点此展开填写" }
        let model = UserDefaults.standard.string(forKey: "cloudVisionModel") ?? CloudVisionConfig.default.model
        return "已配置 · \(model)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("云端视觉服务端配置").font(.subheadline.bold())
                    Spacer()
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(hasCloudKey ? Theme.ok : Theme.warn)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                TextField("API 端点", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "cloudVisionEndpoint") ?? CloudVisionConfig.default.endpoint },
                    set: { UserDefaults.standard.set($0, forKey: "cloudVisionEndpoint") }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "cloudVisionApiKey") ?? "" },
                    set: { UserDefaults.standard.set($0, forKey: "cloudVisionApiKey") }))

                // 视觉模型预设三选一（当前 32B 标准 / 32B 思考 / Kimi-K2.6）+ 自定义
                // 选预设直接写 cloudVisionModel；与引擎 thinking 自适应开关联动：选 32B-Thinking 自动开思考拿推理精度
                let presets: [(id: String, label: String)] = [
                    ("Qwen/Qwen3-VL-32B-Instruct", "当前 · 32B 标准（快速）"),
                    ("Qwen/Qwen3-VL-32B-Thinking", "32B 思考（推理 · 精度更高）"),
                    ("Pro/moonshotai/Kimi-K2.6", "Kimi-K2.6（最强视觉 · 最慢最贵）")
                ]
                let customTag = "__custom__"
                Picker("视觉模型", selection: Binding(
                    get: {
                        let m = UserDefaults.standard.string(forKey: "cloudVisionModel") ?? CloudVisionConfig.default.model
                        return presets.contains { $0.id == m } ? m : customTag
                    },
                    set: { if $0 != customTag { UserDefaults.standard.set($0, forKey: "cloudVisionModel") } }
                )) {
                    ForEach(presets, id: \.id) { p in Text(p.label).tag(p.id) }
                    Text("自定义…").tag(customTag)
                }
                .pickerStyle(.menu)
                TextField("模型名（可自定义直接改）", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "cloudVisionModel") ?? CloudVisionConfig.default.model },
                    set: { UserDefaults.standard.set($0, forKey: "cloudVisionModel") }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Text("OpenAI 兼容多模态端点。照片/ROI 将上传至该服务端；工业保密件请谨慎开启云端模式。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("收起") {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
                    }
                    .font(.caption.bold())
                }
            }
        }
        .onAppear {
            // 首次使用（Key 为空）自动展开；已配置默认折叠防误删
            expanded = (UserDefaults.standard.string(forKey: "cloudVisionApiKey") ?? "").isEmpty
        }
    }
}
