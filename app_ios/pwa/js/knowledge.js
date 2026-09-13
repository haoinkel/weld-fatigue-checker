/* 知识库（与 weld_fatigue_checker/knowledge/*.json 同源，已 faithful 移植）
 * EN 1993-1-9:2005 (疲劳) + ISO 5817:2023 (焊缝缺陷质量等级)
 * FAT = 2e6 次循环处特征应力范围 Δσc (MPa)
 */
window.WF = window.WF || {};

WF.KNOWLEDGE = {
  ref_N: 2000000,
  gamma_mf_default: 1.0,
  // 标准元信息：明确标注随程序打包、离线可用（iPad Pro 2025 M5）
  meta: {
    en1993: {
      code: "EN 1993-1-9:2005",
      title: "钢结构设计 第1-9部分：疲劳",
      note: "细节类别→FAT 取自表 8.1–8.5；S-N 斜率 m=3，拐点 5e6，截止 1e8。已封装于本程序，无需联网。"
    },
    iso5817: {
      code: "ISO 5817:2023",
      title: "焊接 钢、镍及镍合金熔焊焊缝缺陷的质量等级",
      note: "缺陷验收极限按 B/C/D 级；疲劳相关缺陷以焊趾处控制为准。已封装于本程序，无需联网。"
    }
  },
  detail_categories: [
    { id: "P1", fat: 160, name: "轧制/模压产品" },
    { id: "P4", fat: 125, name: "机器气割并修整板材" },
    { id: "P6", fat: 100, name: "轧制/压延产品" },
    { id: "B8", fat: 112, name: "预载高强螺栓双面对称接头-毛截面" },
    { id: "B10", fat: 90, name: "预载注脂螺栓单面接头-毛截面" },
    { id: "B12", fat: 80, name: "装配螺栓单面接头-净截面" },
    { id: "B13", fat: 50, name: "非预载螺栓接头-净截面" },
    { id: "WS1", fat: 125, name: "双面自动对接/角焊缝连续纵缝" },
    { id: "WS3", fat: 112, name: "双面自动角焊/对焊含起止点" },
    { id: "WS5", fat: 100, name: "手工角焊/对焊" },
    { id: "WS8", fat: 80, name: "间断纵向角焊缝 g/h≤25" },
    { id: "WS9", fat: 71, name: "处理孔纵向对接焊缝(高≤60mm)" },
    { id: "WS10g", fat: 125, name: "纵向对接两面打磨齐平+100%探伤" },
    { id: "WS10n", fat: 112, name: "纵向对接无磨削无起止点" },
    { id: "WS10s", fat: 100, name: "纵向对接有起止点" },
    { id: "WS11a", fat: 140, name: "空心型材无起止点自动纵缝 t≤12.5" },
    { id: "WS11b", fat: 125, name: "空心型材无起止点自动纵缝 t≥12.5" },
    { id: "W_FILLET_TRANS_NLC", fat: 80, name: "横向非承载角焊缝（附件，焊趾受拉）" },
    { id: "W_FILLET_TRANS_LC", fat: 80, name: "横向承载角焊缝（十字接头，传力）" },
    { id: "W_FILLET_LONG", fat: 71, name: "纵向角焊缝（平行受力方向）" },
    { id: "W_BUTT_ASWELD", fat: 100, name: "横向对接焊缝（焊态，外形良好）" },
    { id: "W_BUTT_GROUND", fat: 125, name: "横向对接焊缝（打磨与母材齐平）" },
    { id: "W_COVER_END", fat: 80, name: "盖板端部（横向）" },
    { id: "W_STIFF_END", fat: 80, name: "加劲肋端部（横向受拉）" }
  ],
  improvement_methods: [
    { method: "toe_grinding", label: "焊趾打磨", factor: 1.3, max_fat: 125 },
    { method: "tig_dressing", label: "TIG 熔修", factor: 1.3, max_fat: 125 },
    { method: "hammer_peening", label: "锤击强化", factor: 1.5, max_fat: 125 },
    { method: "burr_grinding", label: "旋转钢丝刷打磨", factor: 1.3, max_fat: 100 }
  ],
  iso: {
    imperfections: [
      { type: "undercut", label: "咬边", fatigue_relevant: true,
        limits: { B: { value: 0.05, ref: "t", max_abs: 0.5 },
                  C: { value: 0.1, ref: "t", max_abs: 1.0 },
                  D: { value: 0.15, ref: "t", max_abs: 1.5 } } },
      { type: "porosity", label: "气孔", fatigue_relevant: false,
        limits: { B: { max_pore: 0.5 }, C: { max_pore: 1.0 }, D: { max_pore: 1.5 } } },
      { type: "excess_weld_metal", label: "余高过大(凸度)", fatigue_relevant: true, limits: {} },
      { type: "overlap", label: "焊瘤/满溢", fatigue_relevant: true, limits: {} },
      { type: "linear_misalignment", label: "错边", fatigue_relevant: true,
        limits: { B: { value: 0.1, ref: "t", max_abs: 1.0 },
                  C: { value: 0.15, ref: "t", max_abs: 2.0 },
                  D: { value: 0.2, ref: "t", max_abs: 3.0 } } }
    ]
  }
};
