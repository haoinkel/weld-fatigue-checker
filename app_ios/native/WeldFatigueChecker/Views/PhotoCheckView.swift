// Views/PhotoCheckView.swift
import SwiftUI
import PhotosUI
import ARKit

struct PhotoCheckView: View {
    @EnvironmentObject var store: Store
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var pickerItem: PhotosPickerItem?
    // 系统相机拍照（fullScreenCover）
    @State private var showCamera: Bool = false

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

    // 焊缝区域(ROI)框选模式：在照片上拖拽出焊缝范围，检测只在该区域内生效
    @State private var roiMode: Bool = false

    // 阶段2：检测引擎开关；true=优先 Core ML 模型（未加载时自动回退 CV）
    @State private var useMLModel: Bool = MLDefectDetector.useMLModel

    // 实时相机扫描 sheet
    @State private var showLiveScan: Bool = false

    // 检测历史 sheet
    @State private var showHistory: Bool = false

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
                    // iPhone 单栏同样含照片画布：框选模式下禁滚动，防拖拽被滚动吞掉
                    .scrollDisabled(roiMode)
                }
                .navigationViewStyle(.stack)
            }
        }
        .onChange(of: store.vision.plateThicknessMm) { _, _ in regradeAll() }
        // 焊缝区域(ROI)变化后，按新区域重新自动识别（框选即触发）
        .onChange(of: store.vision.weldSeamROIs) { _, _ in
            if let img = store.photo { autoAnnotate(image: img) }
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
        // 框选焊缝模式下禁用本栏滚动，保证拖拽全部落到照片画布上
        .scrollDisabled(roiMode)
    }

    // MARK: - 顶部说明

    // 工作流进度：根据当前状态推导用户走到了哪一步（0-based；-1 尚未开始）
    private var workflowCurrent: Int {
        let hasPhoto = store.photo != nil
        let roiSet   = !store.vision.weldSeamROIs.isEmpty
        let hasDef   = !store.vision.imperfections.isEmpty
        let calib    = store.photoPxPerMm != nil
        let computed = store.result != nil
        let done = [hasPhoto, roiSet, hasDef, calib, computed].enumerated()
            .reduce(0) { $1.element ? $0 + 1 : $0 }
        // 返回「已到达」的最大步骤索引（连续完成的步数 - 1）
        return done - 1
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "① 焊缝外观检查", systemImage: "camera.viewfinder")
            Text("用 iPad 相机/相册选取焊缝照片，记录接头类型与表面缺陷。\n进阶：用 ARKit(LiDAR) 自动测得咬边/气孔等缺陷的真实尺寸，无需参照物。")
                .font(.caption).foregroundStyle(Theme.textSecondary)

            // 工作流步骤引导：让用户按正确顺序操作，避免漏掉「框选焊缝」等关键步骤
            StepBar(steps: ["导入照片", "框选焊缝", "自动识别", "标定评级", "荷载计算"],
                    current: workflowCurrent)
                .padding(8)
                .background(Theme.panelGradient, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.cyan.opacity(0.18), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("工作流进度：已完成 \(max(workflowCurrent, 0)) / 5 步")

            // 快捷操作：严重度排序 / 保存快照 / 历史
            HStack(spacing: 8) {
                Button {
                    store.sortImperfections()
                } label: {
                    Label("按严重度排序", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("按严重度排序缺陷列表")
                .disabled(store.vision.imperfections.count < 2)

                Button {
                    store.snapshotPhoto()
                } label: {
                    Label("保存快照", systemImage: "camera.on.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("保存当前缺陷快照到历史")

                Button {
                    showHistory = true
                } label: {
                    Label("历史", systemImage: "clock")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("查看检测历史记录")
            }
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet().environmentObject(store)
        }
    }

    // MARK: - 拍照 / LiDAR / 实时扫描按钮

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 拍照：调用系统相机（此前只有相册入口，用户反馈缺拍照选项）
            Button {
                showCamera = true
            } label: {
                Label("拍照", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity).padding(12)
                    .foregroundStyle(.black)
                    .background(LinearGradient(colors: [Theme.cyan, Theme.blue],
                                               startPoint: .leading, endPoint: .trailing),
                                 in: Capsule())
                    .shadow(color: Theme.cyan.opacity(0.35), radius: 10, y: 0)
            }
            .accessibilityLabel("拍摄焊缝照片")
            .accessibilityHint("调用系统相机拍摄焊缝照片")
            .fullScreenCover(isPresented: $showCamera) {
                SystemCameraPicker { img in applyNewPhoto(img) }
                    .ignoresSafeArea()
            }

            // 从相册选择
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("从相册选择", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity).padding(12)
                    .foregroundStyle(Theme.cyan)
                    .background(Theme.cyan.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel("从相册选择焊缝照片")
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
                .accessibilityLabel("使用 LiDAR 自动识别焊缝与缺陷")
                .accessibilityHint("仅支持 LiDAR 的设备；自动框选焊缝并测得真实尺寸")
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
            .accessibilityLabel("打开实时相机扫描识别")
            .accessibilityHint("任意带摄像头的设备；实时框出缺陷")
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
                                .accessibilityLabel("标定比例")
                                .accessibilityHint("在照片参照物上点两点并输入真实长度，得到毫米换算")
                                Button {
                                    roiMode.toggle()
                                    if roiMode { annoMode = false; calMode = false; calPts = [] }
                                } label: {
                                Label("🎯 框选焊缝", systemImage: "viewfinder")
                                    .font(.subheadline)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(roiMode ? Color.green : Theme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(roiMode ? .black : Theme.cyan)
                                }
                                .accessibilityLabel("框选焊缝区域")
                                .accessibilityHint("在照片上从左上向右下拖拽框住焊缝范围，可连续框选多处，检测只在框内生效")
                                if !store.vision.weldSeamROIs.isEmpty {
                                    Button {
                                        store.vision.weldSeamROIs = []
                                    } label: {
                                        Label("清除框选", systemImage: "xmark")
                                            .font(.subheadline)
                                            .padding(.horizontal, 8).padding(.vertical, 6)
                                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            // 检测灵敏度 + 重新识别：现场照片与训练集分布差异大时原始分数偏低，
                            // 可降阈值先看召回；检出为空时提示区会显示模型原始 Top 置信度辅助诊断。
                            HStack(spacing: 8) {
                                Text("灵敏度")
                                    .font(.caption).foregroundStyle(.secondary)
                                Picker("", selection: Binding(
                                    get: { MLDefectDetector.sensitivity.rawValue },
                                    set: { MLDefectDetector.sensitivity = MLDefectDetector.Sensitivity(rawValue: $0) ?? .standard }
                                )) {
                                    ForEach(0..<3) { i in
                                        Text(MLDefectDetector.Sensitivity(rawValue: i)?.label ?? "").tag(i)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 210)
                                Spacer()
                                Button {
                                    autoAnnotate(image: img)
                                } label: {
                                    Label("重新识别", systemImage: "arrow.clockwise")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Theme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(Theme.cyan)
                                }
                                .accessibilityLabel("重新自动识别")
                            }
                            if let ppm = store.photoPxPerMm {
                                Text("已标定：1 mm ≈ \(String(format: "%.2f", Double(ppm))) px（自动框尺寸按 mm 显示）")
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
                                },
                                roiMode: $roiMode,
                                weldSeamROIs: $store.vision.weldSeamROIs
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
                            } else if roiMode {
                                Text(store.vision.weldSeamROIs.isEmpty
                                     ? "框选焊缝：在照片上从左上向右下拖拽出一个矩形框住焊缝范围（可连续框选多处）。"
                                     : "已框选 \(store.vision.weldSeamROIs.count) 处焊缝区域，检测只在框内生效；可继续从左上向右下拖拽追加，或用「📏 标定比例」/LiDAR 量测得到 mm 后评级。")
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
                                .accessibilityLabel("使用 AI 模型识别缺陷")
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
                            onLocateTap: {
                                if annoTargetIndex == i {
                                    annoTargetIndex = -1
                                } else {
                                    annoTargetIndex = i
                                    // 点 📍 直接进入图上标注模式：此前只改索引、无任何可见反馈，
                                    // 用户点完红点没有下一步指引。与提示文案「先点缺陷行的 📍 再点照片」对齐。
                                    annoMode = true
                                }
                            },
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
                        .accessibilityLabel("手动添加新缺陷")

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
                DispatchQueue.main.async { applyNewPhoto(ui) }
            }
        }
    }

    /// 相机拍摄 / 相册选择的照片到达后的统一处理：写入 store、重置模式、触发自动识别
    private func applyNewPhoto(_ ui: UIImage) {
        store.photo = ui
        calMode = false; calPts = []; annoMode = false
        // 若用户在「设计输入」填了非默认板厚，默认带入照片评级
        if store.vision.plateThicknessMm == 12 && store.design.plateThicknessMm != 12 {
            store.vision.plateThicknessMm = store.design.plateThicknessMm
        }
        autoAnnotate(image: ui)
    }

    /// 照片载入后自动检测缺陷区域，标注位置 + 尺寸（bbox + location），并按当前板厚做 ISO 5817 评级
    private func autoAnnotate(image: UIImage) {
        // 焊缝区域闸门：未框选焊缝时不自动识别，避免把非焊缝区域（高光/纹理）误报为缺陷
        let rois = store.vision.weldSeamROIs
        guard !rois.isEmpty else {
            store.vision.imperfections.removeAll { $0.bbox != nil }
            store.autoState = "未框选焊缝区域：已跳过自动识别，避免把非焊缝区域误报为缺陷。" +
                "点照片上的「🎯 框选焊缝」拖拽出焊缝范围（可框多处），或在 🎥 实时扫描中框选后捕获。"
            return
        }
        // 阶段2：优先 Core ML 实例分割，未加载模型时自动回退 CV 规则。
        // 多处框选：逐区域检测后合并（各区域独立判定，中心落在任一框内即保留）。
        var detects: [DetectedDefect] = []
        for r in rois {
            detects += MLDefectDetector.detect(in: image, roi: r)
        }
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
        regradeAll()   // 识别完成后按累计气孔率法统一重评（含气孔双判据）
        let engine = MLDefectDetector.engineName
        let nmsInfo = MLDefectDetector.nmsThresholdOverridden
            ? "NMS阈值已降至0.05；" : "NMS阈值0.25(运行时覆盖未生效)；"
        let diag: String = {
            guard MLDefectDetector.lastUsedML else { return "（本次实际走 CV 规则回退，模型推理未成功）" }
            return MLDefectDetector.sensitivity == .standard
                ? " " + nmsInfo + "可把「灵敏度」调到「极灵敏」再试一次。"
                : " " + nmsInfo + "已在最高灵敏度仍未检出。"
        }()
        store.autoState = (detects.isEmpty
            ? "未检测到明显视觉异常（\(engine)）。模型原始置信度 Top：\(MLDefectDetector.lastRawScoresText)。\(diag)" +
              "若 Top 分数普遍 <0.2，说明现场照片（暗光/粉笔字/角焊缝）与训练集差异过大，属模型能力缺口，需补真实场景照片重训。"
            : "已自动识别 \(detects.count) 处疑似缺陷（\(engine)），位置与尺寸已在照片上标注。" +
              (ppm == nil
                ? " 点「📏 标定比例」设定参照长度后，尺寸以 mm 显示并自动评级。"
                : " 已按板厚 \(String(format: "%.0f", t)) mm 做 ISO 5817 评级。"))
            + "\n" + ISO5817Grader.ndtDisclaimer
    }

    /// 板厚/类型/尺寸变化后，重新评级所有已测得尺寸的缺陷。
    /// 气孔按「截面累计气孔率法」做双判据（单孔直径 + 累计气孔率），与设计评估路径一致。
    private func regradeAll() {
        let t = store.vision.plateThicknessMm
        let level = store.params.qualityLevel   // B|C|D，与设计评估同一目标等级
        // 先聚合全部气孔直径（同一条焊缝的气孔率按整段累计）
        let pores = store.vision.imperfections.compactMap { imp -> Double? in
            guard imp.type == "porosity" else { return nil }
            return imp.poreMm ?? imp.sizeMm
        }
        let agg = pores.isEmpty ? nil :
            ISO5817Grader.gradePorosity(pores: pores, t: t, b: nil, level: level)
        for i in store.vision.imperfections.indices {
            let type = store.vision.imperfections[i].type
            guard type != "defect" else { continue }
            guard let s = store.vision.imperfections[i].sizeMm else { continue }
            if type == "porosity", let a = agg {
                // 等级徽章用单孔直径判定等级；accepted/limitText 用累计法（双判据）
                let g = ISO5817Grader.grade(type: "porosity", sizeMm: s, t: t)
                store.vision.imperfections[i].grade = g.level
                store.vision.imperfections[i].accepted = a.accepted
                store.vision.imperfections[i].limitText = a.limitText
            } else {
                let g = ISO5817Grader.grade(type: type, sizeMm: s, t: t)
                store.vision.imperfections[i].grade = g.level
                store.vision.imperfections[i].accepted = g.accepted
                store.vision.imperfections[i].limitText = g.limitText
            }
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

    // MARK: 安全访问层
    // 真机（iPadOS 26）曾出现"点红色定位点闪退"。列表在删除/重新识别时收缩的瞬间，
    // 行内 `$store.vision.imperfections[index]` 直接下标绑定可能在事务中被越界求值 → 崩溃。
    // 全部改走带 indices.contains 守卫的安全绑定/只读访问，从结构上杜绝越界闪退类。

    private var typeBinding: Binding<String> {
        Binding<String>(
            get: {
                guard store.vision.imperfections.indices.contains(index) else { return DefectTypes.all[0].tag }
                let t = store.vision.imperfections[index].type
                // 兜底：存量数据若含不在选项内的类型，给 Picker 一个合法 tag，避免无匹配异常
                return DefectTypes.all.contains { $0.tag == t } ? t : DefectTypes.all[0].tag
            },
            set: {
                guard store.vision.imperfections.indices.contains(index) else { return }
                store.vision.imperfections[index].type = $0
                regradeRow()
            }
        )
    }

    private var sizeBinding: Binding<Double?> {
        Binding<Double?>(
            get: { store.vision.imperfections.indices.contains(index) ? store.vision.imperfections[index].sizeMm : nil },
            set: {
                guard store.vision.imperfections.indices.contains(index) else { return }
                store.vision.imperfections[index].sizeMm = $0
                regradeRow()
            }
        )
    }

    private var gradeSafe: String? {
        store.vision.imperfections.indices.contains(index) ? store.vision.imperfections[index].grade : nil
    }
    private var acceptedSafe: Bool? {
        store.vision.imperfections.indices.contains(index) ? store.vision.imperfections[index].accepted : nil
    }
    private var limitTextSafe: String? {
        store.vision.imperfections.indices.contains(index) ? store.vision.imperfections[index].limitText : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 第 1 行：缺陷类型（独占一行）。此前类型/尺寸/3 个按钮挤一行，iPad 窄侧栏内
            // Picker 被压缩成"单字竖排"，缺陷名称不可读（真机截图实证）。
            HStack(spacing: 8) {
                Picker("类型", selection: typeBinding) {
                    ForEach(DefectTypes.all, id: \.tag) { d in
                        Text(d.label).tag(d.tag)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)   // 菜单标签按理想宽度展开，不被压缩
                .accessibilityLabel("缺陷 \(index + 1) 类型选择")

                // ISO 5817 等级徽章
                if gradeSafe != nil {
                    let ok = acceptedSafe ?? false
                    Image(systemName: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? Theme.ok : Theme.danger)
                        .help(limitTextSafe ?? "")
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .accessibilityLabel("删除缺陷 \(index + 1)")
            }

            // 第 2 行：尺寸输入 + LiDAR 测量 + 图上定位
            HStack(spacing: 8) {
                TextField("尺寸mm", value: sizeBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .keyboardType(.decimalPad)

                Spacer()

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
            }

            // 评级说明（仅在有评级结果时显示）
            if let g = gradeSafe, let lt = limitTextSafe {
                let ok = acceptedSafe ?? false
                Text("ISO 5817 \(g)： \(lt)")
                    .font(.caption2)
                    .foregroundStyle(ok ? Theme.ok : Theme.danger)
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
    // 焊缝区域(ROI)框选：多处框选（数组），检测只在任一区域内生效
    @Binding var roiMode: Bool
    @Binding var weldSeamROIs: [CGRect]
    @State private var roiDragStart: CGPoint? = nil
    @State private var roiDragCurrent: CGPoint? = nil
    @State private var roiHint: String = ""   // 框选方向/多选反馈

    /// 短暂提示：2.5 秒后若未被新提示覆盖则自动清除
    private func roiFlash(_ msg: String) {
        roiHint = msg
        let token = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if roiHint == token { roiHint = "" }
        }
    }

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
                            .stroke(Theme.defect, lineWidth: 2)
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
                            .background(Theme.defect.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
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

                // 焊缝区域(ROI)叠层：已提交（绿虚线，支持多处）+ 拖拽中（绿实线）
                ForEach(Array(weldSeamROIs.enumerated()), id: \.offset) { ri, r in
                    let rs = CGRect(x: rect.minX + r.minX * rect.width,
                                    y: rect.minY + r.minY * rect.height,
                                    width: r.width * rect.width, height: r.height * rect.height)
                    Rectangle()
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rs.width, height: rs.height)
                        .position(x: rs.midX, y: rs.midY)
                    Text("焊缝#\(ri + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                        .position(x: rs.midX, y: max(rect.minY + 12, rs.minY - 10))
                }
                if let s = roiDragStart, let c = roiDragCurrent {
                    // 方向约束（需求2）：只允许 左上 → 右下
                    let downRight = c.x >= s.x && c.y >= s.y
                    let n0 = CGPoint(x: min(s.x, c.x), y: min(s.y, c.y))
                    let n1 = CGPoint(x: max(s.x, c.x), y: max(s.y, c.y))
                    let rs = CGRect(x: n0.x, y: n0.y, width: n1.x - n0.x, height: n1.y - n0.y)
                    Rectangle()
                        .stroke(downRight ? Color.green : Color.red, lineWidth: 2)
                        .frame(width: rs.width, height: rs.height)
                        .position(x: rs.midX, y: rs.midY)
                    if !downRight {
                        Text("请从左上向右下拖拽框选")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                            .position(x: rs.midX, y: max(rect.minY + 12, rs.minY - 12))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                // ROI 框选模式优先：忽略其它点按
                guard !roiMode else { return }
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
            // 焊缝区域拖拽框选：用 highPriorityGesture 确保拖拽始终优先于 ScrollView 滚动
            // （真机上普通 .gesture 会被 ScrollView 滚动手势吞掉，表现为“框不上”）。
            // 仅 roiMode 时挂载本手势（关闭时为 nil，不拦截标注/标定点按）。
            .highPriorityGesture(roiMode ? DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if roiDragStart == nil { roiDragStart = v.location }
                    roiDragCurrent = v.location
                }
                .onEnded { v in
                    guard let s = roiDragStart else { roiDragStart = nil; roiDragCurrent = nil; return }
                    let s0 = CGPoint(x: min(max(0, (s.x - rect.minX) / rect.width), 1),
                                     y: min(max(0, (s.y - rect.minY) / rect.height), 1))
                    let n1 = CGPoint(x: min(max(0, (v.location.x - rect.minX) / rect.width), 1),
                                    y: min(max(0, (v.location.y - rect.minY) / rect.height), 1))
                    roiDragStart = nil; roiDragCurrent = nil
                    // 方向约束（需求2）：只允许 左上 → 右下 框选
                    guard n1.x >= s0.x, n1.y >= s0.y else {
                        roiFlash("方向错误：请始终从左上向右下拖拽框选焊缝")
                        return   // roiMode 保持开启，可立即重拖（已支持连续框选多处）
                    }
                    let rr = CGRect(x: s0.x, y: s0.y, width: n1.x - s0.x, height: n1.y - s0.y)
                    if rr.width > 0.02, rr.height > 0.02 {
                        weldSeamROIs.append(rr)
                        roiFlash("已框选 \(weldSeamROIs.count) 处，可继续框选；再点「🎯 框选焊缝」关闭")
                    } else {
                        roiFlash("框选区域过小，请重新从左上向右下拖拽")
                    }
                } : nil)
            // 框选方向/多选提示（覆盖在画布顶部）
            .overlay(alignment: .top) {
                if !roiHint.isEmpty {
                    Text(roiHint)
                        .font(.caption).foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
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
                // 关键：overlay 会向内容提案底视图（26pt 圆点）的尺寸，长名称被截成"···"
                // （真机截图实证）。fixedSize 让文本按理想宽度展开，不再被提案宽度截断。
                .fixedSize(horizontal: true, vertical: false)
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
        case "overlap": return "焊瘤"
        case "crack": return "裂纹"
        case "unfused": return "未熔合"
        case "excess_weld_metal": return "余高"
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

// MARK: - 检测历史 sheet

struct HistorySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.history.isEmpty {
                        Text("暂无记录。完成「荷载计算评估」或点照片区「保存快照」后，记录会出现在这里。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(store.history) { h in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(h.kind)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(Theme.cyan.opacity(0.16), in: Capsule())
                                        .foregroundStyle(Theme.cyan)
                                    Text("\(h.date, style: .date) \(h.date, style: .time)")
                                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                }
                                Text(h.title)
                                    .font(.headline).foregroundStyle(Theme.textPrimary)
                                HStack(spacing: 12) {
                                    Text("缺陷 \(h.defects) 处").font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                    Text("超差 \(h.rejected) 处").font(.caption)
                                        .foregroundStyle(h.rejected > 0 ? Theme.danger : Theme.textSecondary)
                                    if let u = h.utilization {
                                        Text(String(format: "利用率 %.0f%%", u * 100))
                                            .font(.caption)
                                            .foregroundStyle(u > 1 ? Theme.danger : (u > 0.8 ? Theme.warn : Theme.ok))
                                    }
                                    if let p = h.pass {
                                        Text(p ? "满足" : "不满足")
                                            .font(.caption).foregroundStyle(p ? Theme.ok : Theme.danger)
                                    }
                                }
                                if !h.summary.isEmpty {
                                    Text("缺陷：" + h.summary)
                                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(10)
                            .background(Theme.panelGradient, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cyan.opacity(0.15), lineWidth: 1))
                        }
                    }
                }
                .padding()
            }
            .background(Theme.bgGradient.ignoresSafeArea())
            .navigationTitle("检测历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityLabel("关闭历史记录")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
// MARK: - 系统相机拍照（UIImagePickerController 封装，供"拍照"按钮调起）
struct SystemCameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        // 无相机设备（极端情况）降级为相册，避免 sourceType 崩溃
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemCameraPicker
        init(_ parent: SystemCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onImage(img)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
