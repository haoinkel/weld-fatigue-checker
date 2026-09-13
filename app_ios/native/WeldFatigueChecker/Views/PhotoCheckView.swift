// Views/PhotoCheckView.swift
import SwiftUI
import PhotosUI

struct PhotoCheckView: View {
    @EnvironmentObject var store: Store
    @State private var pickerItem: PhotosPickerItem?

    // LiDAR 自动识别焊缝 sheet
    @State private var showLidarScan: Bool = false

    // 当前要测量的缺陷行索引（-1 表示无）
    @State private var liDarTargetIndex: Int = -1

    // 图上标注模式：开启后点击照片即可放置/定位缺陷位置
    @State private var annoMode: Bool = false
    @State private var annoTargetIndex: Int = -1   // 点照片时定位到该缺陷；-1 表示新建

    // 参照物标定模式：点两点 + 输入真实长度 → 得到 pxPerMm，自动框尺寸转 mm
    @State private var calMode: Bool = false
    @State private var calPts: [CGPoint] = []
    @State private var showCalAlert: Bool = false
    @State private var calRealMm: String = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("① 焊缝外观检查（iPad 现场拍照）")
                        .font(.headline)
                    Text("用 iPad 相机/相册选取焊缝照片，记录接头类型与表面缺陷。\n进阶：用 ARKit(LiDAR) 自动测得咬边/气孔等缺陷的真实尺寸，无需参照物。")
                        .font(.caption).foregroundColor(.secondary)

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("拍摄 / 选择照片", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity).padding(10)
                            .background(Color.blue.opacity(0.12)).cornerRadius(10)
                    }
                    .onChange(of: pickerItem) { _, newItem in loadPhoto(from: newItem) }

                    // 激光雷达自动识别焊缝及缺陷（仅 LiDAR 设备可用）
                    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                        Button {
                            showLidarScan = true
                        } label: {
                            Label("📡 LiDAR 自动识别焊缝", systemImage: "waveform")
                                .frame(maxWidth: .infinity).padding(10)
                                .background(Color.orange.opacity(0.15)).cornerRadius(10)
                        }
                        .sheet(isPresented: $showLidarScan) {
                            LiDARWeldScanSheet().environmentObject(store)
                        }
                    }

                    if let img = store.photo {
                        VStack(alignment: .leading, spacing: 6) {
                            // 自动识别提示
                            if !store.autoState.isEmpty {
                                Text(store.autoState)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            }

                            HStack(spacing: 8) {
                                Toggle("🏷 图上标注模式", isOn: $annoMode)
                                    .font(.subheadline)
                                Spacer()
                                Button {
                                    calMode.toggle()
                                    if calMode { annoMode = false; calPts = [] }
                                } label: {
                                    Label("📏 标定比例", systemImage: "ruler")
                                        .font(.subheadline)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .background(calMode ? Color.blue : Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(calMode ? .white : .blue)
                                }
                            }
                            if let ppm = store.photoPxPerMm {
                                Text("已标定：1 mm ≈ \(ppm, specifier: "%.2f") px（自动框尺寸按 mm 显示）")
                                    .font(.caption2).foregroundStyle(.blue)
                            } else {
                                Text("未标定：自动框尺寸暂以像素显示。点「📏 标定比例」在参照物上点两点并输入真实长度。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }

                            AnnotationPhotoView(
                                image: img,
                                imperfections: $store.vision.imperfections,
                                annoMode: $annoMode,
                                targetIndex: $annoTargetIndex,
                                calMode: $calMode,
                                calPts: $calPts,
                                pxPerMm: store.photoPxPerMm,
                                onCalTap: { p in
                                    calPts.append(p)
                                    if calPts.count == 2 { calRealMm = ""; showCalAlert = true }
                                }
                            )
                            .frame(maxHeight: 440)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(calMode ? Color.blue : (annoMode ? Color.red : Color.clear), lineWidth: 2))

                            if calMode {
                                Text(calPts.count == 0
                                     ? "标定：在照片上的参照物（如焊脚、直尺）两端各点一下。"
                                     : calPts.count == 1
                                     ? "已点第 1 点，请点第 2 点。"
                                     : "已点两点，请输入该参照物的真实长度（mm）。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if annoMode {
                                Text(annoTargetIndex >= 0 && annoTargetIndex < store.vision.imperfections.count
                                     ? "点击照片，把位置标注到选中的缺陷 #\(annoTargetIndex + 1)；点击空白处取消选中。"
                                     : "点击照片任意位置即可新建一个带位置标注的缺陷；或先点缺陷行的 📍 再点照片，定位到指定缺陷。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Group {
                        Picker("接头类型", selection: $store.vision.jointType) {
                            Text("角焊缝").tag("fillet"); Text("对接焊缝").tag("butt")
                            Text("T型接头").tag("t_joint"); Text("十字接头").tag("cruciform")
                            Text("角接").tag("corner"); Text("搭接").tag("lap")
                        }
                        Picker("荷载方向", selection: $store.vision.loadingDirection) {
                            Text("横向").tag("transverse"); Text("纵向").tag("longitudinal")
                        }
                        Toggle("荷载经焊缝传递（承载）", isOn: $store.vision.loadCarrying)
                    }

                    Text("已实施的焊趾改善措施").font(.subheadline.bold())
                    ForEach(KnowledgeBank.improvements, id: \.method) { m in
                        Toggle(m.label, isOn: Binding(
                            get: { store.vision.improvementsApplied.contains(m.method) },
                            set: { on in
                                if on { store.vision.improvementsApplied.append(m.method) }
                                else { store.vision.improvementsApplied.removeAll { $0 == m.method } }
                            }))
                    }

                    // 缺陷列表
                    Text("表面缺陷（ISO 5817）").font(.subheadline.bold())
                    ForEach(Array(store.vision.imperfections.enumerated()), id: \.offset) { i, imp in
                        ImperfectionRow(
                            index: i,
                            isSelected: liDarTargetIndex == i,
                            isLocated: imp.location != nil,
                            onMeasureTap: { liDarTargetIndex = i },
                            onLocateTap: { annoTargetIndex = (annoTargetIndex == i ? -1 : i) },
                            onDelete: { store.removeImperfection(at: i) }
                        )
                    }
                    Button { store.addImperfection() } label: { Label("+ 添加缺陷", systemImage: "plus") }
                        .font(.caption)

                    // LiDAR 设备能力提示
                    LiDARCapabilityHint()
                }
                .padding()
            }
            .navigationTitle("外观检查")
        }
        // LiDAR 测距 sheet（连续模式：自动列出所有未填尺寸的缺陷，逐一测距）
        .sheet(isPresented: Binding(
            get: { liDarTargetIndex >= 0 },
            set: { if !$0 { liDarTargetIndex = -1 } }
        )) {
            if liDarTargetIndex >= 0 {
                LiDARMeasureSheet(initialIndex: liDarTargetIndex)
                    .environmentObject(store)
            }
        }
        // 标定弹窗：输入参照物真实长度（mm）
        .alert("标定参照物长度", isPresented: $showCalAlert) {
            TextField("真实长度 (mm)", text: $calRealMm)
                .keyboardType(.decimalPad)
            Button("取消", role: .cancel) { calPts = [] }
            Button("确定") {
                if let img = store.photo, calPts.count == 2,
                   let realMm = Double(calRealMm), realMm > 0 {
                    let a = calPts[0], b = calPts[1]
                    let px = hypot((b.x - a.x) * img.size.width, (b.y - a.y) * img.size.height)
                    applyCalibration(pxPerMm: px / realMm)
                }
                calPts = []
            }
        } message: {
            Text("请填入你刚才在照片上点选的两点之间的真实长度（毫米）。")
        }
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: Data.self) { result in
            if case .success(let data) = result, let ui = UIImage(data: data) {
                DispatchQueue.main.async {
                    store.photo = ui
                    calMode = false; calPts = []; annoMode = false
                    autoAnnotate(image: ui)
                }
            }
        }
    }

    /// 照片载入后自动检测缺陷区域，标注位置 + 尺寸（bbox + location）
    private func autoAnnotate(image: UIImage) {
        let detects = PhotoDefectDetector.detect(in: image)
        // 清掉上一张照片留下的自动框（保留手动添加的缺陷）
        store.vision.imperfections.removeAll { $0.bbox != nil }
        let ppm = store.photoPxPerMm
        for d in detects {
            let longPx = max(d.pixelSize.width, d.pixelSize.height)
            let sizeMm = ppm.map { Double(longPx) / $0 }
            let center = CGPoint(x: d.rect.midX, y: d.rect.midY)
            store.vision.imperfections.append(
                ImperfectionInput(type: d.type, sizeMm: sizeMm, poreMm: nil,
                                  location: center, bbox: d.rect, pixelSize: d.pixelSize)
            )
        }
        store.autoState = detects.isEmpty
            ? "未检测到明显视觉异常（启发式）。仍建议按 ISO 5817 做无损检测复核。"
            : "已自动识别 \(detects.count) 处疑似缺陷，位置与尺寸已在照片上标注。" +
              (ppm == nil ? " 点「📏 标定比例」设定参照长度后，尺寸将以 mm 显示。" : "")
    }

    /// 标定完成：写入 pxPerMm，并把已有自动框的像素尺寸换算成 mm
    private func applyCalibration(pxPerMm: Double) {
        store.photoPxPerMm = pxPerMm
        for i in store.vision.imperfections.indices where store.vision.imperfections[i].bbox != nil {
            if let ps = store.vision.imperfections[i].pixelSize {
                store.vision.imperfections[i].sizeMm = Double(max(ps.width, ps.height)) / pxPerMm
            }
        }
        store.autoState = "已标定（1 mm ≈ \(String(format: "%.2f", pxPerMm)) px）。自动框尺寸已按 mm 刷新。"
    }
}

// MARK: - 缺陷行（含 LiDAR 按钮 + 图上定位）

struct ImperfectionRow: View {
    @EnvironmentObject var store: Store
    let index: Int
    let isSelected: Bool
    let isLocated: Bool
    let onMeasureTap: () -> Void
    let onLocateTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("类型", selection: $store.vision.imperfections[index].type) {
                Text("咬边").tag("undercut"); Text("气孔").tag("porosity")
                Text("余高过大").tag("excess_weld_metal"); Text("焊瘤/满溢").tag("overlap")
                Text("错边").tag("linear_misalignment")
            }
            .frame(maxWidth: .infinity)

            TextField("尺寸mm", value: $store.vision.imperfections[index].sizeMm, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .keyboardType(.decimalPad)

            // LiDAR 测量按钮
            Button(action: onMeasureTap) {
                Image(systemName: "scope")
                    .imageScale(.medium)
                    .foregroundStyle(isSelected ? .white : .blue)
                    .padding(8)
                    .background(isSelected ? Color.blue : Color.blue.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("用 LiDAR 测距")
            .help("启动 LiDAR 测距，自动填入真实 mm")

            // 图上定位按钮（已定位时高亮）
            Button(action: onLocateTap) {
                Image(systemName: isLocated ? "mappin.circle.fill" : "mappin.circle")
                    .imageScale(.medium)
                    .foregroundStyle(isLocated ? .red : .secondary)
                    .padding(8)
                    .background(isLocated ? Color.red.opacity(0.12) : Color.clear, in: Circle())
            }
            .accessibilityLabel("在照片上标注位置")
            .help("开启「图上标注模式」后，点照片即可把此缺陷定位到该位置")

            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 照片标注叠层（自动框 + 位置点 + 标定叠层）

struct AnnotationPhotoView: View {
    let image: UIImage
    @Binding var imperfections: [ImperfectionInput]
    @Binding var annoMode: Bool
    @Binding var targetIndex: Int
    @Binding var calMode: Bool
    @Binding var calPts: [CGPoint]
    let pxPerMm: Double?
    var onCalTap: (CGPoint) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = Self.fittedRect(imageSize: image.size, viewSize: size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)

                // 自动识别框（橙色）：bbox + 类型 + 尺寸
                ForEach(Array(imperfections.enumerated()), id: \.offset) { i, imp in
                    if let bbox = imp.bbox {
                        let bx = rect.minX + bbox.minX * rect.width
                        let by = rect.minY + bbox.minY * rect.height
                        let bw = bbox.width * rect.width
                        let bh = bbox.height * rect.height
                        Rectangle()
                            .stroke(Color.orange, lineWidth: 2)
                            .frame(width: bw, height: bh)
                            .position(x: bx + bw / 2, y: by + bh / 2)
                        let longPx = imp.pixelSize.map { max($0.width, $0.height) } ?? 0
                        let sizeTxt = imp.sizeMm != nil
                            ? String(format: "%.1f mm", imp.sizeMm!)
                            : (longPx > 0 ? "\(Int(longPx)) px" : "")
                        Text("#\(i + 1) \(AnnotationMarker.shortLabel(imp.type)) \(sizeTxt)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                            .position(x: bx + bw / 2, y: max(rect.minY + 12, by - 10))
                    } else if let loc = imp.location {
                        // 手动定位点（红）
                        let x = rect.minX + loc.x * rect.width
                        let y = rect.minY + loc.y * rect.height
                        AnnotationMarker(index: i + 1, type: imp.type, sizeMm: imp.sizeMm)
                            .position(x: x, y: y)
                    }
                }

                // 标定叠层（蓝色）：两点 + 连线 + 长度
                ForEach(Array(calPts.enumerated()), id: \.offset) { _, p in
                    let x = rect.minX + p.x * rect.width
                    let y = rect.minY + p.y * rect.height
                    Circle().fill(Color.blue).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .position(x: x, y: y)
                }
                if calPts.count == 2 {
                    let a = calPts[0], b = calPts[1]
                    let ax = rect.minX + a.x * rect.width, ay = rect.minY + a.y * rect.height
                    let bx = rect.minX + b.x * rect.width, by = rect.minY + b.y * rect.height
                    Path { path in
                        path.move(to: CGPoint(x: ax, y: ay))
                        path.addLine(to: CGPoint(x: bx, y: by))
                    }
                    .stroke(Color.blue, lineWidth: 2)
                    let px = hypot((b.x - a.x) * image.size.width, (b.y - a.y) * image.size.height)
                    let lab = pxPerMm.map { "≈ \(px / $0, specifier: "%.1f") mm" } ?? "\(Int(px)) px"
                    Text(lab)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                        .position(x: (ax + bx) / 2, y: (ay + by) / 2 - 12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard rect.contains(point) else {
                    if annoMode && targetIndex >= 0 { targetIndex = -1 }
                    return
                }
                let nx = (point.x - rect.minX) / rect.width
                let ny = (point.y - rect.minY) / rect.height
                let loc = CGPoint(x: nx, y: ny)
                if calMode {
                    onCalTap(loc)
                    return
                }
                guard annoMode else { return }
                if targetIndex >= 0 && imperfections.indices.contains(targetIndex) {
                    imperfections[targetIndex].location = loc
                    targetIndex = -1
                } else {
                    imperfections.append(ImperfectionInput(type: "undercut", sizeMm: nil, poreMm: nil, location: loc))
                }
            }
        }
    }

    // 计算等比缩放后图片在视图中的实际显示矩形（含 letterbox 居中偏移）
    static func fittedRect(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        if imageAspect > viewAspect {
            let w = viewSize.width
            let h = w / imageAspect
            return CGRect(x: 0, y: (viewSize.height - h) / 2, width: w, height: h)
        } else {
            let h = viewSize.height
            let w = h * imageAspect
            return CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: h)
        }
    }
}

struct AnnotationMarker: View {
    let index: Int
    let type: String
    let sizeMm: Double?

    var body: some View {
        ZStack {
            Circle().fill(Color.red).frame(width: 26, height: 26)
            Text("\(index)").foregroundStyle(.white).font(.system(size: 13, weight: .bold))
        }
        .overlay(alignment: .bottom) {
            let txt = Self.shortLabel(type) + (sizeMm.map { "  \(Int($0))mm" } ?? "")
            Text(txt)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.red.opacity(0.85))
                .cornerRadius(5)
                .offset(y: 14)
        }
    }

    static func shortLabel(_ type: String) -> String {
        switch type {
        case "undercut": return "咬边"
        case "porosity": return "气孔"
        case "excess_weld_metal": return "余高过大"
        case "overlap": return "焊瘤"
        case "linear_misalignment": return "错边"
        default: return "缺陷"
        }
    }
}

// MARK: - 设备能力提示

struct LiDARCapabilityHint: View {
    @State private var lidarOK: Bool = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    @State private var meshOK: Bool = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: lidarOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(lidarOK ? .green : .orange)
            Text(lidarOK
                 ? "本设备支持 LiDAR 测距 — 点缺陷行 📐 按钮即可启用"
                 : "本设备不支持 LiDAR，请改用「参照物标定」(详见 PWA 路径)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}