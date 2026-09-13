// ReportGenerator.swift
// 用 PDFKit / UIGraphicsPDFRenderer 生成带标注的报告（iPad 端侧，离线）
import UIKit

enum ReportGenerator {
    static func buildPDF(_ r: AssessmentResult) -> Data {
        let fmt = UIGraphicsPDFRendererFormat()
        let page = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @72dpi
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: fmt)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 40
            let left: CGFloat = 40
            let w = page.width - 80

            func line(_ text: String, _ size: CGFloat = 11, bold: Bool = false, color: UIColor = .black) {
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
                (text as NSString).draw(in: CGRect(x: left, y: y, width: w, height: 20),
                    withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
                y += size + 6
            }

            line("焊缝疲劳合规检查报告", 20, bold: true, color: .systemBlue)
            line("依据 \(KnowledgeBank.standardsSummary)", 10)
            line("(标准均为程序内封装数据，离线生成)", 9)
            line("")
            line("【疲劳强度】", 13, bold: true)
            line("细节类别: \(r.fatigue.detailName) (\(r.fatigue.detailId))")
            line("基准 FAT: \(r.fatigue.baseFat)")
            for imp in r.fatigue.improvements {
                line("改善措施: \(imp.0) ×\(imp.1) → FAT \(Int(imp.2))")
            }
            line("有效 FAT: \(Int(r.fatigue.effectiveFat))")
            line("应力幅 Δσ: \(Int(r.fatigue.deltaSigma)) MPa (γ_Mf=\(r.fatigue.gammaMf))")
            line("允许/需求次数: \(r.fatigue.nAllowable) / \(r.fatigue.nRequired)")
            line("利用率: \(String(format: "%.3f", r.fatigue.utilization)) （>1 不满足）")
            line("结论: \(r.fatigue.pass ? "满足" : "不满足")", 12, bold: true,
                 color: r.fatigue.pass ? .systemGreen : .systemRed)
            line("")

            if !r.design.warnings.isEmpty {
                line("【① 识别出的不合理/疲劳不利细部】", 13, bold: true)
                for w in r.design.warnings {
                    line("[\(w.severity)] \(w.id) \(w.title): \(w.finding)", 10)
                }
                line("")
            }

            line("【② 表面缺陷 (ISO 5817)】", 13, bold: true)
            for imp in r.imperfections {
                let st = imp.accepted == true ? "通过" : (imp.accepted == false ? "超差" : "未判定")
                line("\(imp.label)\(imp.fatigueRelevant ? " [疲劳相关]" : ""): \(st) | \(imp.limit)", 10)
            }
            line("")

            line("【③ 改善建议（按优先级）】", 13, bold: true)
            for p in r.plan {
                let tgt = p.raisesFatTo != nil ? "（目标FAT≈\(p.raisesFatTo!))" : ""
                line("[\(p.priority)] \(p.ruleId) \(p.title): \(p.action) \(tgt)", 10)
            }
            line("")
            line("⚠ \(r.disclaimer)", 9, color: .systemGray)
        }
    }

    private static func fmt(_ n: Double) -> String { n.isFinite ? String(format: "%.3e", n) : "∞" }
}
