// Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TabView {
            PhotoCheckView().tabItem { Label("外观检查", systemImage: "camera") }
            DesignReviewView().tabItem { Label("细部设计", systemImage: "cube") }
            Model3DView().tabItem { Label("STEP 模型", systemImage: "square.stack.3d.up") }
            LoadsAndResultView().tabItem { Label("荷载/结果", systemImage: "function") }
            StandardsView().tabItem { Label("标准包", systemImage: "books.vertical") }
        }
        .accentColor(Theme.cyan)
        .preferredColorScheme(.dark)
    }
}

// 荷载参数 + 计算 + 结果
// iPad：双栏（左=荷载参数，右=评估结果）；iPhone：单栏内联。
struct LoadsAndResultView: View {
    @EnvironmentObject var store: Store
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showHistory = false

    var body: some View {
        Group {
            if hSize == .regular {
                NavigationSplitView {
                    paramsPane
                        .navigationTitle("荷载与结果")
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
                } detail: {
                    resultPane
                }
            } else {
                NavigationView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "③ 荷载参数", systemImage: "slider.horizontal.3")
                            Text("照片无法提供，须人工/仿真输入")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                            paramsFields
                            computeButton
                            if let r = store.result {
                                ResultView(result: r).techCard(glow: true)
                            }
                        }
                        .padding()
                    }
                    .background(Theme.bgGradient.ignoresSafeArea())
                    .navigationTitle("荷载与结果")
                }
                .navigationViewStyle(.stack)
            }
        }
    }

    // MARK: - iPad 左栏：荷载参数

    private var paramsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "③ 荷载参数", systemImage: "slider.horizontal.3")
                Text("照片无法提供，须人工/仿真输入")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                paramsFields
                computeButton
            }
            .padding()
        }
        .background(Theme.bgGradient.ignoresSafeArea())
    }

    // MARK: - iPad 右栏：评估结果（点左侧「计算评估」后在此显示）

    private var resultPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let r = store.result {
                    ResultView(result: r).techCard(glow: true)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "function")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.cyan.opacity(0.55))
                        Text("在左侧填入荷载参数后点「计算评估」，\n评估结果会显示在这里。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                    .techCard()
                }
            }
            .padding()
        }
        .background(Theme.bgGradient.ignoresSafeArea())
        .navigationTitle("评估结果")
    }

    private var paramsFields: some View {
        Group {
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
        }
    }

    private var computeButton: some View {
        HStack(spacing: 10) {
            Button { store.run() } label: {
                if store.isComputing {
                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                } else {
                    Label("计算评估", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(TechButtonStyle())
            .disabled(store.isComputing)        // C1：评估进行中禁止重复触发
            .accessibilityLabel("计算疲劳评估")
            .accessibilityHint(store.isComputing ? "评估计算中，请稍候" : "根据荷载参数与已识别缺陷计算疲劳利用率")

            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock")
            }
            .buttonStyle(TechButtonStyle(filled: false))
            .accessibilityLabel("查看检测历史记录")
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet().environmentObject(store)
        }
    }
}

// 注：LabeledField 的定义统一放在 DesignReviewView.swift，本文件仅使用（模块级可见）。
