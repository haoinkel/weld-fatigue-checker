// Views/StandardsView.swift
// 标准包管理（开放接口）：查看内置标准、切换启用、导入/升级/移除外部标准
// 与 PWA 端 js/standard_registry.js、Python 端 engine/standard_registry.py 行为一致

import SwiftUI
import UniformTypeIdentifiers

struct StandardsView: View {
    @State private var packs: [StandardPackRegistry.PackInfo] = []
    @State private var activeFatigue: String = ""
    @State private var activeAccept: String = ""
    @State private var message: String = ""
    @State private var showImporter = false
    @State private var showSchema = false

    private let reg = StandardPackRegistry.shared

    var body: some View {
        NavigationView {
            Form {
                // ① 当前启用的标准
                Section(header: Text("当前启用"), footer: Text(reg.standardsSummary).font(.caption2)) {
                    Picker("疲劳标准 (FAT/S-N)", selection: $activeFatigue) {
                        ForEach(packs.filter { $0.kind == "fatigue" }, id: \.id) { p in
                            Text(verbatim: "\(p.code)｜\(p.title)").tag(p.id)
                        }
                    }
                    .onChange(of: activeFatigue) { newValue in apply(kind: "fatigue", id: newValue) }

                    Picker("验收标准 (表面缺陷)", selection: $activeAccept) {
                        ForEach(packs.filter { $0.kind == "acceptance" }, id: \.id) { p in
                            Text(verbatim: "\(p.code)｜\(p.title)").tag(p.id)
                        }
                    }
                    .onChange(of: activeAccept) { newValue in apply(kind: "acceptance", id: newValue) }
                }

                // ② 已注册标准包
                Section(header: Text("已注册标准包 (\(packs.count))")) {
                    ForEach(packs) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(verbatim: p.code).font(.subheadline.bold())
                                    Tag(text: p.isBuiltin ? "内置" : "导入",
                                        color: p.isBuiltin ? .secondary : .green)
                                    Tag(text: p.verified ? "已校核" : "待校核",
                                        color: p.verified ? .green : .orange)
                                }
                                Text(verbatim: p.title).font(.caption).foregroundColor(.secondary)
                                Text(verbatim: "\(p.kind == "fatigue" ? "疲劳" : "验收") · v\(p.version)")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if !p.isBuiltin {
                                Button(role: .destructive) {
                                    let r = reg.removeUserPack(p.id)
                                    message = (r.ok ? "✓ " : "✗ ") + r.message
                                    reload()
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                // ③ 导入 / 升级
                Section(header: Text("补充或升级标准"),
                        footer: Text("把符合 schema 的 .pack.json 通过 AirDrop 或「文件」App 放入本 App 的 StandardPacks 目录，"
                                     + "或直接在此选择文件导入。同 pack_id 再次导入即为升级。").font(.caption2)) {
                    Button { showImporter = true } label: {
                        Label("导入标准包 (.pack.json)", systemImage: "square.and.arrow.down")
                    }
                    Button { let n = reg.rescanUserPacks(); reload()
                        message = "已重新扫描，共 \(n) 个用户标准包" } label: {
                        Label("重新扫描 StandardPacks 目录", systemImage: "arrow.clockwise")
                    }
                    Button { UIPasteboard.general.string = blankTemplateJSON()
                        message = "空白模板已复制到剪贴板（可粘贴到文本编辑器后填表）" } label: {
                        Label("复制标准包空白模板", systemImage: "doc.on.doc")
                    }
                }

                // ④ 字段说明
                Section(header: Text("标准包字段说明（给写标准的人）")) {
                    Button { showSchema.toggle() } label: {
                        Label(showSchema ? "收起" : "展开", systemImage: "chevron.right")
                    }
                    if showSchema { Text(schemaText).font(.system(.caption, design: .monospaced)) }
                }

                if !message.isEmpty {
                    Section(header: Text("操作结果")) { Text(message).font(.caption) }
                }
            }
            .navigationTitle("标准包")
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .standardsDidChange)) { _ in reload() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType.json, UTType(filenameExtension: "pack") ?? UTType.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let u = urls.first else { return }
                    let accessed = u.startAccessingSecurityScopedResource()
                    let r = reg.importPack(fileURL: u)
                    if accessed { u.stopAccessingSecurityScopedResource() }
                    message = (r.ok ? "✓ " : "✗ ") + r.message
                        + (r.warnings.isEmpty ? "" : "\n⚠ " + r.warnings.joined(separator: "；"))
                    reload()
                case .failure(let e):
                    message = "✗ 选择文件失败：\(e.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 逻辑

    private func reload() {
        packs = reg.list()
        activeFatigue = reg.activeId("fatigue") ?? ""
        activeAccept = reg.activeId("acceptance") ?? ""
    }

    private func apply(kind: String, id: String) {
        guard !id.isEmpty else { return }
        do { try reg.setActive(kind: kind, packId: id); message = "✓ 已切换 \(kind) → \(id)" }
        catch { message = "✗ \(error.localizedDescription)"; reload() }
    }

    private var schemaText: String {
        """
        必填：
          schema_version  "1.0"
          pack_id         全程序唯一 ID（小写/数字/连字符）
          kind            "fatigue"（疲劳 FAT/S-N）或 "acceptance"（表面验收）
          code            标准代号，如 "GB 50017-2017"
          title           标准名称
          version         版本

        疲劳包还需：
          defaults:            { ref_N, gamma_mf_default, sn_m }
          detail_categories:   [ { id, fat, name } ]        细节类别 → FAT(MPa)
          improvement_methods: [ { method, label, factor, max_fat }]

        验收包还需：
          levels:         { "B": "最高", "C": "中等", "D": "较低" }
          imperfections:  [ { type, label, fatigue_relevant,
                              limits: { B: { value, ref:"t", max_abs } , ... } } ]

        可选：region / language / verified / verification_note / sn_curve
        规则：同 ID 再导入=升级；内置包不可移除；移除后回退内置默认；选择即生效。
        """
    }

    private func blankTemplateJSON() -> String {
        """
        {
          "schema_version": "1.0",
          "pack_id": "my-standard-1",
          "kind": "fatigue",
          "code": "XXX 0000-2025",
          "title": "标准中文名",
          "region": "CN",
          "version": "2025",
          "language": "zh",
          "verified": false,
          "verification_note": "数值来源与校核说明",
          "defaults": { "ref_N": 2000000, "gamma_mf_default": 1.0, "sn_m": 3 },
          "detail_categories": [ { "id": "X1", "fat": 100, "name": "示例细节" } ],
          "improvement_methods": [
            { "method": "toe_grinding", "label": "焊趾打磨", "factor": 1.3, "max_fat": 125 }
          ]
        }
        """
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18)).foregroundColor(color)
            .clipShape(Capsule())
    }
}
