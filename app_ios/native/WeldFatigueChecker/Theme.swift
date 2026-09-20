// Theme.swift
// 全局「科技感」暗色主题：深空底 + 霓虹青强调色 + 玻璃拟态面板 + 发光按钮 + 等宽数据字。
// 所有视图共用本文件中的颜色、修饰符与组件，保证视觉一致。

import SwiftUI

// MARK: - 调色板
enum Theme {
    // 背景：极深蓝黑渐变
    static let bgTop    = Color(red: 0.027, green: 0.043, blue: 0.071) // #070B12
    static let bgBottom = Color(red: 0.043, green: 0.071, blue: 0.114) // #0B122D
    static let bgGradient = LinearGradient(
        colors: [bgTop, bgBottom],
        startPoint: .top, endPoint: .bottom)

    // 面板：略带蓝的暗灰，带细微高光
    static let panelTop    = Color(red: 0.094, green: 0.122, blue: 0.188) // #18203 0
    static let panelBottom = Color(red: 0.062, green: 0.086, blue: 0.141) // #0F1624
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
            .frame(maxWidth: .filled ? .infinity : nil)
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
