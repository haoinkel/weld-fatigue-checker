/* 设计审查规则 R1~R16（移植自 engine/design_review.py）
 * 标出不合理/疲劳不利细部，并给出可落地的改型建议（含目标FAT与工作量）。
 */
window.WF = window.WF || {};

WF.DesignReview = (function () {
  // 注意：标准不在此处写死，细节类别一律经 WF.Engine 走「当前启用的标准包」
  const Eng = WF.Engine;

  function matchDetail(d) {
    const jt = d.joint_type, wt = d.weld_type, ld = d.loading_direction;
    const lc = !!d.load_carrying;
    if (wt === "butt") return d.ground_flush ? "W_BUTT_GROUND" : "W_BUTT_ASWELD";
    if (wt === "fillet") {
      if (ld === "longitudinal") return "W_FILLET_LONG";
      return lc ? "W_FILLET_TRANS_LC" : "W_FILLET_TRANS_NLC";
    }
    if (jt === "t_joint" || jt === "cruciform") return lc ? "W_FILLET_TRANS_LC" : "W_FILLET_TRANS_NLC";
    if (jt === "corner" || jt === "lap") return "W_FILLET_TRANS_NLC";
    return null;
  }

  const RULES = [
    { id: "R1", severity: "high", title: "承载十字/角接头 FAT 过低",
      when: d => d.load_carrying && ["cruciform", "t_joint", "fillet", "corner"].indexOf(d.joint_type) >= 0,
      finding: "荷载经角焊缝传递（十字/承载角接头），FAT≈80 为较低等级，疲劳寿命对 Δσ 极敏感。",
      suggestions: [
        { action: "改为非承载纵向附件或全熔透对接焊", raises_fat_to: 125, effort: "中(需改图)" },
        { action: "对焊趾施加锤击/针束锤击强化", raises_fat_to: 112, effort: "低(焊后)" },
        { action: "对焊趾打磨或 TIG 熔修", raises_fat_to: 100, effort: "低(焊后)" }
      ] },
    { id: "R2", severity: "medium", title: "对接焊缝未打磨齐平",
      when: d => d.weld_type === "butt" && !d.ground_flush,
      finding: "横向对接焊缝焊态 FAT≈100；余高与母材过渡不平滑，焊趾应力集中。",
      suggestions: [
        { action: "打磨焊缝与母材齐平", raises_fat_to: 125, effort: "低(焊后)" },
        { action: "100%探伤+双面打磨齐平+无起止点(自动焊)", raises_fat_to: 140, effort: "中" }
      ] },
    { id: "R3", severity: "high", title: "拉应力区采用部分熔透",
      when: d => d.in_tension_zone && !d.full_penetration,
      finding: "位于拉应力区的接头采用部分熔透，根部为疲劳薄弱面，FAT 显著低于全熔透。",
      suggestions: [
        { action: "改为全熔透焊缝(K型/双面焊，保证根部焊透)", raises_fat_to: 125, effort: "中(改图工艺)" },
        { action: "端部加引/收弧板，避免弧坑裂纹后去除打磨", raises_fat_to: null, effort: "低" }
      ] },
    { id: "R4", severity: "medium", title: "横向附件长度偏短",
      when: d => d.loading_direction === "transverse" && d.attachment_length_mm != null && d.attachment_length_mm < 50,
      finding: "横向受力附件/加劲肋长度过短，焊趾附近应力集中系数偏高。",
      suggestions: [
        { action: "加长附件至 l≥1.5×板宽或端部斜切过渡", raises_fat_to: 90, effort: "中(改图)" },
        { action: "端部采用斜面/圆弧过渡降低应力集中", raises_fat_to: 90, effort: "低" }
      ] },
    { id: "R5", severity: "medium", title: "梁端未设切孔(cope hole)",
      when: d => d.joint_type === "t_joint" && !d.cope_hole,
      finding: "梁端腹板处未设切孔，焊缝收弧于腹板自由边，产生局部应力集中与弧坑裂纹风险。",
      suggestions: [
        { action: "增设端部切孔(cope hole)或端部铣切成型", raises_fat_to: 90, effort: "中(改图)" },
        { action: "采用连续焊并端部打磨圆滑过渡", raises_fat_to: 80, effort: "低" }
      ] },
    { id: "R6", severity: "low", title: "纵向角焊缝 FAT 最低",
      when: d => d.weld_type === "fillet" && d.loading_direction === "longitudinal",
      finding: "纵向角焊缝 FAT≈71(最低一级)，仅适用于非承载且应力水平较低处。",
      suggestions: [
        { action: "若实际承载，改为全熔透对接焊", raises_fat_to: 125, effort: "中" },
        { action: "对焊趾施加改善措施(打磨/TIG/锤击)", raises_fat_to: 100, effort: "低" }
      ] },
    { id: "R7", severity: "medium", title: "盖板/附件端部 abrupt 终止",
      when: d => d.cover_termination === "abrupt",
      finding: "盖板或附件端部 abrupt 终止(直角收尾)，端部焊趾应力集中大，FAT≈80。",
      suggestions: [
        { action: "端部削薄/斜面过渡(taper)，长度≥5×板厚", raises_fat_to: 100, effort: "中(改图)" },
        { action: "盖板全长焊接并对端部焊趾打磨", raises_fat_to: 90, effort: "低" }
      ] },
    { id: "R8", severity: "medium", title: "焊缝位于受拉自由边",
      when: d => d.in_tension_zone && ["lap", "corner", "fillet"].indexOf(d.joint_type) >= 0 && d.weld_type === "fillet",
      finding: "角焊缝/搭接焊位于板件受拉自由边附近，净截面焊趾受拉，FAT≈80 且易起裂。",
      suggestions: [
        { action: "将焊缝移离自由边，或把该边改为轧制/机加工边", raises_fat_to: 90, effort: "中" },
        { action: "对焊趾打磨/TIG 改善并做磁粉探伤", raises_fat_to: 100, effort: "低" }
      ] },
    { id: "R9", severity: "medium", title: "厚板尺寸效应未处理 (t>25mm)",
      when: d => (d.plate_thickness_mm || 0) > 25,
      finding: "板厚 t>25mm 时 EN1993-1-9 引入尺寸效应，FAT 按 (25/t)^0.25 折减。",
      suggestions: [
        { action: "对厚板焊趾施加锤击/打磨改善，抵消尺寸效应", raises_fat_to: 112, effort: "低(焊后)" },
        { action: "细部设计中避免厚板焊趾位于高 Δσ 区", raises_fat_to: null, effort: "中(改图)" }
      ] },
    { id: "R10", severity: "medium", title: "对接错边(未对齐)",
      when: d => d.misalignment_mm != null && d.misalignment_mm > 0,
      finding: "对接接头存在母材错边 e，产生二阶弯曲应力，需乘折减系数 k_m。",
      suggestions: [
        { action: "装配对齐，控制错边 e≤0.15t 并局部打磨过渡", raises_fat_to: null, effort: "低(装配)" },
        { action: "对高 Δσ 区改用全熔透+打磨齐平", raises_fat_to: 125, effort: "中" }
      ] },
    { id: "R11", severity: "low", title: "焊缝交叉处应力集中",
      when: d => d.joint_type === "cruciform" && d.load_carrying === false && d.crossing,
      finding: "横向焊缝与纵向焊缝交叉处，交叉点焊趾 FAT≈80 且双向应力叠加。",
      suggestions: [
        { action: "重新布置焊缝避免交叉；不可避免时交叉处打磨", raises_fat_to: 90, effort: "中(改图)" }
      ] },
    { id: "R12", severity: "high", title: "受拉区焊缝起止点(弧坑)未处理",
      when: d => d.in_tension_zone && d.runoff_tabs === false && d.weld_type === "butt",
      finding: "对接焊缝起止点位于受拉区且无引/收弧板，弧坑为典型裂纹起源，FAT 显著下降。",
      suggestions: [
        { action: "使用引/收弧板(run-off tabs)，焊后去除并打磨", raises_fat_to: 112, effort: "低(工艺)" },
        { action: "起止点移至低应力区并打磨", raises_fat_to: 100, effort: "低" }
      ] },
    { id: "R13", severity: "low", title: "高周疲劳未施加焊趾改善",
      when: d => d.high_cycle && !(d.improvements_applied && d.improvements_applied.length),
      finding: "设计寿命 >5e6 次(高周疲劳)的细部未施加焊趾改善，未利用可提升的 FAT 上限。",
      suggestions: [
        { action: "对关键焊趾施加 TIG 熔修/锤击，FAT 上限可达 125", raises_fat_to: 125, effort: "低" }
      ] },
    { id: "R14", severity: "medium", title: "加劲肋端部为方形",
      when: d => d.stiffener_end === "square",
      finding: "加劲肋端部方形收尾，焊趾应力集中明显(FAT≈80)，易在端部起裂。",
      suggestions: [
        { action: "端部改为圆弧过渡(r≥)或将端部切成斜面", raises_fat_to: 90, effort: "中(改图)" },
        { action: "端部焊趾打磨并做无损检测", raises_fat_to: 90, effort: "低" }
      ] },
    { id: "R15", severity: "low", title: "间断焊缝参数不利",
      when: d => d.intermittent && d.weld_continuous === false,
      finding: "间断角焊缝端部焊趾 FAT≈80；若 g/h>25 则端部效应更不利。",
      suggestions: [
        { action: "改为连续焊缝，或控制间距 g/h ≤ 25", raises_fat_to: null, effort: "中(改图)" }
      ] },
    { id: "R16", severity: "low", title: "焊脚尺寸可能不足",
      when: d => d.leg_size_mm != null && d.required_leg_mm != null && d.leg_size_mm < d.required_leg_mm,
      finding: "实际焊脚尺寸小于所需喉厚对应焊脚，静强度与疲劳喉部均不足。",
      suggestions: [
        { action: "加大焊脚至满足喉厚 a≥0.7×所需焊脚，并重新评估 FAT", raises_fat_to: null, effort: "中(工艺)" }
      ] }
  ];

  function reviewDesign(design) {
    const detailId = matchDetail(design);
    if (!detailId) {
      return { detail_id: null, detail_name: null, base_fat: null,
        warnings: [{ id: "M0", severity: "high", title: "无法映射细节",
          finding: "无法由几何映射细节类别。",
          suggestions: [{ action: "请在界面确认接头类型/焊缝类型/荷载方向", raises_fat_to: null, effort: "—" }] }],
        recommendations: [] };
    }
    const d = Eng.findDetail(detailId);
    const warnings = [];
    RULES.forEach(r => {
      try { if (r.when(design)) warnings.push({ id: r.id, severity: r.severity,
        title: r.title, finding: r.finding, suggestions: r.suggestions }); }
      catch (e) {}
    });
    const order = { high: 0, medium: 1, low: 2 };
    warnings.sort((a, b) => order[a.severity] - order[b.severity]);
    return { detail_id: detailId, detail_name: d.name, base_fat: d.fat,
             warnings: warnings, recommendations: [] };
  }

  // 生成按优先级排序的改型计划
  function suggestImprovements(design, fatigueFail) {
    const dr = reviewDesign(design);
    const plan = [];
    const seen = new Set();
    dr.warnings.forEach(w => w.suggestions.forEach(s => {
      const key = s.action + "|" + s.raises_fat_to;
      if (seen.has(key)) return;
      seen.add(key);
      plan.push({ priority: w.severity, rule_id: w.id, title: w.title,
        action: s.action, raises_fat_to: s.raises_fat_to, effort: s.effort });
    }));
    const order = { high: 0, medium: 1, low: 2 };
    plan.sort((a, b) => order[a.priority] - order[b.priority] || a.rule_id.localeCompare(b.rule_id));
    if (fatigueFail && plan.length) {
      plan.unshift({ priority: "high", rule_id: "F0", title: "疲劳强度不足",
        action: "优先降低应力幅 Δσ 或提升 FAT(见下方改型)，使利用率≤1", raises_fat_to: null, effort: "—" });
    }
    return plan;
  }

  return { matchDetail, RULES, reviewDesign, suggestImprovements };
})();
