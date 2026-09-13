/* 验证 PWA 端「标准包开放接口」：
 *   内置包加载 → 列表 → 导入新标准(GB 50017 样例) → 切换生效 → 引擎随标准变化 → 移除 → 回退
 * 运行：node tools/test_standards.js
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

/* --- 模拟浏览器环境 --- */
const store = {};
const sandbox = {
  console,
  localStorage: {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; }
  }
};
sandbox.window = sandbox;
vm.createContext(sandbox);

const base = path.join(__dirname, "..", "js");
["packs.js", "standard_registry.js", "knowledge.js", "engine.js", "design_rules.js"].forEach(f => {
  vm.runInContext(fs.readFileSync(path.join(base, f), "utf8"), sandbox, { filename: f });
});

const WF = sandbox.WF;
const STD = WF.Standards, Eng = WF.Engine, DR = WF.DesignReview;

let pass = 0, fail = 0;
function ok(cond, label, extra) {
  if (cond) { pass++; console.log("  ✓ " + label); }
  else { fail++; console.log("  ✗ " + label + (extra ? "  → " + extra : "")); }
}

console.log("\n[1] 内置标准包");
const list0 = STD.list();
ok(list0.length === 2, "内置 2 个标准包", JSON.stringify(list0.map(p => p.pack_id)));
ok(STD.activeId("fatigue") === "en1993-1-9", "默认疲劳标准 = en1993-1-9", STD.activeId("fatigue"));
ok(STD.activeId("acceptance") === "iso5817", "默认验收标准 = iso5817", STD.activeId("acceptance"));

console.log("\n[2] 引擎读取内置标准");
const d80 = Eng.findDetail("W_FILLET_TRANS_LC");
ok(d80 && d80.fat === 80, "W_FILLET_TRANS_LC FAT=80", d80 && d80.fat);
// EN1993-1-9 锤击 factor=1.5、上限 125：80×1.5=120
ok(Eng.effectiveFat("W_FILLET_TRANS_LC", ["hammer_peening"]).fat === 120,
   "锤击后 FAT=120 (80×1.5，未超上限125)", Eng.effectiveFat("W_FILLET_TRANS_LC", ["hammer_peening"]).fat);
ok(Eng.effectiveFat("W_BUTT_ASWELD", ["hammer_peening"]).fat === 125,
   "FAT100 锤击后受上限约束 =125", Eng.effectiveFat("W_BUTT_ASWELD", ["hammer_peening"]).fat);
const iso0 = Eng.evaluateImperfections(12, "C", [{ type: "undercut", size_mm: 1.2 }]);
ok(iso0[0].accepted === false, "咬边 1.2mm @C级 t=12 → 超差(阈值1.0)", JSON.stringify(iso0[0]));

console.log("\n[3] 导入新标准包（GB 50017 样例）");
const sample = fs.readFileSync(path.join(__dirname, "..", "samples", "gb50017-2017.pack.json"), "utf8");
const r = STD.importPack(sample);
ok(r.ok, "导入成功", r.message || (r.errors || []).join(";"));
ok(STD.list().length === 3, "标准包数量 → 3", String(STD.list().length));
ok((r.warnings || []).some(w => w.indexOf("verified=false") >= 0), "提示该包 verified=false 待校核");

console.log("\n[4] 切换到新标准后引擎立即生效");
STD.setActive("fatigue", "gb50017-2017");
ok(STD.activeId("fatigue") === "gb50017-2017", "当前疲劳标准 = gb50017-2017");
const g5 = Eng.findDetail("GB_J5");
ok(g5 != null, "可查到新标准的细节 GB_J5", JSON.stringify(g5));
ok(g5 && Eng.effectiveFat("GB_J5", ["hammer_peening"]).fat !== 112,
   "同一改善措施在新标准下结果不同（说明未写死）",
   g5 && Eng.effectiveFat("GB_J5", ["hammer_peening"]).fat);
ok(Eng.findDetail("W_FILLET_TRANS_LC") == null, "旧标准细节 ID 在新标准下不再可用（符合预期）");

console.log("\n[5] 校验器拒绝非法标准包");
const bad = STD.importPack(JSON.stringify({ schema_version: "1.0", pack_id: "x", kind: "fatigue" }));
ok(!bad.ok, "缺字段的包被拒绝", (bad.errors || []).join(";"));
const bad2 = STD.importPack("{ 这不是 JSON ");
ok(!bad2.ok, "非 JSON 被拒绝", bad2.message);
const bad3 = STD.importPack(JSON.stringify({ schema_version: "1.0", pack_id: "y", kind: "unknown",
  code: "X", title: "Y", version: "1", detail_categories: [], improvement_methods: [] }));
ok(!bad3.ok, "未知 kind 被拒绝", (bad3.errors || []).join(";"));

console.log("\n[6] 升级（同 ID 再导入）");
const up = JSON.parse(sample);
up.version = "2017+勘误1";
const r2 = STD.importPack(JSON.stringify(up));
ok(r2.ok && r2.message.indexOf("升级") >= 0, "再次导入 → 升级", r2.message);

console.log("\n[7] 移除导入包并回退");
const rm = STD.removeUserPack("gb50017-2017");
ok(rm.ok, "移除成功", rm.message);
ok(STD.activeId("fatigue") === "en1993-1-9", "自动回退到内置 en1993-1-9", STD.activeId("fatigue"));
ok(Eng.findDetail("W_FILLET_TRANS_LC").fat === 80, "回退后 FAT 恢复正常");
const rm2 = STD.removeUserPack("en1993-1-9");
ok(!rm2.ok, "内置包不可移除", rm2.message);

console.log("\n[8] 设计审查规则随标准走");
const dr = DR.reviewDesign({ joint_type: "cruciform", weld_type: "fillet",
  loading_direction: "transverse", load_carrying: true, plate_thickness_mm: 28,
  attachment_length_mm: 40, in_tension_zone: true, full_penetration: false,
  stiffener_end: "square", cover_termination: "abrupt", misalignment_mm: 2,
  runoff_tabs: false, high_cycle: true, improvements_applied: [] });
ok(dr.detail_id === "W_FILLET_TRANS_LC", "十字接头映射 W_FILLET_TRANS_LC", dr.detail_id);
ok(dr.warnings.length >= 6, "R1~R16 触发 " + dr.warnings.length + " 条（≥6）",
   dr.warnings.map(w => w.id).join(","));
const plan = DR.suggestImprovements(dr.detail_id ? {
  joint_type: "cruciform", weld_type: "fillet", loading_direction: "transverse",
  load_carrying: true, plate_thickness_mm: 28, attachment_length_mm: 40,
  in_tension_zone: true, full_penetration: false, stiffener_end: "square",
  cover_termination: "abrupt", misalignment_mm: 2, runoff_tabs: false,
  high_cycle: true, improvements_applied: [] } : {}, true);
ok(plan.length > 0 && plan[0].priority === "high", "改善计划按优先级排序，首条为 high");

console.log("\n———————————————");
console.log(`结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
