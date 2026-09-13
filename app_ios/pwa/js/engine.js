/* 疲劳校核引擎（移植自 engine/fatigue.py，纯 JS，可离线运行）
 * 标准不再写死：通过 WF.Standards 读取「当前启用的标准包」，
 * 切换/导入新标准后无需改动本文件即刻生效。
 */
window.WF = window.WF || {};

WF.Engine = (function () {
  // 动态取当前启用的标准（标准包优先，缺失时回退旧内嵌知识库）
  function KB() {
    return (window.WF && WF.Standards && WF.Standards.knowledge)
      ? WF.Standards.knowledge() : WF.KNOWLEDGE;
  }

  function findDetail(id) {
    return KB().detail_categories.find(d => d.id === id) || null;
  }

  function effectiveFat(detailId, improvementsApplied) {
    improvementsApplied = improvementsApplied || [];
    const d = findDetail(detailId);
    if (!d) throw new Error("未知细节类别: " + detailId);
    let fatEff = d.fat;
    const applied = [];
    KB().improvement_methods.forEach(imp => {
      if (improvementsApplied.indexOf(imp.method) >= 0) {
        const capped = Math.min(fatEff * imp.factor, imp.max_fat);
        applied.push({ method: imp.method, label: imp.label, factor: imp.factor,
                       fat_before: fatEff, fat_after: capped });
        fatEff = capped;
      }
    });
    return { fat: fatEff, applied: applied };
  }

  function allowableCycles(fat, deltaSigma, gammaMf) {
    gammaMf = gammaMf || 1.0;
    const deltaEff = gammaMf * deltaSigma;
    if (deltaEff <= 0) return Infinity;
    return KB().ref_N * Math.pow(fat / deltaEff, 3);
  }

  function constantAmplitudeCheck(detailId, deltaSigma, nRequired, opts) {
    opts = opts || {};
    const imp = opts.improvementsApplied || [];
    const gammaMf = opts.gammaMf || 1.0;
    const ef = effectiveFat(detailId, imp);
    const nAllow = allowableCycles(ef.fat, deltaSigma, gammaMf);
    const util = nAllow > 0 ? nRequired / nAllow : Infinity;
    const d = findDetail(detailId);
    return {
      detail_id: detailId, detail_name: d.name, base_fat: d.fat,
      improvements: ef.applied, effective_fat: ef.fat,
      delta_sigma: deltaSigma, gamma_mf: gammaMf,
      n_required: nRequired, n_allowable: nAllow,
      utilization: util, pass: util <= 1.0
    };
  }

  function minerCheck(detailId, spectrum, opts) {
    opts = opts || {};
    const imp = opts.improvementsApplied || [];
    const gammaMf = opts.gammaMf || 1.0;
    const ef = effectiveFat(detailId, imp);
    let damage = 0;
    const blocks = spectrum.map(([ds, n]) => {
      const nAllow = allowableCycles(ef.fat, ds, gammaMf);
      const di = nAllow > 0 ? n / nAllow : Infinity;
      damage += di;
      return { delta_sigma: ds, n: n, n_allow: nAllow, d_i: di };
    });
    return { detail_id: detailId, effective_fat: ef.fat, improvements: ef.applied,
             gamma_mf: gammaMf, damage: damage, pass: damage <= 1.0, blocks: blocks };
  }

  function evaluateImperfections(thickness, qualityLevel, imperfections) {
    const iso = KB().iso;
    const stdName = (KB().meta && KB().meta.acceptance) ? KB().meta.acceptance.code : "验收标准";
    return imperfections.map(imp => {
      const spec = iso.imperfections.find(x => x.type === imp.type);
      if (!spec) return { type: imp.type, label: imp.type, accepted: null,
                          note: stdName + " 中无此类型定义" };
      const lim = spec.limits[qualityLevel];
      let accepted = null, limitTxt = lim ? "" : "无该等级定义";
      if (lim && lim.value != null && imp.size_mm != null) {
        let thr = lim.value * (lim.ref === "t" ? thickness : 1.0);
        if (lim.max_abs != null) thr = Math.min(thr, lim.max_abs);
        accepted = imp.size_mm <= thr;
        limitTxt = "阈值≈" + thr.toFixed(3) + "mm, 实测=" + imp.size_mm + "mm";
      } else if (lim && lim.max_pore != null && imp.pore_mm != null) {
        accepted = imp.pore_mm <= lim.max_pore;
        limitTxt = "最大孔径=" + lim.max_pore + "mm, 实测=" + imp.pore_mm + "mm";
      } else if (lim) {
        limitTxt = "需按 " + stdName + " 原文判定(该包未含量化限值)";
      }
      return { type: imp.type, label: spec.label, accepted: accepted,
               limit: limitTxt, fatigue_relevant: spec.fatigue_relevant, note: spec.note || "" };
    });
  }

  return { KB, findDetail, effectiveFat, allowableCycles, constantAmplitudeCheck,
           minerCheck, evaluateImperfections };
})();
