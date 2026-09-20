// Views/PhotoCheckView.swift
import SwiftUI
import PhotosUI
import ARKit

struct PhotoCheckView: View {
    @EnvironmentObject var store: Store
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var pickerItem: PhotosPickerItem?

    // iPad 双栏：右栏当前选中查看的缺陷行
    @State private var selectedImpIndex: Int?
    // 照片画布实测宽度（用于按图片宽高比计算画布高度）
    @State private var canvasW: CGFloat = 0

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

    // 阶段2：检测引擎开关；true=优先 Core ML 模型（未加载时自动回退 CV）
    @State private var useMLModel: Bool = MLDefectDetector.useMLModel

    // 实时相机扫描 sheet
    @State private var showLiveScan: Bool = false

    var body: some View {
        Group {
            if hSize == .regular {
                // iPad：双栏。左=操作与缺陷列表，右=照片大图+缺陷详情（点左侧缺陷行联动）
                NavigationSplitView {
                    sidebarContent
                        .navigationTitle("外观检查")
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
                } detail: {
                    detailContent
                }
            } else {
                // iPhone：单栏（照片内联）
                NavigationView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            headerSection
                            actionButtons
                            photoBlock
                            formSection
                        }
                        .padding()
                    }
                    .background(Theme.bgGradient.ignoresSafeArea())
                    .navigationTitle("外观检查")
                }
                .navigationViewStyle(.stack)
            }
        }
        .onChange(of: store.vision.plateThicknessMm) { _, _ in regradeAll() }
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

    // MARK: - iPad 双栏：左栏

    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                actionButtons
                formSection
            }
            .padding()
        }
        .background(Theme.bgGradient.ignoresSafeArea())
    }

    // MARK: - iPad 双栏：右栏（照片大图 + 缺陷详情）

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "照片标注与缺陷详情", systemImage: "photo.on.rectangle.angled")
                if store.photo != nil {
                    photoBlock
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.cyan.opacity(0.55))
                        Text("在左侧点「拍摄 / 选择照片」导入焊缝照片后，这里会显示大图与缺陷标注。\n点左侧缺陷行，这里会显示该缺陷详情。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .techCard()
                }
                selectedDefectSection
            }
            .padding()
        }
        .background(Theme.bgGradient.ignoresSafeArea())
        .navigationTitle("照片详情")
    }

    // MARK: - 顶部说明

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "① 焊缝外观检查", systemImage: "camera.viewfinder")
            Text("用 iPad 相机/相册选取焊缝照片，记录接头类型与表面缺陷。\n进阶：用 ARKit(LiDAR) 自动测得咬边/气孔等缺陷的真实尺寸，无需参照物。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - 拍照 / LiDAR / 实时扫描按钮

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("拍摄 / 选择照片", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity).padding(12)
                    .foregroundStyle(.black)
                    .background(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                               startPoint: .leading, endPoint: .trailing),
                                 in: Capsule())
                    .shadow(color: Theme.cyan.opacity(0.35), radius: 10, y: 0)
            }
            .onChange(of: pickerItem) { _, newItem in loadPhoto(from: newItem) }

            // 激光雷达自动识别焊缝及缺陷（仅 LiDAR 设备可用）
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                Button {
                    showLidarScan = true
                } label: {
                    Label("📡 LiDAR 自动识别焊缝", systemImage: "waveform")
                        .frame(maxWidth: .infinity).padding(12)
                        .foregroundStyle(.white)
                        .background(LinearGradient(colors: [Color.orange, Color(red: 1, green: 0.5, blue: 0.1)],
                                                   startPoint: .leading, endPoint: .trailing),
                                     in: Capsule())
                        .shadow(color: Color.orange.opacity(0.35), radius: 10, y: 0)
                }
                .sheet(isPresented: $showLidarScan) {
                    LiDARWeldScanSheet().environmentObject(store)
                }
            }

            // 实时相机预览识别（任意带摄像头的设备可用，不依赖 LiDAR）
            Button {
                showLiveScan = true
            } label: {
                Label("🎥 实时扫描识别", systemImage: "video.circle")
                    .frame(maxWidth: .infinity).padding(12)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [Theme.violet, Color(red: 0.5, green: 0.3, blue: 1.0)],
                                               startPoint: .leading, endPoint: .trailing),
                                 in: Capsule())
                    .shadow(color: Theme.violet.opacity(0.35), radius: 10, y: 0)
            }
            .fullScreenCover(isPresented: $showLiveScan) {
                LiveScanView().environmentObject(store)
            }
        }
    }

    // MARK: - 照片区（自动提示 + 标注开关 + 画布 + 提示）

    @ViewBuilder
    private var photoBlock: some View {
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
                                    .background(calMode ? Theme.cyan : Theme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(calMode ? .black : Theme.cyan)
                                }
                            }
                            if let ppm = store.photoPxPerMm {
                                Text("已标定：1 mm ≈ \(ppm, specifier: "%.2f") px（自动框尺寸按 mm 显示）")
                                    .font(.caption2).foregroundStyle(Theme.cyan)
                            } else {
                                Text("未标定：自动框尺寸暂以像素显示。点「📏 标定比例」在参照物上点两点并输入真实长度。")
                                    .font(.caption2).foregroundStyle(Theme.textSecondary)
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
                            .frame(maxWidth: .infinity)
                            .frame(height: canvasHeight(for: img))
                            .background(
                                GeometryReader { g in
                                    Color.clear
                                        .onAppear { canvasW = g.size.width }
                                        .onChange(of: g.size.width) { _, nw in canvasW = nw }
                                }
                            )
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(calMode ? Color.blue : (annoMode ? Color.red : Theme.cyan.opacity(0.25)), lineWidth: 2))

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
    }

    // MARK: - 表单：接头/荷载/板厚/检测引擎 + 改善措施 + 缺陷列表

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                        // 母材厚度 t：驱动 ISO 5817 评级（咬边/气孔按 t 比例判定）
                        // 默认从「设计输入」的厚度同步，也可在此直接覆盖。
                        HStack {
                            Text("母材厚度 t (mm)").font(.subheadline)
                            Spacer()
                            TextField("12", value: $store.vision.plateThicknessMm, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .keyboardType(.decimalPad)
                        }
                        Text("板厚用于把缺陷实测尺寸换算为 ISO 5817 质量等级（B/C/D）。改此值会即时重评所有已标注缺陷。")
                            .font(.caption2).foregroundStyle(.secondary)

                        // 阶段2：检测引擎开关（AI 模型 / CV 规则回退）
                        HStack {
                            Image(systemName: "brain").foregroundStyle(.purple)
                            Toggle("使用 AI 模型识别", isOn: $useMLModel)
                                .font(.subheadline)
                            Spacer()
                            Text(MLDefectDetector.isModelAvailable ? "模型已加载" : "未加载→CV")
                                .font(.caption2)
                                .foregroundStyle(MLDefectDetector.isModelAvailable ? .green : .secondary)
                        }
                        .onChange(of: useMLModel) { _, v in MLDefectDetector.useMLModel = v }
                    }

                    SectionTitle(text: "焊趾改善措施", systemImage: "wrench.and.screwdriver")
                    ForEach(KnowledgeBank.improvements, id: \.method) { m in
                        Toggle(m.label, isOn: Binding(
                            get: { store.vision.improvementsApplied.contains(m.method) },
                            set: { on in
                                if on { store.vision.improvementsApplied.append(m.method) }
                                else { store.vision.improvementsApplied.removeAll { $0 == m.method } }
                            }))
                    }

                    // 缺陷列表
                    SectionTitle(text: "表面缺陷（ISO 5817）", systemImage: "exclamationmark.triangle")
                    ForEach(Array(store.vision.imperfections.enumerated()), id: \.offset) { i, imp in
                        ImperfectionRow(
                            index: i,
                            isSelected: liDarTargetIndex == i,
                            isLocated: imp.location != nil,
                            detailSelected: selectedImpIndex == i,
                            onMeasureTap: { liDarTargetIndex = i },
                            onLocateTap: { annoTargetIndex = (annoTargetIndex == i ? -1 : i) },
                            onDelete: {
                                store.removeImperfection(at: i)
                                if selectedImpIndex == i { selectedImpIndex = nil }
                            }
                        )
                        .onTapGesture {
                            selectedImpIndex = (selectedImpIndex == i ? nil : i)
                        }
                    }
                    Button { store.addImperfection() } label: { Label("+ 添加缺陷", systemImage: "plus") }
                        .font(.caption)

                    // LiDAR 设备能力提示
                    LiDARCapabilityHint()
        }
    }

    // MARK: - 右栏：选中缺陷的详情卡

    @ViewBuilder
    private var selectedDefectSection: some View {
        if let i = selectedImpIndex, store.vision.imperfections.indices.contains(i) {
            defectDetailCard(i)
        } else {
            Text("提示：点左侧缺陷行，这里会显示该缺陷的详细信息（类型 / 尺寸 / ISO 5817 评级 / 限值）。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func defectDetailCard(_ i: Int) -> some View {
        let imp = store.vision.imperfections[i]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("缺陷 #\(i + 1) 详情").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                if let g = imp.grade {
                    let ok = imp.accepted ?? false
                    Text("ISO 5817 \(g)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((ok ? Theme.ok : Theme.danger).opacity(0.18), in: Capsule())
                        .foregroundStyle(ok ? Theme.ok : Theme.danger)
                }
            }
            let sizeText: String = {
                if let s = imp.sizeMm { return String(format: "%.2f mm", s) }
                if let ps = imp.pixelSize { return "\(Int(defectMeasurePx(type: imp.type, pixelSize: ps))) px（未标定）" }
                return "未测量"
            }()
            kvRow("类型", AnnotationMarker.shortLabel(imp.type))
            kvRow("实测尺寸", sizeText)
            if let lt = imp.limitText { kvRow("验收限值", lt) }
            kvRow("图上位置", imp.location.map { String(format: "x %.2f, y %.2f", $0.x, $0.y) } ?? "未标注")
            if let ps = imp.pixelSize { kvRow("像素尺寸", "\(Int(ps.width)) × \(Int(ps.height)) px") }
            if let ok = imp.accepted {
                Text(ok ? "✓ 当前板厚下合格" : "✗ 当前板厚下超差")
                    .font(.subheadline.bold())
                    .foregroundStyle(ok ? Theme.ok : Theme.danger)
            }
        }
        .techCard(glow: true)
    }

    private func kvRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(v).font(.subheadline).foregroundStyle(Theme.textPrimary).mono()
        }
    }

    /// 按图片宽高比与画布实测宽度计算画布高度
    /// （修复：GeometryReader 在 ScrollView 内只给 maxHeight 会高度塌陷，导致照片不可见、无法点按）
    private func canvasHeight(for img: UIImage) -> CGFloat {
        guard canvasW > 1 else { return 300 }
        let aspect = img.size.height / max(img.size.width, 1)
        return min(max(canvasW * aspect, 200), 480)
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: Data.self) { result in
            if case .success(let data) = result, let d = data, let ui = UIImage(data: d) {
                DispatchQueue.main.async {
                    store.photo = ui
                    calMode = false; calPts = []; annoMode = false
                    // 若用户在「设计输入」填了非默认板厚，默认带入照片评级
                    if store.vision.plateThicknessMm == 12 && store.design.plateThicknessMm != 12 {
                        store.vision.plateThicknessMm = store.design.plateThicknessMm
                    }
                    autoAnnotate(image: ui)
                }
            }
        }
    }

    /// 照片载入后自动检测缺陷区域，标注位置 + 尺寸（bbox + location），并按当前板厚做 ISO 5817 评级
    private func autoAnnotate(image: UIImage) {
        // 阶段2：优先 Core ML 实例分割，未加载模型时自动回退 CV 规则
        let detects = MLDefectDetector.detect(in: image)
        // 清掉上一张照片留下的自动框（保留手动添加的缺陷）
        store.vision.imperfections.removeAll { $0.bbox != nil }
        let ppm = store.photoPxPerMm
        let t = store.vision.plateThicknessMm
        for d in detects {
            // 余高/凸度按竖直(bbox 高)测量，其余取长边
            let longPx = defectMeasurePx(type: d.type, pixelSize: d.pixelSize)
            let sizeMm = ppm.map { Double(longPx) / $0 }
            let center = CGPoint(x: d.rect.midX, y: d.rect.midY)
            var imp = ImperfectionInput(type: d.type, sizeMm: sizeMm, poreMm: nil,
                                        location: center, bbox: d.rect, pixelSize: d.pixelSize)
            // 标定出 mm 且类型可判定时，立即评级
            if let s = sizeMm, d.type != "defect" {
                let g = ISO5817Grader.grade(type: d.type, sizeMm: s, t: t)
                imp.grade = g.level; imp.accepted = g.accepted; imp.limitText = g.limitText
            }
            store.vision.imperfections.append(imp)
        }
        let engine = MLDefectDetector.engineName
        store.autoState = detects.isEmpty
            ? "未检测到明显视觉异常（\(engine)）。仍建议按 ISO 5817 做无损检测复核。"
            : "已自动识别 \(detects.count) 处疑似缺陷（\(engine)），位置与尺寸已在照片上标注。" +
              (ppm == nil
                ? " 点「📏 标定比例」设定参照长度后，尺寸以 mm 显示并自动评级。"
                : " 已按板厚 \(String(format: "%.0f", t)) mm 做 ISO 5817 评级。")
    }

    /// 板厚变化后，重新评级所有已测得尺寸的缺陷
    private func regradeAll() {
        let t = store.vision.plateThicknessMm
        for i in store.vision.imperfections.indices {
            guard let s = store.vision.imperfections[i].sizeMm else { continue }
            let type = store.vision.imperfections[i].type
            guard type != "defect" else { continue }
            let g = ISO5817Grader.grade(type: type, sizeMm: s, t: t)
            store.vision.imperfections[i].grade = g.level
            store.vision.imperfections[i].accepted = g.accepted
            store.vision.imperfections[i].limitText = g.limitText
        }
    }

    /// 标定完成：写入 pxPerMm，并把已有自动框的像素尺寸换算成 mm
    private func applyCalibration(pxPerMm: Double) {
        store.photoPxPerMm = pxPerMm
        for i in store.vision.imperfections.indices where store.vision.imperfections[i].bbox != nil {
            if let ps = store.vision.imperfections[i].pixelSize {
                // 余高/凸度按竖直(bbox 高)换算，其余取长边
                store.vision.imperfections[i].sizeMm =
                    defectMeasurePx(type: store.vision.imperfections[i].type, pixelSize: ps) / pxPerMm
            }
        }
        store.autoState = "已标定（1 mm ≈ \(String(format: "%.2f", pxPerMm)) px）。自动框尺寸已按 mm 刷新并重新评级。"
        regradeAll()   // 标定换算出 mm 后，按当前板厚重评
    }
}

// MARK: - 缺陷行（含 LiDAR 按钮 + 图上定位）

struct ImperfectionRow: View {
    @EnvironmentObject var store: Store
    let index: Int
    let isSelected: Bool
    let isLocated: Bool
    var detailSelected: Bool = false   // 右栏详情当前展示的行（高亮）
    let onMeasureTap: () -> Void
    let onLocateTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("类型", selection: $store.vision.imperfections[index].type) {
                    Text("咬边").tag("undercut"); Text("气孔").tag("porosity")
                    Text("余高过大").tag("excess_weld_metal"); Text("焊瘤/满溢").tag("overlap")
                    Text("错边").tag("linear_misalignment"); Text("裂纹/弧坑裂纹").tag("crack")
                }
                .frame(maxWidth: .infinity)
                .onChange(of: store.vision.imperfections[index].type) { _, _ in regradeRow() }

                TextField("尺寸mm", value: $store.vision.imperfections[index].sizeMm, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .keyboardType(.decimalPad)
                    .onChange(of: store.vision.imperfections[index].sizeMm) { _, _ in regradeRow() }

                // ISO 5817 等级徽章
                if let g = store.vision.imperfections[index].grade {
                    let ok = store.vision.imperfections[index].accepted ?? false
                    Image(systemName: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? .green : .red)
                        .help(store.vision.imperfections[index].limitText ?? "")
                }

                // LiDAR 测量按钮
                Button(action: onMeasureTap) {
                    Image(systemName: "scope")
                        .imageScale(.medium)
                        .foregroundStyle(isSelected ? .white : Theme.cyan)
                        .padding(8)
                        .background(isSelected ? Theme.cyan : Theme.cyan.opacity(0.12), in: Circle())
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

            // 评级说明（仅在有评级结果时显示）
            if let g = store.vision.imperfections[index].grade,
               let lt = store.vision.imperfections[index].limitText {
                let ok = store.vision.imperfections[index].accepted ?? false
                Text("ISO 5817 \(g)： \(lt)")
                    .font(.caption2)
                    .foregroundStyle(ok ? .green : .red)
            }
        }
        .padding(8)
        .background(isSelected || detailSelected
                    ? AnyShapeStyle(Theme.cyan.opacity(0.14)) : AnyShapeStyle(Theme.panelGradient),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.cyan.opacity(detailSelected ? 0.65 : (isSelected ? 0.5 : 0.15)),
                    lineWidth: detailSelected ? 1.5 : 1))
    }

    /// 该行尺寸或类型变化后，按当前板厚重评该缺陷
    private func regradeRow() {
        guard store.vision.imperfections.indices.contains(index) else { return }
        let imp = store.vision.imperfections[index]
        guard imp.type != "defect" else {
            store.vision.imperfections[index].grade = nil
            store.vision.imperfections[index].accepted = nil
            store.vision.imperfections[index].limitText = nil
            return
        }
        if let s = imp.sizeMm {
            let g = ISO5817Grader.grade(type: imp.type, sizeMm: s, t: store.vision.plateThicknessMm)
            store.vision.imperfections[index].grade = g.level
            store.vision.imperfections[index].accepted = g.accepted
            store.vision.imperfections[index].limitText = g.limitText
        } else {
            store.vision.imperfections[index].grade = nil
            store.vision.imperfections[index].accepted = nil
            store.vision.imperfections[index].limitText = nil
        }
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
                        let longPx = imp.pixelSize.map { defectMeasurePx(type: imp.type, pixelSize: $0) } ?? 0
                        let sizeTxt = imp.sizeMm != nil
                            ? String(format: "%.1f mm", imp.sizeMm!)
                            : (longPx > 0 ? "\(Int(longPx)) px" : "")
                        let gradeTxt = imp.grade.map { " \($0)" } ?? ""
                        Text("#\(i + 1) \(AnnotationMarker.shortLabel(imp.type)) \(sizeTxt)\(gradeTxt)")
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
                    let lab = pxPerMm.map { String(format: "≈ %.1f mm", Double(px) / $0) } ?? "\(Int(px)) px"
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
        .background(Theme.panelGradient, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cyan.opacity(0.15), lineWidth: 1))
    }
}