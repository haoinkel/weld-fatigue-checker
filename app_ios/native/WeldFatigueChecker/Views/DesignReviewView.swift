// Views/DesignReviewView.swift
import SwiftUI

// 把可选 Double 的 Binding 转成非可选 Binding（缺省 0），供 LabeledField 使用
private func dblBinding(_ b: Binding<Double?>) -> Binding<Double> {
    Binding<Double>(get: { b.wrappedValue ?? 0 }, set: { b.wrappedValue = $0 })
}

struct DesignReviewView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("② 3D 设计合理性审查").font(.headline)
                    Text("填入从 3D 图 / CAD / LiDAR 识别的几何与传力属性，自动标出不合理细部并给改型建议。")
                        .font(.caption).foregroundColor(.secondary)

                    Picker("接头类型", selection: $store.design.jointType) {
                        Text("十字接头").tag("cruciform"); Text("T型接头").tag("t_joint")
                        Text("对接").tag("butt"); Text("角接").tag("fillet")
                        Text("搭接").tag("lap"); Text("角接(edge)").tag("corner")
                    }
                    Picker("焊缝类型", selection: $store.design.weldType) {
                        Text("角焊缝").tag("fillet"); Text("对接").tag("butt")
                    }
                    Picker("荷载方向", selection: $store.design.loadingDirection) {
                        Text("横向").tag("transverse"); Text("纵向").tag("longitudinal")
                    }
                    Toggle("荷载经焊缝传递", isOn: $store.design.loadCarrying)
                    Toggle("全熔透", isOn: $store.design.fullPenetration)
                    Toggle("打磨与母材齐平", isOn: $store.design.groundFlush)
                    LabeledField("附件长度(mm)", value: dblBinding($store.design.attachmentLengthMm))
                    LabeledField("板厚 t(mm)", value: $store.design.plateThicknessMm)
                    Toggle("梁端有切孔", isOn: $store.design.copeHole)
                    Toggle("位于拉应力区", isOn: $store.design.inTensionZone)
                    Picker("加劲肋端部", selection: $store.design.stiffenerEnd) {
                        Text("方形").tag("square"); Text("圆弧").tag("radius"); Text("斜面").tag("taper")
                    }
                    Picker("盖板端部", selection: $store.design.coverTermination) {
                        Text("直角终止").tag("abrupt"); Text("斜面过渡").tag("taper")
                    }
                    LabeledField("错边量 e(mm)", value: dblBinding($store.design.misalignmentMm))
                    Toggle("有引/收弧板", isOn: $store.design.runoffTabs)
                    Toggle("高周疲劳(>5e6)", isOn: $store.design.highCycle)
                }
                .padding()
            }
            .navigationTitle("3D 设计审查")
        }
    }
}

// 通用带标签数字输入
struct LabeledField: View {
    let label: String
    @Binding var value: Double
    init(_ label: String, value: Binding<Double>) { self.label = label; self._value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField(label, value: $value, format: .number).textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
        }
    }
}
