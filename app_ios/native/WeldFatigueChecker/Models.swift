// Models.swift
// 共享数据模型：输入（3D 设计 / 照片 / 荷载）与评估结果
// 与 weld_fatigue_checker/engine/* 同源移植（EN 1993-1-9 + ISO 5817）

import Foundation
import SwiftUI

// MARK: - 焊工档案（WeldersHub 思路：焊工身份 + 资质 + 报告二维码）

/// 焊工资质档案：用于报告署名与现场二维码核验（EN 1090 可追溯要求）
struct WelderProfile {
    var name: String = ""          // 焊工姓名
    var certNo: String = ""        // 资质证书编号
    var level: String = ""         // 资质等级（如 ISO 9606 II / ASME 6G）
    var standard: String = "ISO 9606-1"   // 评定标准
    var expiry: Date? = nil        // 证书有效期（用于到期提醒）
    var company: String = ""       // 所属单位（可选）

    /// 资质是否临近到期（≤30 天）或已过期
    var certExpiryStatus: (state: String, daysLeft: Int?) {
        guard let e = expiry else { return ("未填有效期", nil) }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0
        if days < 0 { return ("已过期", days) }
        if days <= 30 { return ("即将到期", days) }
        return ("有效", days)
    }

    /// 二维码承载的文本（扫码即看档案摘要）
    var qrPayload: String {
        var s = "焊工档案\n"
        s += "姓名: \(name.isEmpty ? "—" : name)\n"
        s += "证书号: \(certNo.isEmpty ? "—" : certNo)\n"
        s += "等级: \(level.isEmpty ? "—" : level)\n"
        s += "标准: \(standard)\n"
        if let e = expiry { s += "有效期至: \(Self.dateFmt.string(from: e))\n" }
        return s
    }

    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}

// MARK: - 缺陷处置态（RQMS 思路：沿焊缝归集 + 处置判定）

enum Disposition: String, CaseIterable {
    case accept   // 合格
    case monitor  // 观察（未评级/待复核）
    case rework   // 需返修
    case reject   // 不合格/拒收

    var label: String {
        switch self {
        case .accept: return "合格"
        case .monitor: return "观察"
        case .rework: return "返修"
        case .reject: return "拒收"
        }
    }

    /// SwiftUI 用色（与 Theme 语义一致：绿/橙/红）
    var color: Color {
        switch self {
        case .accept: return Color(red: 0.255, green: 0.906, blue: 0.557)
        case .monitor: return Color(red: 1.0, green: 0.718, blue: 0.224)
        case .rework: return Color(red: 1.0, green: 0.55, blue: 0.2)
        case .reject: return Color(red: 1.0, green: 0.365, blue: 0.396)
        }
    }
}

extension ImperfectionInput {
    /// 由 ISO5817 判定推导处置态
    var disposition: Disposition {
        if let a = accepted { return a ? .accept : .rework }
        return .monitor
    }
}

// MARK: - 3D 设计输入
struct DesignInput {
    var jointType: String = "cruciform"        // butt|fillet|t_joint|cruciform|corner|lap
    var weldType: String = "fillet"            // butt|fillet
    var loadingDirection: String = "transverse" // transverse|longitudinal
    var loadCarrying: Bool = true
    var fullPenetration: Bool = false
    var groundFlush: Bool = false
    var attachmentLengthMm: Double? = 60
    var transitionRadiusMm: Double? = nil   // 附件过渡半径 r（表8.4 纵向附件按 r/L 分级）
    var attachmentToeGround: Bool = false    // 横向附件焊趾端部打磨（表8.4 detail4 → FAT80）
    var plateThicknessMm: Double = 12
    var copeHole: Bool = false
    var inTensionZone: Bool = true
    var stiffenerEnd: String = "square"        // square|radius|taper
    var coverTermination: String = "abrupt"     // abrupt|taper
    var misalignmentMm: Double? = 0
    var runoffTabs: Bool = false
    var highCycle: Bool = false
    var crossing: Bool = false
    var intermittent: Bool = false
    var weldContinuous: Bool = true
    var improvementsApplied: [String] = []
}

// MARK: - 照片视觉输入
struct ImperfectionInput {
    var type: String       // undercut|porosity|excess_weld_metal|overlap|linear_misalignment
    var sizeMm: Double?
    var poreMm: Double?
    // 照片上标注的缺陷位置（归一化坐标 0..1，原点左上）；用于「图上标注模式」
    var location: CGPoint?
    // 照片上自动标注的缺陷边界框（归一化矩形 0..1）；有 bbox 即视为自动识别生成
    var bbox: CGRect? = nil
    // 缺陷在原图中的像素尺寸（宽/高）；用于标定后换算为 mm
    var pixelSize: CGSize? = nil
    // 端侧 ISO 5817 评级结果（由 ISO5817Grader 在给定板厚 t 下判定）
    var grade: String? = nil            // 等级 B / C / D，或 "✗" 表示超差不合格
    var accepted: Bool? = nil           // 该实测尺寸在当前板厚下是否合格
    var limitText: String? = nil        // 验收限值说明（如 "≤0.1t 且最大 1.0 mm"）
}
struct VisionInput {
    var jointType: String = "fillet"          // 照片识别的接头类型
    var loadingDirection: String = "transverse"
    var loadCarrying: Bool = false
    var detailCandidate: String? = nil
    var improvementsApplied: [String] = []
    var imperfections: [ImperfectionInput] = []
    // 母材厚度 mm：供自动评级（ISO 5817 限值含 t 比例项）；默认 12
    var plateThicknessMm: Double = 12
    // 焊缝区域(ROI)列表：归一化矩形 0..1（原点左上），支持多处框选（多条焊缝/多段区域）。
    // 缺陷检测只在任一区域内生效：区域外不报任何缺陷，避免扫描非焊缝物体时把高光/纹理误判为余高等缺陷。
    // 余高(excess_weld_metal)为几何量，不应由 2D 亮度推断，应仅来自 LiDAR 剖面(WeldProfileAnalyzer)。
    var weldSeamROIs: [CGRect] = []
}

// MARK: - 用户荷载参数
struct UserParams {
    var deltaSigma: Double = 70
    var nRequired: Double = 2_000_000
    var gammaMf: Double = 1.0
    var qualityLevel: String = "C"   // B|C|D
    var engineMode: String = "local"  // local|cloud|auto（双引擎并行：端侧/云端，云端无网自动回落端侧）
    var thickness: Double = 12
    var weldWidthMm: Double = 24      // 余高/凸度计算基准宽度 b（ISO 5817 余高限值 h≤v·b+add）；缺省 2t
    var welder: WelderProfile = WelderProfile()   // 焊工档案（报告署名 + 二维码）
}

// MARK: - 结果结构
struct ImprovementSuggestion { let action: String; let raisesFatTo: Int?; let effort: String }
struct DesignWarning {
    let id: String; let severity: String; let title: String
    let finding: String; let suggestions: [ImprovementSuggestion]
}
struct DesignReviewResult {
    let detailId: String?; let detailName: String?; let baseFat: Int?
    let warnings: [DesignWarning]
}
struct FatigueResult {
    let detailId: String; let detailName: String; let baseFat: Int
    let table: String?   // EN1993-1-9 表号（如 "8.4"），用于展示"对比的是哪张表"
    let improvements: [(label: String, factor: Double, fatAfter: Double)]
    let effectiveFat: Double; let deltaSigma: Double; let gammaMf: Double
    let nAllowable: Double; let nRequired: Double; let utilization: Double; let pass: Bool
    let fatPenalties: [String]        // 缺陷→FAT 折减说明（空=未因缺陷折减）
    let defectForcedFail: Bool        // 因裂纹/未熔合/未焊透等一票否决缺陷强制判废
}
struct ImperfectionResult {
    let label: String; let accepted: Bool?; let limit: String; let fatigueRelevant: Bool
    let notPermitted: Bool   // true = 该质量等级不允许(裂纹/未熔合/焊瘤 B,C/根部咬边 B…)，一票否决强制判废
}
struct PlanItem: Equatable {
    let priority: String; let ruleId: String; let title: String
    let action: String; let raisesFatTo: Int?; let effort: String
}
struct AssessmentResult {
    let design: DesignReviewResult
    let fatigue: FatigueResult
    let imperfections: [ImperfectionResult]
    let plan: [PlanItem]
    let disclaimer: String
}

// MARK: - 阶段3 M3：逐细部（per-weld-seam）评估项
/// 一条焊缝 = 一个 3D 锚点位置 + 该处实际使用的接头参数 + 独立评估结果。
/// 位置用 (x,y,z) 元组而非 SCNVector3，避免 Models 引入 SceneKit 依赖（Store 直接持有）。
struct WeldSeam: Identifiable {
    let id = UUID()
    let index: Int                                   // 第几条焊缝（结果列表序号 1..n）
    let position: (x: Float, y: Float, z: Float)    // 焊缝锚点 3D 坐标（来自几何提取）
    let design: DesignInput                          // 实际用于该焊缝的接头参数（局部几何/M3 自动或全局表单）
    let assessment: AssessmentResult                 // 对该焊缝独立评估（复用 DesignReviewer.assess 内核）
    let note: String                                 // 该焊缝接头判定的来源说明（如「局部板面夹角自动判定」）
}
