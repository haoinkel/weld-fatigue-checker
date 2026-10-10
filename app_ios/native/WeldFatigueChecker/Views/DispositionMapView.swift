// Views/DispositionMapView.swift
// 缺陷处置地图（RQMS 思路：沿焊缝归集缺陷 + 四色处置判定）
// 把当前识别到的缺陷按 bbox 中心水平位置排成一条「焊缝带」，直观看到缺陷分布与处置态。

import SwiftUI

struct DispositionMapView: View {
    let imperfections: [ImperfectionInput]
    @Environment(\.dismiss) private var dismiss

    // 带 bbox 的缺陷（位置可映射）；按中心 x 排序便于沿焊缝排布
    private var plotted: [(idx: Int, imp: ImperfectionInput, cx: CGFloat)] {
        imperfections.enumerated().compactMap { i, imp in
            guard let b = imp.bbox else { return nil }
            return (i, imp, b.midX)
        }.sorted { $0.cx < $1.cx }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 处置图例
                    HStack(spacing: 14) {
                        ForEach(Disposition.allCases, id: \.self) { d in
                            HStack(spacing: 5) {
                                Circle().fill(d.color).frame(width: 12, height: 12)
                                Text(d.label).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }

                    // 焊缝带位置地图
                    VStack(alignment: .leading, spacing: 6) {
                        Text("焊缝缺陷位置带（按水平位置排序）")
                            .font(.subheadline.bold()).foregroundStyle(Theme.textPrimary)
                        GeometryReader { geo in
                            let h: CGFloat = 46
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.panelTop)
                                    .frame(height: h)
                                // 刻度
                                ForEach(0..<10) { k in
                                    Rectangle().fill(Theme.cyan.opacity(0.15))
                                        .frame(width: 1, height: h)
                                        .position(x: geo.size.width * (CGFloat(k) / 10), y: h / 2)
                                }
                                // 缺陷点
                                ForEach(plotted, id: \.idx) { p in
                                    let x = geo.size.width * p.cx
                                    Circle().fill(p.imp.disposition.color)
                                        .frame(width: 16, height: 16)
                                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                                        .position(x: x, y: h / 2)
                                        .overlay(
                                            Text("\(p.idx + 1)")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .position(x: x, y: 10)
                                        )
                                }
                            }
                            .frame(height: h)
                        }
                        .frame(height: 60)
                        Text("⚠ 位置基于当前照片 bbox 相对坐标；多张照片/长焊缝需分别查看。")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    .techCard()

                    // 处置清单
                    SectionTitle(text: "处置清单（\(imperfections.count) 项）", systemImage: "list.bullet")
                    if imperfections.isEmpty {
                        Text("暂无缺陷数据。请先在照片页识别或手动添加缺陷。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(Array(imperfections.enumerated()), id: \.offset) { i, imp in
                            HStack(spacing: 10) {
                                Circle().fill(imp.disposition.color)
                                    .frame(width: 12, height: 12)
                                Text("#\(i + 1) \(AnnotationMarker.shortLabel(imp.type))")
                                    .font(.subheadline).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if let s = imp.sizeMm {
                                    Text(String(format: "%.1f mm", s)).font(.caption).mono(13)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Text(imp.disposition.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(imp.disposition.color)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(imp.disposition.color.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding()
            }
            .background(Theme.bgGradient.ignoresSafeArea())
            .navigationTitle("缺陷处置地图")
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}
