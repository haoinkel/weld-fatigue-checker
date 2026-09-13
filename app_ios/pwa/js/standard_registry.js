/* standard_registry.js —— 标准包注册表（PWA 版，纯前端、离线可用）
 *
 * 开放接口：后续补充新标准（GB 50017 / IIW / AWS D1.1 / BS 7608 / DNV …）时，
 * 只需准备一个符合 schema 的 .pack.json，在页面上「导入标准包」即可，
 * 无需改动任何引擎代码 —— 导入后下拉框出现该标准，选它即生效。
 *
 * 存储：
 *   内建标准包：js/packs.js（由 knowledge/packs/*.pack.json 生成，随程序打包）
 *   导入标准包：localStorage["wf_packs_user_v1"]
 *   当前启用：  localStorage["wf_packs_active_v1"]
 */
window.WF = window.WF || {};

WF.Standards = (function () {
  var KEY_USER = "wf_packs_user_v1";
  var KEY_ACTIVE = "wf_packs_active_v1";
  var SCHEMA_VERSION = "1.0";
  var KINDS = ["fatigue", "acceptance"];

  function builtinPacks() {
    return (window.WF && WF.PACKS && WF.PACKS.packs) ? WF.PACKS.packs : {};
  }
  function builtinIndex() {
    return (window.WF && WF.PACKS && WF.PACKS.index) ? WF.PACKS.index : {};
  }

  function readJSON(key, def) {
    try {
      var raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : def;
    } catch (e) { return def; }
  }
  function writeJSON(key, obj) {
    try { localStorage.setItem(key, JSON.stringify(obj)); } catch (e) {}
  }

  function userPacks() { return readJSON(KEY_USER, {}); }
  function saveUserPacks(o) { writeJSON(KEY_USER, o); }

  function allPacks() {
    var all = {};
    var b = builtinPacks();
    Object.keys(b).forEach(function (k) { all[k] = b[k]; });
    var u = userPacks();
    Object.keys(u).forEach(function (k) { all[k] = u[k]; });
    return all;
  }

  /* ---------- 校验 ---------- */
  function validate(p) {
    var errors = [], warnings = [];
    if (!p || typeof p !== "object") return { ok: false, errors: ["必须是一个 JSON 对象"], warnings: [] };
    ["schema_version", "pack_id", "kind", "code", "title", "version"].forEach(function (k) {
      if (p[k] === undefined || p[k] === null || p[k] === "") errors.push("缺少必需字段: " + k);
    });
    if (p.kind && KINDS.indexOf(p.kind) < 0) errors.push("kind 必须为 fatigue 或 acceptance，当前: " + p.kind);
    if (p.kind === "fatigue") {
      if (!Array.isArray(p.detail_categories)) errors.push("fatigue 类型缺少 detail_categories 数组");
      else p.detail_categories.forEach(function (d, i) {
        if (d.id === undefined || d.fat === undefined) errors.push("detail_categories[" + i + "] 缺少 id 或 fat");
      });
      if (!Array.isArray(p.improvement_methods)) errors.push("fatigue 类型缺少 improvement_methods 数组");
    }
    if (p.kind === "acceptance") {
      if (!Array.isArray(p.imperfections)) errors.push("acceptance 类型缺少 imperfections 数组");
      else p.imperfections.forEach(function (it, i) {
        if (it.type === undefined || it.limits === undefined) errors.push("imperfections[" + i + "] 缺少 type 或 limits");
      });
    }
    if (p.schema_version && String(p.schema_version) !== SCHEMA_VERSION) {
      warnings.push("schema_version=" + p.schema_version + "，当前程序支持 " + SCHEMA_VERSION);
    }
    if (p.verified === false) warnings.push("该标准包标记 verified=false，数值须经原文校核后方可用于工程判定");
    return { ok: errors.length === 0, errors: errors, warnings: warnings };
  }

  /* ---------- 列表 / 启停 ---------- */
  function list() {
    var all = allPacks();
    return Object.keys(all).map(function (id) {
      var p = all[id];
      return {
        pack_id: id, kind: p.kind, code: p.code, title: p.title,
        region: p.region, version: String(p.version == null ? "" : p.version),
        verified: !!p.verified,
        builtin: !!(builtinPacks()[id])
      };
    }).sort(function (a, b) {
      return a.kind.localeCompare(b.kind) || a.pack_id.localeCompare(b.pack_id);
    });
  }

  function listByKind(kind) {
    return list().filter(function (p) { return p.kind === kind; });
  }

  function defaultActive() {
    var idx = builtinIndex();
    var act = (idx && idx.active) ? idx.active : {};
    return {
      fatigue: act.fatigue || (listByKind("fatigue")[0] || {}).pack_id || null,
      acceptance: act.acceptance || (listByKind("acceptance")[0] || {}).pack_id || null
    };
  }

  function activeIds() {
    var saved = readJSON(KEY_ACTIVE, null);
    var def = defaultActive();
    if (!saved) return def;
    var all = allPacks();
    KINDS.forEach(function (k) {
      if (!saved[k] || !all[saved[k]]) saved[k] = def[k];
      else if (all[saved[k]].kind !== k) saved[k] = def[k];
    });
    return saved;
  }

  function activeId(kind) { return activeIds()[kind]; }

  function setActive(kind, packId) {
    if (KINDS.indexOf(kind) < 0) throw new Error("未知 kind: " + kind);
    var p = allPacks()[packId];
    if (!p) throw new Error("未找到标准包: " + packId);
    if (p.kind !== kind) throw new Error("标准包 " + packId + " 类型为 " + p.kind + "，不能作为 " + kind + " 启用");
    var v = validate(p);
    if (!v.ok) throw new Error("标准包校验失败: " + v.errors.join("; "));
    var a = activeIds();
    a[kind] = packId;
    writeJSON(KEY_ACTIVE, a);
    return p;
  }

  /* ---------- 导入 / 升级 / 移除 ---------- */
  function importPack(text) {
    var p;
    try { p = JSON.parse(text); }
    catch (e) { return { ok: false, message: "JSON 解析失败: " + e.message, errors: [], warnings: [] }; }
    var v = validate(p);
    if (!v.ok) return { ok: false, message: "标准包校验失败", errors: v.errors, warnings: v.warnings };

    var all = allPacks();
    var existed = !!all[p.pack_id];
    var oldVersion = existed ? String(all[p.pack_id].version) : null;

    var u = userPacks();
    u[p.pack_id] = p;
    saveUserPacks(u);

    // 若该类型尚无启用项，自动启用首个
    var a = activeIds();
    var auto = "";
    if (!a[p.kind]) { a[p.kind] = p.pack_id; writeJSON(KEY_ACTIVE, a); auto = "，并已自动启用"; }

    var msg = existed
      ? "升级标准包 " + p.pack_id + ": version " + oldVersion + " → " + p.version + auto
      : "新增标准包 " + p.pack_id + " (" + p.code + ")" + auto;
    return { ok: true, message: msg, errors: [], warnings: v.warnings, pack: p };
  }

  function removeUserPack(packId) {
    if (builtinPacks()[packId]) return { ok: false, message: "内建标准包不可移除: " + packId };
    var u = userPacks();
    if (!u[packId]) return { ok: false, message: "未找到导入的标准包: " + packId };
    delete u[packId];
    saveUserPacks(u);
    var a = activeIds();
    KINDS.forEach(function (k) { if (a[k] === packId) a[k] = defaultActive()[k]; });
    writeJSON(KEY_ACTIVE, a);
    return { ok: true, message: "已移除标准包 " + packId };
  }

  /* ---------- 供引擎消费的归一化视图 ---------- */
  function knowledge() {
    var all = allPacks();
    var a = activeIds();
    var f = all[a.fatigue], acc = all[a.acceptance];
    if (!f || !acc) return WF.KNOWLEDGE;          // 兜底：旧版内嵌知识库
    var d = f.defaults || {};
    return {
      ref_N: d.ref_N || 2000000,
      gamma_mf_default: d.gamma_mf_default || 1.0,
      detail_categories: f.detail_categories || [],
      improvement_methods: f.improvement_methods || [],
      iso: { imperfections: acc.imperfections || [], levels: acc.levels || {} },
      meta: {
        fatigue: { code: f.code, title: f.title, version: String(f.version == null ? "" : f.version),
                   note: f.verification_note || "", verified: !!f.verified },
        acceptance: { code: acc.code, title: acc.title, version: String(acc.version == null ? "" : acc.version),
                      note: acc.verification_note || "", verified: !!acc.verified }
      },
      packIds: { fatigue: f.pack_id, acceptance: acc.pack_id }
    };
  }

  return {
    SCHEMA_VERSION: SCHEMA_VERSION, KINDS: KINDS,
    list: list, listByKind: listByKind, validate: validate,
    activeId: activeId, activeIds: activeIds, setActive: setActive,
    importPack: importPack, removeUserPack: removeUserPack,
    knowledge: knowledge
  };
})();
