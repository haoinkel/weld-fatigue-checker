/* Node 功能验证：在模拟 window 下加载 PWA 引擎，跑通评估逻辑 */
const fs = require("fs");
const path = require("path");
global.window = global;
const base = path.join(__dirname, "..", "js");
["knowledge.js", "engine.js", "design_rules.js"].forEach(f => {
  const code = fs.readFileSync(path.join(base, f), "utf8");
  eval(code);
});
const W = global.window.WF;
const DR = W.DesignReview, Eng = W.Engine;

// 1) 十字承载角接头 -> 细节
const demo = {
  joint_type: "cruciform", weld_type: "fillet", loading_direction: "transverse",
  load_carrying: true, full_penetration: false, ground_flush: false,
  attachment_length_mm: 40, plate_thickness_mm: 28, cope_hole: false,
  in_tension_zone: true, stiffener_end: "square", cover_termination: "abrupt",
  misalignment_mm: 3.0, runoff_tabs: false, high_cycle: true
};
console.log("matchDetail:", DR.matchDetail(demo));
const dr = DR.reviewDesign(demo);
console.log("warnings:", dr.warnings.map(w => w.id + "/" + w.severity).join(","));
const plan = DR.suggestImprovements(demo, true);
console.log("plan[0..3]:", plan.slice(0, 4).map(p => p.rule_id + ":" + p.action));

// 2) 疲劳计算：锤击提升至 125，Δσ=70, N=2e6
const fc = Eng.constantAmplitudeCheck("W_FILLET_TRANS_LC", 70, 2_000_000,
  { improvementsApplied: ["hammer_peening"], gammaMf: 1.0 });
console.log("FAT_eff(锤击):", fc.effective_fat, "利用率:", fc.utilization.toFixed(3), "pass:", fc.pass);
const fc2 = Eng.constantAmplitudeCheck("W_FILLET_TRANS_LC", 70, 2_000_000,
  { improvementsApplied: [], gammaMf: 1.0 });
console.log("FAT_eff(无改善):", fc2.effective_fat, "利用率:", fc2.utilization.toFixed(3), "pass:", fc2.pass);

// 3) 缺陷验收：咬边 1.2mm @ C 级 t=12
const imp = Eng.evaluateImperfections(12, "C", [{ type: "undercut", size_mm: 1.2 }]);
console.log("咬边验收:", imp[0].label, imp[0].accepted, imp[0].limit);
