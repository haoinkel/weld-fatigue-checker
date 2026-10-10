// Views/WeldSpecView.swift
// 「焊接助手」标签页：焊规计算器（①）+ 焊工档案（②）+ 证书到期提醒（③）
// 借鉴 WeldersHub：工艺参数推荐 / 焊工档案 / 证书追踪。

import SwiftUI

struct WeldSpecView: View {
    @EnvironmentObject var store: Store

    // 焊规计算器输入
    @State private var process = "GMAW"
    @State private var material = "碳钢"
    @State private var joint = "对接"
    @State private var position = "PA 平焊"
    @State private var spec: WeldSpecResult? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "焊接工艺助手", systemImage: "wrench.and.screwdriver")
                Text("焊前给参数、焊后检缺陷，形成闭环。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)

                // MARK: - ① 焊规计算器
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "① 焊规计算器", systemImage: "slider.horizontal.2.square")
                    Picker("工艺", selection: $process) {
                        ForEach(WeldSpecCalculator.processes, id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    HStack(spacing: 10) {
                        Picker("材质", selection: $material) {
                            ForEach(WeldSpecCalculator.materials, id: \.self) { Text($0) }
                        }.pickerStyle(.menu)
                        Picker("接头", selection: $joint) {
                            ForEach(WeldSpecCalculator.joints, id: \.self) { Text($0) }
                        }.pickerStyle(.menu)
                    }
                    Picker("位置", selection: $position) {
                        ForEach(WeldSpecCalculator.positions, id: \.self) { Text($0) }
                    }.pickerStyle(.menu)
                    LabeledField("板厚 (mm)", value: $store.params.thickness)
                    Button {
                        spec = WeldSpecCalculator.recommend(process: process, material: material,
                                                            thickness: store.params.thickness, joint: joint,
                                                            position: position)
                    } label: {
                        Label("计算推荐参数", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TechButtonStyle())

                    if let s = spec { specResultCard(s) }
                }
                .techCard()

                // MARK: - ② 焊工档案 + ③ 证书提醒
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "② 焊工档案（报告署名 / 二维码）", systemImage: "person.badge.shield.check")
                    let w = $store.params.welder
                    Group {
                        TextField("焊工姓名", text: w.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("证书编号", text: w.certNo)
                            .textFieldStyle(.roundedBorder)
                        TextField("资质等级（如 ISO 9606 II / ASME 6G）", text: w.level)
                            .textFieldStyle(.roundedBorder)
                        TextField("评定标准", text: w.standard)
                            .textFieldStyle(.roundedBorder)
                        TextField("所属单位（可选）", text: w.company)
                            .textFieldStyle(.roundedBorder)
                        DatePicker("证书有效期",
                                   selection: Binding(
                                    get: { store.params.welder.expiry ?? Date() },
                                    set: { store.params.welder.expiry = $0 }),
                                   displayedComponents: .date)
                    }
                    // ③ 到期提醒
                    let st = store.params.welder.certExpiryStatus
                    HStack(spacing: 8) {
                        Image(systemName: st.state == "有效" ? "checkmark.seal.fill"
                                : (st.state == "已过期" ? "xmark.seal.fill" : "exclamationmark.triangle.fill"))
                            .foregroundStyle(st.state == "有效" ? Theme.ok
                                             : (st.state == "已过期" ? Theme.danger : Theme.warn))
                        let daysText: String = {
                            guard let d = st.daysLeft else { return "" }
                            return d >= 0 ? "（剩 \(d) 天）" : "（已超 \(-d) 天）"
                        }()
                        Text("资质状态：\(st.state)" + daysText)
                            .font(.subheadline.bold())
                            .foregroundStyle(st.state == "有效" ? Theme.ok
                                             : (st.state == "已过期" ? Theme.danger : Theme.warn))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((st.state == "有效" ? Theme.ok : (st.state == "已过期" ? Theme.danger : Theme.warn))
                                    .opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    if st.state != "有效" {
                        Text(st.state == "已过期" ? "证书已过期，须重新评定后方可施焊。"
                             : "证书即将到期，请尽快安排复评，避免影响合规追溯。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .techCard()
            }
            .padding()
        }
        .background(Theme.bgGradient.ignoresSafeArea())
        .navigationTitle("焊接助手")
    }

    // MARK: - 计算结果卡片
    @ViewBuilder
    private func specResultCard(_ s: WeldSpecResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("工艺/材质/接头/位置",
                "\(s.process) · \(s.material) · \(s.joint) · \(s.position) · \(String(format: "%.0f", s.thickness))mm")
            if let c = s.currentRange {
                row("焊接电流 I", "\(Int(c.lowerBound)) – \(Int(c.upperBound)) A")
            }
            if let v = s.voltageRange {
                row("电弧电压 U", "\(Int(v.lowerBound)) – \(Int(v.upperBound)) V")
            }
            row("焊接速度 v", "\(Int(s.travelSpeed.lowerBound)) – \(Int(s.travelSpeed.upperBound)) cm/min")
            if let wf = s.wireFeed {
                row("送丝速度", "\(String(format: "%.1f", wf.lowerBound)) – \(String(format: "%.1f", wf.upperBound)) m/min")
            }
            row("预热温度", "\(Int(s.preheat)) ℃")
            Divider().background(Theme.cyan.opacity(0.2))
            ForEach(s.notes, id: \.self) { n in
                Text("• \(n)").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(10)
        .background(Theme.panelTop.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
            Text(v).font(.subheadline.bold()).foregroundStyle(Theme.textPrimary).mono(14)
            Spacer()
        }
    }
}
