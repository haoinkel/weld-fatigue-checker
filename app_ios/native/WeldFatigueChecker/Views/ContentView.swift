// Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TabView {
            PhotoCheckView().tabItem { Label("外观检查", systemImage: "camera") }
            DesignReviewView().tabItem { Label("3D 设计", systemImage: "cube") }
            Model3DView().tabItem { Label("3D 模型", systemImage: "square.stack.3d.up") }
            LoadsAndResultView().tabItem { Label("荷载/结果", systemImage: "function") }
            StandardsView().tabItem { Label("标准包", systemImage: "books.vertical") }
        }
        .accentColor(.blue)
    }
}

// 荷载参数 + 计算 + 结果
struct LoadsAndResultView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("③ 荷载参数（照片无法提供，须人工/仿真输入）")
                        .font(.headline)
                    Picker("判定依据", selection: $store.mode) {
                        Text("综合：3D 定FAT+照片定缺陷").tag("both")
                        Text("仅照片").tag("photo")
                        Text("仅 3D 设计").tag("design")
                    }.pickerStyle(.segmented)

                    LabeledField("应力幅 Δσ (MPa)", value: $store.params.deltaSigma)
                    LabeledField("需求循环次数 N", value: $store.params.nRequired)
                    Picker("疲劳分项系数 γ_Mf", selection: $store.params.gammaMf) {
                        Text("1.0（默认）").tag(1.0); Text("1.15（详细）").tag(1.15); Text("1.35（简化）").tag(1.35)
                    }

                    Button { store.run() } label: {
                        Text("计算评估").frame(maxWidth: .infinity).padding(10)
                    }
                    .buttonStyle(.borderedProminent)

                    if let r = store.result {
                        ResultView(result: r)
                    }
                }
                .padding()
            }
            .navigationTitle("荷载与结果")
        }
    }
}

// 注：LabeledField 的定义统一放在 DesignReviewView.swift，本文件仅使用（模块级可见）。
