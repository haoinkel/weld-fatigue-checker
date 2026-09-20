// ReportGenerator.swift
// 评估报告导出：PDF（UIGraphicsPDFRenderer，多页）+ Word（HTML .doc，Word/Pages 均可打开）
// iPad 端侧离线生成；导出写入临时文件并返回文件 URL（带文件名，系统分享/预览才正确）。
import UIKit

enum ReportGenerator {

    // MARK: - 对外接口

    /// 生成 PDF 并写入临时文件，返回可分享的文件 URL
    static func exportPDF(_ r: AssessmentResult, fileName: String = "焊缝疲劳评估报告.pdf") -> URL? {
        let data = buildPDF(r)
        return writeTemp(data: data, fileName: fileName)
    }

    /// 生成 Word（HTML .doc）并写入临时文件，返回可分享的文件 URL
    static func exportWord(_ r: AssessmentResult, fileName: String = "焊缝疲劳评估报告.doc") -> URL? {
        let html = buildWordHTML(r)
        guard let data = html.data(using: .utf8) else { return nil }
        return writeTemp(data: data, fileName: fileName)
    }

    // MARK: - PDF 渲染（支持自动分页与折行）

    static func buildPDF(_ r: AssessmentResult) -> Data {
        let fmt = UIGraphicsPDFRendererFormat()
        let page = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @72dpi
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: fmt)
        return renderer.pdfData { ctx in
            var y: CGFloat = 40
            let left: CGFloat = 40
            let w = page.width - 80

            // 折行文本：测量实际高度；超出页底自动换页
            func line(_ text: String, _ size: CGFloat = 11, bold: Bool = false, color: UIColor = .black) {
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
                let bounding = (text as NSString).boundingRect(
                    with: CGSize(width: w, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
                let h = ceil(bounding.height)
                if y + h > page.height - 40 {          // 换页
                    ctx.beginPage()
                    y = 40
                }
                (text as NSString).draw(in: CGRect(x: left, y: y, width: w, height: h), withAttributes: attrs)
                y += h + 6
            }

            ctx.beginPage()
            line("焊缝疲劳合规检查报告", 20, bold: true, color: .systemBlue)
            line("依据 \(KnowledgeBank.standardsSummary)", 10)
            line("(标准均为程序内封装数据，离线生成)", 9)
            line("")
            line("【疲劳强度】", 13, bold: true)
            line("细节类别: \(r.fatigue.detailName) (\(r.fatigue.detailId))")
            line("基准 FAT: \(r.fatigue.baseFat)")
            for imp in r.fatigue.improvements {
                line("改善措施: \(imp.label) ×\(imp.factor) → FAT \(Int(imp.fatAfter))")
            }
            line("有效 FAT: \(Int(r.fatigue.effectiveFat))")
            line("应力幅 Δσ: \(Int(r.fatigue.deltaSigma)) MPa (γ_Mf=\(r.fatigue.gammaMf))")
            line("允许/需求次数: \(fmtNum(r.fatigue.nAllowable)) / \(fmtNum(r.fatigue.nRequired))")
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

    // MARK: - Word（HTML .doc；Word / Pages / WPS 均可打开）

    static func buildWordHTML(_ r: AssessmentResult) -> String {
        var s = """
        <html><head><meta charset="utf-8"><title>焊缝疲劳合规检查报告</title>
        <style>
        body{font-family:"Microsoft YaHei","PingFang SC",sans-serif;font-size:11pt;margin:40px;}
        h1{color:#1a6fc4;font-size:18pt;} h2{font-size:13pt;margin-top:18px;}
        table{border-collapse:collapse;width:100%;} td{border:1px solid #999;padding:5px 8px;font-size:10.5pt;}
        .pass{color:#0a0;font-weight:bold;} .fail{color:#c00;font-weight:bold;}
        .note{color:#888;font-size:9pt;}
        </style></head><body>
        <h1>焊缝疲劳合规检查报告</h1>
        <p>依据 \(KnowledgeBank.standardsSummary)<br><span class="note">标准均为程序内封装数据，离线生成。</span></p>

        <h2>一、疲劳强度</h2>
        <table>
        <tr><td>细节类别</td><td>\(escape(r.fatigue.detailName)) (\(escape(r.fatigue.detailId)))</td></tr>
        <tr><td>基准 FAT</td><td>\(r.fatigue.baseFat)</td></tr>
        """
        for imp in r.fatigue.improvements {
            s += "<tr><td>改善措施</td><td>\(escape(imp.label)) ×\(imp.factor) → FAT \(Int(imp.fatAfter))</td></tr>"
        }
        s += """
        <tr><td>有效 FAT</td><td>\(Int(r.fatigue.effectiveFat))</td></tr>
        <tr><td>应力幅 Δσ</td><td>\(Int(r.fatigue.deltaSigma)) MPa (γ_Mf=\(r.fatigue.gammaMf))</td></tr>
        <tr><td>允许次数</td><td>\(fmtNum(r.fatigue.nAllowable))</td></tr>
        <tr><td>需求次数</td><td>\(fmtNum(r.fatigue.nRequired))</td></tr>
        <tr><td>利用率</td><td>\(String(format: "%.3f", r.fatigue.utilization))（&gt;1 不满足）</td></tr>
        <tr><td>结论</td><td class="\(r.fatigue.pass ? "pass" : "fail")">\(r.fatigue.pass ? "满足 ✓" : "不满足 ✗")</td></tr>
        </table>

        <h2>二、① 识别出的不合理/疲劳不利细部</h2>
        """
        if r.design.warnings.isEmpty {
            s += "<p>（无）</p>"
        } else {
            s += "<table><tr><td>编号</td><td>等级</td><td>问题</td><td>说明</td></tr>"
            for w in r.design.warnings {
                s += "<tr><td>\(escape(w.id))</td><td>\(escape(w.severity))</td><td>\(escape(w.title))</td><td>\(escape(w.finding))</td></tr>"
            }
            s += "</table>"
        }

        s += "<h2>三、② 表面缺陷（ISO 5817）</h2>"
        if r.imperfections.isEmpty {
            s += "<p>（无）</p>"
        } else {
            s += "<table><tr><td>缺陷</td><td>判定</td><td>限值/实测</td></tr>"
            for imp in r.imperfections {
                let st = imp.accepted == true ? "通过" : (imp.accepted == false ? "超差" : "未判定")
                let cls = imp.accepted == true ? "pass" : (imp.accepted == false ? "fail" : "")
                s += "<tr><td>\(escape(imp.label))\(imp.fatigueRelevant ? " [疲劳相关]" : "")</td>"
                    + "<td class=\"\(cls)\">\(st)</td><td>\(escape(imp.limit))</td></tr>"
            }
            s += "</table>"
        }

        s += "<h2>四、③ 改善建议（按优先级）</h2><table><tr><td>优先级</td><td>编号</td><td>问题</td><td>措施</td></tr>"
        for p in r.plan {
            let tgt = p.raisesFatTo != nil ? "（目标FAT≈\(p.raisesFatTo!))" : ""
            s += "<tr><td>\(escape(p.priority))</td><td>\(escape(p.ruleId))</td><td>\(escape(p.title))</td>"
                + "<td>\(escape(p.action))\(escape(tgt))</td></tr>"
        }
        s += """
        </table>
        <p class="note">⚠ \(escape(r.disclaimer))</p>
        </body></html>
        """
        return s
    }

    // MARK: - 工具

    /// 写入临时文件（同 名 先删后写，保证分享带正确文件名与扩展名）
    private static func writeTemp(data: Data, fileName: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func fmtNum(_ n: Double) -> String {
        n.isFinite ? String(format: "%.3e", n) : "∞"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
