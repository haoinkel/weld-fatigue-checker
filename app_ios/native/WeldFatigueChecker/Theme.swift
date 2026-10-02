// Theme.swift
// 全局「科技感」暗色主题：深空底 + 霓虹青强调色 + 玻璃拟态面板 + 发光按钮 + 等宽数据字。
// 所有视图共用本文件中的颜色、修饰符与组件，保证视觉一致。

import SwiftUI

// MARK: - 调色板
enum Theme {
    // 背景：深蓝灰渐变（非纯黑，车间强光下更柔和、层次更清晰）
    static let bgTop    = Color(red: 0.118, green: 0.161, blue: 0.243) // #1E293D
    static let bgBottom = Color(red: 0.082, green: 0.125, blue: 0.200) // #152033
    static let bgGradient = LinearGradient(
        colors: [bgTop, bgBottom],
        startPoint: .top, endPoint: .bottom)

    // 面板：比背景更亮的蓝灰，带细微高光，保证卡片悬浮感
    static let panelTop    = Color(red: 0.165, green: 0.208, blue: 0.290) // #2A3550
    static let panelBottom = Color(red: 0.110, green: 0.153, blue: 0.227) // #1C273A
    static let panelGradient = LinearGradient(
        colors: [panelTop, panelBottom],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // 霓虹强调色
    static let cyan  = Color(red: 0.0,   green: 0.851, blue: 1.0)   // #00D9FF
    static let blue  = Color(red: 0.235, green: 0.557, blue: 1.0)   // #3C8EFF
    static let violet = Color(red: 0.706, green: 0.408, blue: 1.0)  // #B468FF

    // 语义色（在暗底上更明亮）
    static let ok    = Color(red: 0.255, green: 0.906, blue: 0.557) // 绿
    static let warn  = Color(red: 1.0,   green: 0.718, blue: 0.224) // 橙
    static let danger = Color(red: 1.0,  green: 0.365, blue: 0.396) // 红

    // 文本
    static let textPrimary   = Color(red: 0.918, green: 0.949, blue: 0.988)
    static let textSecondary = Color(red: 0.612, green: 0.671, blue: 0.761)
}

// MARK: - 根背景（铺满安全区）
struct TechBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.bgGradient.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}

// MARK: - 玻璃拟态面板（带霓虹描边与可选发光）
struct TechCard: ViewModifier {
    var glow: Bool = false
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.panelGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.cyan.opacity(glow ? 0.55 : 0.22), lineWidth: 1)
            )
            .shadow(color: Theme.cyan.opacity(glow ? 0.28 : 0.0), radius: glow ? 14 : 0, y: 0)
    }
}

// MARK: - 主操作按钮（霓虹渐变胶囊）
struct TechButtonStyle: ButtonStyle {
    var filled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: filled ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, filled ? 0 : 14)
            .foregroundStyle(filled ? Color.black : Theme.cyan)
            .background(
                filled
                ? AnyView(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                         startPoint: .leading, endPoint: .trailing)
                            .clipShape(Capsule()))
                : AnyView(Theme.cyan.opacity(0.12).clipShape(Capsule()))
            )
            .overlay(
                Capsule().stroke(Theme.cyan.opacity(filled ? 0.0 : 0.55), lineWidth: 1)
            )
            .shadow(color: Theme.cyan.opacity(filled ? 0.35 : 0.0), radius: 10, y: 0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
    }
}

// MARK: - 通用修饰符
extension View {
    /// 整页暗色科技背景
    func techBackground() -> some View { self.modifier(TechBackground()) }

    /// 玻璃拟态面板卡片
    func techCard(glow: Bool = false) -> some View { self.modifier(TechCard(glow: glow)) }

    /// 等宽数字（用于 FAT / MPa / mm 等数值）
    func mono(_ size: CGFloat = 15, weight: Font.Weight = .medium) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

// MARK: - 章节标题（左侧霓虹竖条）
struct SectionTitle: View {
    let text: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(
                LinearGradient(colors: [Theme.cyan, Theme.blue],
                               startPoint: .top, endPoint: .bottom)
            ).frame(width: 4, height: 18)
            if let s = systemImage {
                Image(systemName: s).foregroundStyle(Theme.cyan).font(.subheadline)
            }
            Text(text)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
    }
}

// MARK: - 霓虹渐变大标题（用于结果、关键数值）
struct GlowText: View {
    let text: String
    var font: Font = .title3.bold()
    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(
                LinearGradient(colors: [Theme.cyan, Theme.violet],
                               startPoint: .leading, endPoint: .trailing)
            )
    }
}

// MARK: - 缺陷统一语义色
// 照片标注与实时扫描共用，避免「照片橙、扫描青」两色混淆。
// 暖橙与整体青色科技 UI 形成对比，在焊缝照片上更醒目。
extension Theme {
    static let defect = Color(red: 1.0, green: 0.55, blue: 0.2)   // #FF8C33 缺陷框/标记
}

// MARK: - 环形仪表（疲劳利用率 / 合格率等 0..1+ 指标）
struct GaugeRing: View {
    let value: Double          // 允许 >1（超差）
    let label: String
    var caption: String? = nil
    var body: some View {
        let v = min(max(value, 0), 1)
        let color: Color = value > 1 ? Theme.danger : (value > 0.8 ? Theme.warn : Theme.ok)
        ZStack {
            Circle()
                .stroke(Theme.textSecondary.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: v)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 6, y: 0)
            VStack(spacing: 2) {
                Text(String(format: "%.0f%%", value * 100))
                    .font(.title.bold()).foregroundStyle(Theme.textPrimary)
                Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(String(format: "%.0f%%", value * 100))" + (value > 1 ? "，超差" : value > 0.8 ? "，接近上限" : "，在安全范围内"))
    }
}

// MARK: - 缺陷类型统一标签（与模型 5 类输出对齐）
// 模型输出：porosity/crack/undercut/overlap/unfused
enum DefectTypes {
    static let all: [(tag: String, label: String)] = [
        ("undercut", "咬边"),
        ("porosity", "气孔"),
        ("crack",    "裂纹/弧坑裂纹"),
        ("overlap",  "焊瘤/满溢"),
        ("unfused",  "未熔合"),
    ]
    static func label(_ tag: String) -> String {
        all.first(where: { $0.tag == tag })?.label ?? "缺陷"
    }

    // 类别严重度（越小越严重）：裂纹/弧坑裂纹 > 未熔合 > 咬边 > 焊瘤 > 气孔
    static func typeRank(_ tag: String) -> Int {
        switch tag {
        case "crack":   return 0
        case "unfused": return 1
        case "undercut":return 2
        case "overlap": return 3
        case "porosity":return 4
        default:        return 9
        }
    }
    // 验收状态优先级（越小越优先显示）：超差 > 未判定 > 合格
    static func acceptanceRank(_ accepted: Bool?) -> Int {
        if accepted == false { return 0 }
        if accepted == nil   { return 1 }
        return 2
    }
}

// MARK: - 工作流步骤条（引导用户按正确顺序操作）
struct StepBar: View {
    let steps: [String]
    let current: Int   // 当前已到达的步骤索引（0-based）；-1 表示尚未开始
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, label in
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(i <= current ? Theme.cyan : Theme.textSecondary.opacity(0.25))
                            .frame(width: 22, height: 22)
                        if i < current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                        } else {
                            Text("\(i + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(i == current ? .black : Theme.textSecondary)
                        }
                    }
                    .accessibilityLabel("步骤 \(i + 1)：\(label)" + (i < current ? "（已完成）" : i == current ? "（进行中）" : "（未开始）"))
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(i <= current ? Theme.textPrimary : Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 56)
                }
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(i < current ? Theme.cyan : Theme.textSecondary.opacity(0.25))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
