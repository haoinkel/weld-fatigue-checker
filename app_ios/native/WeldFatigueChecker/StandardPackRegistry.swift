// StandardPackRegistry.swift
// 标准包注册表 —— 开放接口：后续补充/升级标准无需改代码
//
// 设计要点（与 Python engine/standard_registry.py、PWA js/standard_registry.js 完全一致）：
//   · 标准以「标准包 StandardPack」形式存在，JSON schema v1.0
//   · kind = fatigue（疲劳 FAT/S-N）| acceptance（表面缺陷验收）
//   · 内置包：App 包内 *.pack.json（Copy Bundle Resources 打进 .ipa，离线可用）
//   · 导入包：Documents/StandardPacks/*.pack.json（可通过「文件」App / AirDrop 放入后导入）
//   · 同 pack_id 再次导入 = 升级；内置包不可移除；移除后自动回退内置默认
//   · 选择即生效：引擎、缺陷类型、质量等级、改善措施全部随当前启用的标准包变化
//
// 新增一个标准的完整流程：
//   1) 复制一份空白模板（见 app_ios/pwa/js/app.js 的 blankTemplate，或 samples/gb50017-2017.pack.json）
//   2) 按标准原文填 detail_categories / improvement_methods / imperfections
//   3) 校验通过后置 verified=true，写清 verification_note
//   4) 放进 App 包（内置）或用 App 内「导入标准包」导入即可

import Foundation

// MARK: - 标准包数据模型（Codable，字段与 JSON 一一对应）

struct FatigueDefaults: Codable {
    let refN: Double?
    let gammaMfDefault: Double?
    let snM: Double?
    enum CodingKeys: String, CodingKey {
        case refN = "ref_N", gammaMfDefault = "gamma_mf_default", snM = "sn_m"
    }
}

struct SnCurve: Codable {
    let kneeN: Double?
    let caflRatio: Double?
    let cutoffRatio: Double?
    let note: String?
    enum CodingKeys: String, CodingKey {
        case kneeN = "knee_N", caflRatio = "cafl_ratio", cutoffRatio = "cutoff_ratio", note
    }
}

struct PackDetail: Codable {
    let id: String
    let fat: Int
    let name: String
    let table: String?   // EN1993-1-9 表号（"8.1"…"8.5" 或 "8.4/8.5"），用于评估结果展示
    let verified: Bool?
    let note: String?
}

struct PackImprovement: Codable {
    let method: String
    let label: String
    let factor: Double
    let maxFat: Int
    let note: String?
    enum CodingKeys: String, CodingKey { case method, label, factor, maxFat = "max_fat", note }
}

struct PackLimit: Codable {
    let value: Double?
    let ref: String?
    let maxAbs: Double?
    let maxPore: Double?
    let poreRate: Double?
    let permitted: Bool?
    let add: Double?
    let formula: String?
    enum CodingKeys: String, CodingKey {
        case value, ref, maxAbs = "max_abs", maxPore = "max_pore", poreRate = "pore_rate"
        case permitted, add, formula
    }
}

struct PackImperfection: Codable {
    let type: String
    let label: String
    let fatigueRelevant: Bool?
    let note: String?
    let limits: [String: PackLimit]?
    enum CodingKeys: String, CodingKey {
        case type, label, fatigueRelevant = "fatigue_relevant", note, limits
    }
}

struct StandardPack: Codable {
    let schemaVersion: String
    let packId: String
    let kind: String            // "fatigue" | "acceptance"
    let code: String
    let title: String
    let region: String?
    let version: String?
    let language: String?
    let verified: Bool?
    let verificationNote: String?
    let defaults: FatigueDefaults?
    let snCurve: SnCurve?
    let detailCategories: [PackDetail]?
    let improvementMethods: [PackImprovement]?
    let levels: [String: String]?
    let imperfections: [PackImperfection]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", packId = "pack_id", kind, code, title
        case region, version, language, verified
        case verificationNote = "verification_note", defaults
        case snCurve = "sn_curve"
        case detailCategories = "detail_categories"
        case improvementMethods = "improvement_methods"
        case levels, imperfections
    }

    var isBuiltin: Bool = false
    var displayVersion: String { version ?? "—" }
}

// MARK: - 注册表

final class StandardPackRegistry {

    static let shared = StandardPackRegistry()

    static let schemaVersion = "1.0"
    static let kinds = ["fatigue", "acceptance"]

    private let udActiveKey = "wf_packs_active_v1"
    private var builtins: [String: StandardPack] = [:]
    private var userPacks: [String: StandardPack] = [:]

    private init() {
        builtins = Self.loadBuiltins()
        userPacks = Self.loadUserPacks()
    }

    // MARK: 目录

    /// 用户导入目录：Documents/StandardPacks（Info.plist 已开 UIFileSharingEnabled，
    /// 可在「文件」App 中直接看到，支持 AirDrop 传入 .pack.json）
    static var userPacksDir: URL {
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = doc.appendingPathComponent("StandardPacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadBuiltins() -> [String: StandardPack] {
        var out: [String: StandardPack] = [:]
        let fm = FileManager.default
        var dirs: [URL] = []
        if let root = Bundle.main.resourceURL { dirs.append(root) }
        if let root = Bundle.main.resourceURL {
            dirs.append(root.appendingPathComponent("Resources"))
            dirs.append(root.appendingPathComponent("Resources/packs"))
            dirs.append(root.appendingPathComponent("packs"))
        }
        let decoder = JSONDecoder()
        for d in dirs {
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for u in files where u.pathExtension == "json" && u.lastPathComponent.contains(".pack.") {
                guard let data = try? Data(contentsOf: u),
                      var p = try? decoder.decode(StandardPack.self, from: data) else { continue }
                p.isBuiltin = true
                out[p.packId] = p
            }
        }
        return out
    }

    private static func loadUserPacks() -> [String: StandardPack] {
        var out: [String: StandardPack] = [:]
        let fm = FileManager.default
        let dir = userPacksDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return out }
        let decoder = JSONDecoder()
        for u in files where u.pathExtension == "json" {
            guard let data = try? Data(contentsOf: u),
                  let p = try? decoder.decode(StandardPack.self, from: data) else { continue }
            out[p.packId] = p
        }
        return out
    }

    // MARK: 列表

    func all() -> [String: StandardPack] {
        var m = builtins
        for (k, v) in userPacks { m[k] = v }
        return m
    }

    struct PackInfo: Identifiable {
        let id: String
        let pack: StandardPack
        var code: String { pack.code }
        var title: String { pack.title }
        var kind: String { pack.kind }
        var version: String { pack.displayVersion }
        var verified: Bool { pack.verified ?? false }
        var isBuiltin: Bool { pack.isBuiltin }
    }

    func list() -> [PackInfo] {
        all().map { PackInfo(id: $0.key, pack: $0.value) }
            .sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
    }

    func list(kind: String) -> [PackInfo] { list().filter { $0.kind == kind } }

    // MARK: 启用

    func activeId(_ kind: String) -> String? {
        let saved = UserDefaults.standard.dictionary(forKey: udActiveKey) as? [String: String]
        let allP = all()
        if let s = saved?[kind], let p = allP[s], p.kind == kind { return s }
        return list(kind: kind).first?.id
    }

    func activePack(_ kind: String) -> StandardPack? {
        guard let id = activeId(kind) else { return nil }
        return all()[id]
    }

    @discardableResult
    func setActive(kind: String, packId: String) throws -> StandardPack {
        guard StandardPackRegistry.kinds.contains(kind) else { throw PackError.badKind(kind) }
        guard let p = all()[packId] else { throw PackError.notFound(packId) }
        guard p.kind == kind else { throw PackError.kindMismatch(packId, p.kind, kind) }
        var d = UserDefaults.standard.dictionary(forKey: udActiveKey) as? [String: String] ?? [:]
        d[kind] = packId
        UserDefaults.standard.set(d, forKey: udActiveKey)
        NotificationCenter.default.post(name: .standardsDidChange, object: nil)
        return p
    }

    // MARK: 校验 / 导入 / 移除

    enum PackError: LocalizedError {
        case badKind(String), notFound(String), kindMismatch(String, String, String)
        case invalid([String]), parse(String)
        var errorDescription: String? {
            switch self {
            case .badKind(let k): return "未知标准类型: \(k)"
            case .notFound(let i): return "未找到标准包: \(i)"
            case .kindMismatch(let i, let a, let b): return "标准包 \(i) 类型为 \(a)，不能作为 \(b) 启用"
            case .invalid(let e): return "标准包校验失败：" + e.joined(separator: "；")
            case .parse(let m): return "JSON 解析失败：\(m)"
            }
        }
    }

    static func validate(_ p: StandardPack) -> (ok: Bool, errors: [String], warnings: [String]) {
        var errors: [String] = [], warnings: [String] = []
        if p.schemaVersion != schemaVersion {
            warnings.append("schema_version=\(p.schemaVersion)，当前程序支持 \(schemaVersion)")
        }
        if !kinds.contains(p.kind) { errors.append("kind 必须为 fatigue 或 acceptance，当前: \(p.kind)") }
        if p.kind == "fatigue" {
            if let ds = p.detailCategories {
                if ds.isEmpty { errors.append("detail_categories 为空") }
            } else { errors.append("fatigue 类型缺少 detail_categories") }
            if p.improvementMethods == nil { errors.append("fatigue 类型缺少 improvement_methods") }
        }
        if p.kind == "acceptance" {
            if let im = p.imperfections {
                if im.isEmpty { errors.append("imperfections 为空") }
            } else { errors.append("acceptance 类型缺少 imperfections") }
        }
        if p.verified == false { warnings.append("该标准包 verified=false，数值须经原文校核后方可用于工程判定") }
        return (errors.isEmpty, errors, warnings)
    }

    struct ImportResult {
        let ok: Bool
        let message: String
        let warnings: [String]
    }

    /// 从 JSON 文本导入（同 pack_id 即升级）
    func importPack(text: String) -> ImportResult {
        guard let data = text.data(using: .utf8) else {
            return ImportResult(ok: false, message: "编码转换失败", warnings: [])
        }
        let p: StandardPack
        do { p = try JSONDecoder().decode(StandardPack.self, from: data) }
        catch { return ImportResult(ok: false, message: PackError.parse(error.localizedDescription).localizedDescription, warnings: []) }

        let v = Self.validate(p)
        guard v.ok else {
            return ImportResult(ok: false, message: PackError.invalid(v.errors).localizedDescription, warnings: v.warnings)
        }

        let existed = all()[p.packId] != nil
        let oldVer = all()[p.packId]?.displayVersion

        let url = Self.userPacksDir.appendingPathComponent(p.packId + ".pack.json")
        do { try data.write(to: url, options: .atomic) }
        catch { return ImportResult(ok: false, message: "写入失败：\(error.localizedDescription)", warnings: v.warnings) }
        userPacks[p.packId] = p

        var auto = ""
        if activeId(p.kind) == nil { try? setActive(kind: p.kind, packId: p.packId); auto = "，并已自动启用" }

        let msg = existed
            ? "升级标准包 \(p.packId)：v\(oldVer ?? "?") → v\(p.displayVersion)\(auto)"
            : "新增标准包 \(p.packId)（\(p.code)）\(auto)"
        NotificationCenter.default.post(name: .standardsDidChange, object: nil)
        return ImportResult(ok: true, message: msg, warnings: v.warnings)
    }

    /// 从文件 URL 导入（「文件」App 选择 / AirDrop 传入）
    func importPack(fileURL: URL) -> ImportResult {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ImportResult(ok: false, message: "无法读取文件：\(fileURL.lastPathComponent)", warnings: [])
        }
        return importPack(text: text)
    }

    /// 把 Documents/StandardPacks 目录里的包重新扫一遍（无需逐个导入）
    func rescanUserPacks() -> Int {
        userPacks = Self.loadUserPacks()
        NotificationCenter.default.post(name: .standardsDidChange, object: nil)
        return userPacks.count
    }

    func removeUserPack(_ packId: String) -> ImportResult {
        if builtins[packId] != nil {
            return ImportResult(ok: false, message: "内置标准包不可移除：\(packId)", warnings: [])
        }
        guard userPacks[packId] != nil else {
            return ImportResult(ok: false, message: "未找到导入的标准包：\(packId)", warnings: [])
        }
        let url = Self.userPacksDir.appendingPathComponent(packId + ".pack.json")
        try? FileManager.default.removeItem(at: url)
        userPacks.removeValue(forKey: packId)
        var d = UserDefaults.standard.dictionary(forKey: udActiveKey) as? [String: String] ?? [:]
        for k in StandardPackRegistry.kinds where d[k] == packId { d[k] = list(kind: k).first?.id }
        UserDefaults.standard.set(d, forKey: udActiveKey)
        NotificationCenter.default.post(name: .standardsDidChange, object: nil)
        return ImportResult(ok: true, message: "已移除标准包 \(packId)", warnings: [])
    }

    // MARK: 供引擎消费的当前视图

    struct Current {
        var refN: Double
        var gammaMfDefault: Double
        var details: [DetailCategory]
        var improvements: [ImprovementMethod]
        var imperfections: [ImperfectionSpec]
        var levels: [String]
        var fatigueMeta: (code: String, title: String, version: String, verified: Bool, note: String)
        var acceptanceMeta: (code: String, title: String, version: String, verified: Bool, note: String)
    }

    func current() -> Current {
        let f = activePack("fatigue")
        let a = activePack("acceptance")

        let details: [DetailCategory] = (f?.detailCategories ?? []).map {
            DetailCategory(id: $0.id, fat: $0.fat, name: $0.name, table: $0.table)
        }
        let improvs: [ImprovementMethod] = (f?.improvementMethods ?? []).map {
            ImprovementMethod(method: $0.method, label: $0.label, factor: $0.factor, maxFat: $0.maxFat)
        }
        var imps: [ImperfectionSpec] = []
        (a?.imperfections ?? []).forEach { it in
            var limits: [String: IsoLimit] = [:]
            (it.limits ?? [:]).forEach { lv, l in
                limits[lv] = IsoLimit(value: l.value, ref: l.ref, maxAbs: l.maxAbs,
                                      maxPore: l.maxPore, poreRate: l.poreRate,
                                      permitted: l.permitted, add: l.add)
            }
            imps.append(ImperfectionSpec(type: it.type, label: it.label,
                                         fatigueRelevant: it.fatigueRelevant ?? false, limits: limits))
        }
        let levels = (a?.levels ?? [:]).keys.sorted()

        return Current(
            refN: f?.defaults?.refN ?? 2_000_000,
            gammaMfDefault: f?.defaults?.gammaMfDefault ?? 1.0,
            details: details,
            improvements: improvs,
            imperfections: imps,
            levels: levels.isEmpty ? ["B", "C", "D"] : levels,
            fatigueMeta: (code: f?.code ?? "疲劳标准", title: f?.title ?? "", version: f?.displayVersion ?? "",
                          verified: f?.verified ?? false, note: f?.verificationNote ?? ""),
            acceptanceMeta: (code: a?.code ?? "验收标准", title: a?.title ?? "", version: a?.displayVersion ?? "",
                             verified: a?.verified ?? false, note: a?.verificationNote ?? "")
        )
    }

    var standardsSummary: String {
        let c = current()
        let fatigueVerified = c.fatigueMeta.verified ? "已校核" : "待校核"
        let acceptanceVerified = c.acceptanceMeta.verified ? "已校核" : "待校核"
        let fLine = "疲劳：\(c.fatigueMeta.code) v\(c.fatigueMeta.version)（\(fatigueVerified)，\(c.details.count) 条细节）"
        let aLine = "验收：\(c.acceptanceMeta.code) v\(c.acceptanceMeta.version)（\(acceptanceVerified)，\(c.imperfections.count) 类缺陷）"
        return fLine + "\n" + aLine
    }
}

extension Notification.Name {
    static let standardsDidChange = Notification.Name("wf.standardsDidChange")
}
