// KnowledgeBank.swift
// 知识库：EN 1993-1-9:2005 (疲劳) + ISO 5817:2023 (焊缝缺陷质量等级)
//
// 标准封装方式（离线，App 包内自带）：
//   1) 优先从 App 包内 Resources/en1993_1_9.json 与 Resources/iso5817.json 读取
//      —— 这两份文件随 .ipa 打进设备，运行时零网络请求。
//   2) 若包内文件缺失，回退到下方内置数据（与 knowledge/*.json 同源）。
// 在 Xcode 中把 Resources/ 加入 Target Membership（Copy Bundle Resources）即可生效。

import Foundation

struct DetailCategory {
    let id: String; let fat: Int; let name: String
    var table: String?   // EN1993-1-9 表号（"8.1"…"8.5" / "8.4/8.5"），评估结果展示用
    init(id: String, fat: Int, name: String, table: String? = nil) {
        self.id = id; self.fat = fat; self.name = name; self.table = table
    }
}
struct ImprovementMethod { let method: String; let label: String; let factor: Double; let maxFat: Int }

struct IsoLimit {
    var value: Double?
    var ref: String?      // "t" 表示与板厚成比例；"b" 表示焊缝宽度基准
    var maxAbs: Double?
    var maxPore: Double?
    var poreRate: Double?  // 气孔率上限（%），用于累计气孔率法（ISO 5817 表 2/3）
    var formula: String?   // 等级不允许时的判定公式/原因说明（裂纹/未熔合一票否决等）
    var permitted: Bool?  // false = 该等级不允许（裂纹/未熔合/焊瘤 B,C/根部咬边 B 等一票否决）
    var add: Double?      // 比例项附加常数（余高/凸度 h≤v·ref+add）
}
struct ImperfectionSpec {
    let type: String; let label: String; let fatigueRelevant: Bool
    var limits: [String: IsoLimit]   // key: "B"|"C"|"D"
}

enum KnowledgeBank {
    // MARK: - 参数与数据：全部来自「标准包注册表」当前启用的标准包
    // 导入/切换标准后无需重启即可生效；注册表为空时回退 App 包内 JSON，再回退内置数据。
    static var refN: Double { StandardPackRegistry.shared.current().refN }
    static var gammaMfDefault: Double { StandardPackRegistry.shared.current().gammaMfDefault }

    static var standardsSummary: String { StandardPackRegistry.shared.standardsSummary }

    static var details: [DetailCategory] {
        let r = StandardPackRegistry.shared.current().details
        return r.isEmpty ? builtInDetails : r
    }
    static var improvements: [ImprovementMethod] {
        let r = StandardPackRegistry.shared.current().improvements
        return r.isEmpty ? builtInImprovements : r
    }
    static var isoImperfections: [ImperfectionSpec] {
        let r = StandardPackRegistry.shared.current().imperfections
        return r.isEmpty ? builtInImperfections : r
    }
    /// 质量等级（B/C/D…）由当前验收标准包决定
    static var qualityLevels: [String] { StandardPackRegistry.shared.current().levels }

    // MARK: - 内置兜底数据
    private static let builtInDetails: [DetailCategory] = [
        DetailCategory(id: "P1", fat: 160, name: "轧制/模压产品"),
        DetailCategory(id: "P4", fat: 125, name: "机器气割并修整板材"),
        DetailCategory(id: "P6", fat: 100, name: "轧制/压延产品"),
        DetailCategory(id: "B8", fat: 112, name: "预载高强螺栓双面对称接头-毛截面"),
        DetailCategory(id: "B10", fat: 90, name: "预载注脂螺栓单面接头-毛截面"),
        DetailCategory(id: "B12", fat: 80, name: "装配螺栓单面接头-净截面"),
        DetailCategory(id: "B13", fat: 50, name: "非预载螺栓接头-净截面"),
        DetailCategory(id: "WS1", fat: 125, name: "双面自动对接/角焊缝连续纵缝"),
        DetailCategory(id: "WS3", fat: 112, name: "双面自动角焊/对焊含起止点"),
        DetailCategory(id: "WS5", fat: 100, name: "手工角焊/对焊"),
        DetailCategory(id: "WS8", fat: 80, name: "间断纵向角焊缝 g/h≤25"),
        DetailCategory(id: "WS9", fat: 71, name: "处理孔纵向对接焊缝(高≤60mm)"),
        DetailCategory(id: "WS10g", fat: 125, name: "纵向对接两面打磨齐平+100%探伤"),
        DetailCategory(id: "WS10n", fat: 112, name: "纵向对接无磨削无起止点"),
        DetailCategory(id: "WS10s", fat: 100, name: "纵向对接有起止点"),
        DetailCategory(id: "WS11a", fat: 140, name: "空心型材无起止点自动纵缝 t≤12.5"),
        DetailCategory(id: "WS11b", fat: 125, name: "空心型材无起止点自动纵缝 t≥12.5"),
        DetailCategory(id: "W_TA_TRANS_71", fat: 80, name: "横向非承载角焊缝（附件，焊趾受拉）"),
        DetailCategory(id: "W_CRUCIFORM_TOE_80", fat: 80, name: "横向承载角焊缝（十字接头，传力）"),
        DetailCategory(id: "W_LA_LONG_50", fat: 71, name: "纵向角焊缝（平行受力方向）"),
        DetailCategory(id: "W_BUTT_ASWELD", fat: 100, name: "横向对接焊缝（焊态，外形良好）"),
        DetailCategory(id: "W_BUTT_GROUND", fat: 125, name: "横向对接焊缝（打磨与母材齐平）"),
        DetailCategory(id: "W_COVER_END_80", fat: 80, name: "盖板端部（横向）"),
        DetailCategory(id: "W_STIFF_WEB_71", fat: 80, name: "加劲肋端部（横向受拉）")
    ]

    private static let builtInImprovements: [ImprovementMethod] = [
        ImprovementMethod(method: "toe_grinding", label: "焊趾打磨", factor: 1.3, maxFat: 125),
        ImprovementMethod(method: "tig_dressing", label: "TIG 熔修", factor: 1.3, maxFat: 125),
        ImprovementMethod(method: "hammer_peening", label: "锤击强化", factor: 1.5, maxFat: 125),
        ImprovementMethod(method: "burr_grinding", label: "旋转钢丝刷打磨", factor: 1.3, maxFat: 100)
    ]

    private static let builtInImperfections: [ImperfectionSpec] = [
        ImperfectionSpec(type: "crack", label: "裂纹", fatigueRelevant: true,
            limits: ["B": IsoLimit(permitted: false), "C": IsoLimit(permitted: false), "D": IsoLimit(permitted: false)]),
        ImperfectionSpec(type: "lack_of_fusion", label: "未熔合", fatigueRelevant: true,
            limits: ["B": IsoLimit(permitted: false), "C": IsoLimit(permitted: false), "D": IsoLimit(permitted: false)]),
        ImperfectionSpec(type: "incomplete_penetration", label: "未焊透（单面焊根）", fatigueRelevant: true,
            limits: ["B": IsoLimit(permitted: false), "C": IsoLimit(permitted: false),
                     "D": IsoLimit(value: 0.2, ref: "t", maxAbs: 2.0)]),
        ImperfectionSpec(type: "undercut", label: "咬边", fatigueRelevant: true,
            limits: ["B": IsoLimit(value: 0.05, ref: "t", maxAbs: 0.5),
                     "C": IsoLimit(value: 0.1, ref: "t", maxAbs: 1.0),
                     "D": IsoLimit(value: 0.15, ref: "t", maxAbs: 1.5)]),
        ImperfectionSpec(type: "root_undercut", label: "根部咬边", fatigueRelevant: true,
            limits: ["B": IsoLimit(permitted: false),
                     "C": IsoLimit(value: 0.05, ref: "t", maxAbs: 0.5),
                     "D": IsoLimit(value: 0.1, ref: "t", maxAbs: 1.0)]),
        ImperfectionSpec(type: "porosity", label: "气孔", fatigueRelevant: false,
            limits: ["B": IsoLimit(maxPore: 0.5, poreRate: 2.0),
                     "C": IsoLimit(maxPore: 0.5, poreRate: 4.0),
                     "D": IsoLimit(maxPore: 3.0, poreRate: 8.0)]),
        ImperfectionSpec(type: "excess_weld_metal", label: "余高过大(凸度)", fatigueRelevant: true,
            limits: ["B": IsoLimit(value: 0.1, ref: "b", maxAbs: 5.0, add: 1.0),
                     "C": IsoLimit(value: 0.15, ref: "b", maxAbs: 7.0, add: 1.0),
                     "D": IsoLimit(value: 0.25, ref: "b", maxAbs: 10.0, add: 1.0)]),
        ImperfectionSpec(type: "overlap", label: "焊瘤/满溢", fatigueRelevant: true,
            limits: ["B": IsoLimit(permitted: false), "C": IsoLimit(permitted: false),
                     "D": IsoLimit(value: 1.0, maxAbs: 1.0)]),
        ImperfectionSpec(type: "linear_misalignment", label: "错边", fatigueRelevant: true,
            limits: ["B": IsoLimit(value: 0.1, ref: "t", maxAbs: 1.0),
                     "C": IsoLimit(value: 0.15, ref: "t", maxAbs: 2.0),
                     "D": IsoLimit(value: 0.2, ref: "t", maxAbs: 3.0)]),
        // —— 以下两项为「优化点 D：缺陷类别扩展」占位（当前视觉模型为 5 类，尚未输出这两类）——
        // 限值暂定，须对照 ISO 5817:2023 表 1–5 官方原文核定后再用于工程判定。
        ImperfectionSpec(type: "solid_inclusion", label: "固体夹渣", fatigueRelevant: true,
            limits: ["B": IsoLimit(value: 0.1, ref: "t", maxAbs: 1.0),
                     "C": IsoLimit(value: 0.15, ref: "t", maxAbs: 2.0),
                     "D": IsoLimit(value: 0.2, ref: "t", maxAbs: 3.0)]),
        ImperfectionSpec(type: "spatter", label: "飞溅", fatigueRelevant: false,
            limits: ["B": IsoLimit(permitted: true), "C": IsoLimit(permitted: true), "D": IsoLimit(permitted: true)])
    ]

    /// 查找细节类别；对旧版占位 ID 做兼容映射（避免数据升级后引用失效）
    static func findDetail(_ id: String) -> DetailCategory? {
        if let d = details.first(where: { $0.id == id }) { return d }
        if let mapped = legacyDetailAliases[id],
           let d = details.first(where: { $0.id == mapped }) { return d }
        return nil
    }

    /// 旧版占位细节 ID → v5 校正版（表 8.4/8.5 权威 W 系列）映射
    private static let legacyDetailAliases: [String: String] = [
        "W_FILLET_TRANS_LC":  "W_CRUCIFORM_TOE_80",
        "W_FILLET_TRANS_NLC": "W_TA_TRANS_71",
        "W_FILLET_LONG":      "W_LA_LONG_50",
        "W_COVER_END":        "W_COVER_END_80",
        "W_STIFF_END":        "W_STIFF_WEB_71"
    ]
}
