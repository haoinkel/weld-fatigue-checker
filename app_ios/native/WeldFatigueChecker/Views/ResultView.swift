// Views/ResultView.swift
import SwiftUI

struct ResultView: View {
    let result: AssessmentResult
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlowText(text: "评估结果", font: .title2.bold())

            kv("细节类别", "\(result.fatigue.detailName) (\(result.fatigue.detailId))")
            kv("基准 FAT", "\(result.fatigue.baseFat)")
            ForEach(result.fatigue.improvements, id: \.label) { imp in
                kv("改善措施", "\(imp.0) ×\(imp.1) → FAT \(Int(imp.2))")
            }
            kv("有效 FAT", "\(Int(result.fatigue.effectiveFat))")
            kv("应力幅 Δσ", "\(Int(result.fatigue.deltaSigma)) MPa (γ_Mf=\(result.fatigue.gammaMf))")
            kv("允许次数", fmt(result.fatigue.nAllowable))
            kv("需求次数", fmt(result.fatigue.nRequired))
            kv("利用率", String(format: "%.3f （>1 不满足）", result.fatigue.utilization))
            HStack {
                Text("疲劳结论").bold().foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(result.fatigue.pass ? "满足 ✓" : "不满足 ✗")
                    .bold()
                    .foregroundStyle(result.fatigue.pass ? Theme.ok : Theme.danger)
                    .shadow(color: (result.fatigue.pass ? Theme.ok : Theme.danger).opacity(0.6), radius: 6, y: 0)
            }

            if !result.design.warnings.isEmpty {
                Text("① 识别出的不合理/疲劳不利细部").font(.subheadline.bold())
                ForEach(result.design.warnings, id: \.id) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            tag(w.severity)
                            Text("\(w.id) \(w.title)").bold()
                        }
                        Text(w.finding).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .techCard()
                }
            }

            Text("② 表面缺陷（ISO 5817）").font(.subheadline.bold())
            ForEach(result.imperfections, id: \.label) { r in
                kv(r.label + (r.fatigueRelevant ? " [疲劳相关]" : ""),
                   "\(r.accepted == true ? "通过" : (r.accepted == false ? "超差" : "未判定")) | \(r.limit)")
            }

            Text("③ 改善建议（按优先级）").font(.subheadline.bold())
            ForEach(result.plan, id: \.ruleId) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        tag(p.priority)
                        Text("\(p.ruleId) \(p.title)").bold()
                    }
                    Text(p.action + (p.raisesFatTo != nil ? "（目标FAT≈\(p.raisesFatTo!))" : "")).font(.caption)
                    if !p.effort.isEmpty {
                        Text("工作量：\(p.effort)").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                .techCard()
            }

            HStack(spacing: 12) {
                Button {
                    if let url = ReportGenerator.exportPDF(result) {
                        shareURL = url; exportError = nil; showShare = true
                    } else { exportError = "PDF 导出失败，请重试" }
                } label: { Label("导出 PDF", systemImage: "square.and.arrow.up") }
                    .buttonStyle(TechButtonStyle(filled: false))

                Button {
                    if let url = ReportGenerator.exportWord(result) {
                        shareURL = url; exportError = nil; showShare = true
                    } else { exportError = "Word 导出失败，请重试" }
                } label: { Label("导出 Word", systemImage: "doc.badge.arrow.up") }
                    .buttonStyle(TechButtonStyle(filled: false))
            }
            if let exportError {
                Text(exportError).font(.caption).foregroundColor(.red)
            }
            Text(result.disclaimer).font(.caption2).foregroundColor(.secondary)
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]).presentationDetents([.medium, .large]) }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).bold().foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(v).multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.textPrimary)
                .mono(15)
        }.font(.subheadline)
    }
    private func fmt(_ n: Double) -> String { n.isFinite ? String(format: "%.3e", n) : "∞" }
    private func tag(_ p: String) -> some View {
        let map = ["high": "严重", "medium": "建议", "low": "可优化", "ok": "通过"]
        let color: Color = p == "high" ? Theme.danger : (p == "medium" ? Theme.warn : (p == "low" ? Theme.cyan : Theme.ok))
        return Text(map[p, default: p]).font(.caption2).padding(4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.45), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// 系统分享 sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
