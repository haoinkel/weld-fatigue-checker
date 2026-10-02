// Views/ResultView.swift
import SwiftUI

struct ResultView: View {
    let result: AssessmentResult
    @EnvironmentObject var store: Store
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlowText(text: "评估结果", font: .title2.bold())

            kv("细节类别", "\(result.fatigue.detailName) (\(result.fatigue.detailId))")
            if let tbl = result.fatigue.table {
                kv("对比标准表", "EN 1993-1-9 表 \(tbl)")
            }
            kv("基准 FAT", "\(result.fatigue.baseFat)")
            ForEach(result.fatigue.improvements, id: \.label) { imp in
                kv("改善措施", "\(imp.0) ×\(imp.1) → FAT \(Int(imp.2))")
            }
            kv("有效 FAT", "\(Int(result.fatigue.effectiveFat))")
            if !result.fatigue.fatPenalties.isEmpty {
                kv("缺陷折减", result.fatigue.defectForcedFail ? "强制判废" : "已计入降级")
                ForEach(result.fatigue.fatPenalties, id: \.self) { n in
                    Text("· \(n)").font(.caption2).foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 8)
                }
            }
            kv("应力幅 Δσ", "\(Int(result.fatigue.deltaSigma)) MPa (γ_Mf=\(result.fatigue.gammaMf))")
            kv("允许次数", fmt(result.fatigue.nAllowable))
            kv("需求次数", fmt(result.fatigue.nRequired))

            // 疲劳利用率环形仪表 + 结论（替代纯文本 KV，一眼看出是否满足）
            HStack(spacing: 16) {
                GaugeRing(value: result.fatigue.utilization, label: "疲劳利用率")
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("疲劳结论").font(.subheadline.bold()).foregroundStyle(Theme.textSecondary)
                    Text(result.fatigue.pass ? "满足设计要求 ✓" : (result.fatigue.defectForcedFail ? "缺陷强制判废 ✗" : "不满足 ✗"))
                        .font(.title3.bold())
                        .foregroundStyle(result.fatigue.pass ? Theme.ok : Theme.danger)
                        .shadow(color: (result.fatigue.pass ? Theme.ok : Theme.danger).opacity(0.6), radius: 6, y: 0)
                    Text("有效 FAT \(Int(result.fatigue.effectiveFat)) · Δσ \(Int(result.fatigue.deltaSigma)) MPa")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    if result.fatigue.defectForcedFail {
                        Text("裂纹/未熔合/未焊透等一票否决缺陷：疲劳不满足")
                            .font(.caption2).foregroundStyle(Theme.danger)
                    }
                }
                Spacer()
            }
            .techCard(glow: true)

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
                HStack(spacing: 8) {
                    Circle()
                        .fill(r.accepted == true ? Theme.ok : (r.accepted == false ? Theme.danger : Theme.warn))
                        .frame(width: 8, height: 8)
                    Text(r.label + (r.fatigueRelevant ? " [疲劳相关]" : ""))
                        .font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(r.accepted == true ? "通过" : (r.accepted == false ? "超差" : "未判定"))
                        .font(.caption.bold())
                        .foregroundStyle(r.accepted == true ? Theme.ok : (r.accepted == false ? Theme.danger : Theme.warn))
                    Text("| \(r.limit)")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .padding(8)
                .background(Theme.panelGradient, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke((r.accepted == false ? Theme.danger : Theme.cyan).opacity(0.2), lineWidth: 1))
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

            if let seams = store.weldSeams, !seams.isEmpty {
                Text("④ 逐细部评估（M3 · 3D 图上多锚点）").font(.subheadline.bold())
                ForEach(seams) { s in
                    let r = s.assessment.fatigue
                    let needsFP = (s.design.jointType == "cruciform" || s.design.jointType == "t_joint"
                                  || (s.design.weldType == "fillet" && s.design.loadCarrying))
                    let sevColor: Color = (!r.pass) ? Theme.danger
                        : (needsFP && !s.design.fullPenetration ? Theme.warn : Theme.ok)
                    let verdict = (!r.pass) ? (r.defectForcedFail ? "缺陷强制判废" : "不满足")
                        : (needsFP && !s.design.fullPenetration ? "满足（全熔透待确认）" : "满足")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Circle().fill(sevColor).frame(width: 8, height: 8)
                            Text("焊缝 #\(s.index) · \(r.detailName)").bold()
                            Spacer()
                            Text(verdict).font(.caption.bold()).foregroundStyle(sevColor)
                        }
                        Text("对比标准表：EN 1993-1-9 表 \(r.table ?? "—") ｜ 有效FAT \(Int(r.effectiveFat)) ｜ 利用率 \(String(format: "%.2f", r.utilization))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if !s.assessment.design.warnings.isEmpty {
                            Text("⚠ " + s.assessment.design.warnings.map { $0.title }.joined(separator: "；"))
                                .font(.caption2).foregroundStyle(Theme.warn)
                        }
                        Text(s.note).font(.caption2).foregroundStyle(Theme.textSecondary)
                        if !s.assessment.plan.isEmpty {
                            Divider().background(Theme.cyan.opacity(0.2))
                            Text("位置化建议（M5）").font(.caption2.bold()).foregroundStyle(Theme.textPrimary)
                            ForEach(s.assessment.plan, id: \.ruleId) { p in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        tag(p.priority)
                                        Text(p.title).font(.caption2.bold())
                                    }
                                    Text(p.action).font(.caption2).foregroundStyle(Theme.textSecondary)
                                    if let fat = p.raisesFatTo {
                                        Text("目标 FAT → \(fat)").font(.caption2.bold()).foregroundStyle(Theme.cyan)
                                    }
                                }
                            }
                        }
                    }
                    .techCard()
                }
                Text("提示：以上每条焊缝对应 3D 模型上的一个彩色锚点（绿=合理 / 红=不合理 / 黄=全熔透待确认）。各焊缝局部接头由几何自动判定，其余参数沿用设计表单；如需每焊缝人工差异化，请逐项修改表单后重评。")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
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
