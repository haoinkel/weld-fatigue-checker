/* 焊缝疲劳检查器 — UI 逻辑（iPad PWA）
 * 读取表单 -> 组装 vision_input / design_input / user_params -> 调用引擎 -> 渲染结果
 * 设备：iPad Pro 2025 11" M5（LiDAR 由 ARKit 独占，Safari 读不到深度，故 PWA 用参照物标定）
 * 标准：全部经 WF.Standards 标准包注册表动态加载 —— 导入新标准包后无需改本文件即生效
 */
(function () {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const Eng = WF.Engine, DR = WF.DesignReview, STD = WF.Standards;

  /* ---------- 随标准包动态生成的可选项 ---------- */
  function KB() { return STD.knowledge(); }

  function defectTypes() {
    const iso = KB().iso || { imperfections: [] };
    if (iso.imperfections && iso.imperfections.length) {
      return iso.imperfections.map(x => ({ type: x.type, label: x.label }));
    }
    return [{ type: "undercut", label: "咬边" }, { type: "porosity", label: "气孔" }];
  }

  function qualityLevels() {
    const lv = (KB().iso || {}).levels || {};
    const keys = Object.keys(lv);
    return keys.length ? keys : ["B", "C", "D"];
  }

  function renderQualityLevels() {
    const sel = $("quality_level"); if (!sel) return;
    const cur = sel.value;
    const lv = (KB().iso || {}).levels || {};
    sel.innerHTML = qualityLevels().map(k =>
      `<option value="${k}">${k}${lv[k] ? "（" + lv[k] + "）" : ""}</option>`).join("");
    if (qualityLevels().indexOf(cur) >= 0) sel.value = cur;
  }

  function renderImprovementBox() {
    const box = $("impvBox"); if (!box) return;
    const ms = KB().improvement_methods || [];
    box.innerHTML = ms.map(m =>
      `<label class="check"><input type="checkbox" value="${m.method}" class="impv" /> ` +
      `${m.label}（×${m.factor}，上限 FAT ${m.max_fat}）</label>`).join("")
      || `<span class="hint">当前疲劳标准包未定义改善措施。</span>`;
  }

  /* ---------- 照片 + 标定 + 缺陷标注 ---------- */
  let canvas = $("canvas");
  let ctx = canvas.getContext("2d");
  let photoImg = null;             // 已加载的原始图（用于重绘）
  // 标注对象：位置点 {kind:'pos', x, y, idx, label} 或 尺寸框 {kind:'box', x1,y1,x2,y2, type, sizeMm, label}
  let annos = [];
  let calMode = false, measureMode = false;
  let calPts = [], measPts = [];
  let pxPerMm = null;               // 标定得到的像素/毫米（仅在画布等比显示时有效）
  let showAnnos = true;            // 标注模式开关
  // 自动识别后待在图上“点选位置”的候选标签队列
  let pendingPlace = [];
  let placeSeq = 0;               // 位置点序号

  function resetScale() { pxPerMm = null; calPts = []; measPts = []; }
  function resetAll() { pxPerMm = null; calPts = []; measPts = []; annos = []; pendingPlace = []; placeSeq = 0; }


  $("photo").addEventListener("change", (e) => {
    const f = e.target.files && e.target.files[0];
    if (!f) return;
    const url = URL.createObjectURL(f);
    const img = new Image();
    img.onload = () => {
      const W = 900, scale = W / img.width;
      canvas.width = W;
      canvas.height = Math.round(img.height * scale);
      photoImg = img;
      canvas.hidden = false;
      resetAll();
      setCalState("未标定：点「标定比例」后，点击照片中参照物（直尺/Aruco/银行卡 85.6mm）的两端。");
      setCalScale();
      redraw();
      $("autoBtn").disabled = false;
      $("recState").textContent = "正在端侧自动识别焊缝缺陷…";
      // 拍照/选图后自动识别（启发式，无网络）
      setTimeout(autoRecognize, 60);
      URL.revokeObjectURL(url);
    };
    img.src = url;
  });

  function setCalState(t) { $("calState").textContent = t; }

  function setCalScale() {
    const el = $("calScale");
    if (!el) return;
    if (!pxPerMm || !photoImg) { el.innerHTML = ""; return; }
    const wMm = canvas.width / pxPerMm;
    const hMm = canvas.height / pxPerMm;
    // 透视提示：照片为透视成像，参照物与缺陷应大致在同一平面，否则尺寸会有误差
    el.innerHTML = `比例校验：1mm ≈ ${(1 / pxPerMm).toFixed(2)}px ｜ 整图物理尺寸 ≈ ` +
      `<b>${wMm.toFixed(0)}×${hMm.toFixed(0)} mm</b>（若与实物明显不符，说明标定有误，请重标）。`;
  }

  // 缺陷类型 -> 中文标签（用于标注标签）
  function defectLabel(type) {
    const d = defectTypes().find(x => x.type === type);
    return d ? d.label : (type || "缺陷");
  }

  // 标注模式开关：更新按钮文字 / 高亮，并触发重绘
  function updateAnnoToggle() {
    const b = $("annoToggle"); if (!b) return;
    b.textContent = showAnnos ? "🏷 标注：开" : "🏷 标注：关";
    b.classList.toggle("active", showAnnos);
  }

  function setAnnoMode(on) { showAnnos = on; updateAnnoToggle(); redraw(); }

  // 全量重绘：原图 + 可视标尺 + 缺陷标注（避免叠加绘制累积污染）
  function redraw() {
    if (!photoImg) return;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(photoImg, 0, 0, canvas.width, canvas.height);
    if (pxPerMm) drawScaleBar();
    if (showAnnos) annos.forEach(drawAnno);
  }

  // 标定后绘制一条“标尺”，让用户肉眼校验比例是否正确
  function drawScaleBar() {
    // 选一个“好看”的整毫米数，使标尺像素长在 90~180 之间
    const targetPx = 120;
    let barMm = targetPx / pxPerMm;
    const step = Math.pow(10, Math.floor(Math.log10(barMm)));
    const nice = [1, 2, 5, 10].map(k => k * step).find(v => v >= barMm) || step * 10;
    const barPx = nice * pxPerMm;
    const x0 = 16, y0 = canvas.height - 22, x1 = x0 + barPx;
    ctx.save();
    ctx.strokeStyle = "#0b3d91"; ctx.fillStyle = "#0b3d91"; ctx.lineWidth = 3;
    ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y0);
    ctx.moveTo(x0, y0 - 6); ctx.lineTo(x0, y0 + 6);
    ctx.moveTo(x1, y0 - 6); ctx.lineTo(x1, y0 + 6); ctx.stroke();
    ctx.font = "bold 15px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "bottom";
    ctx.fillText(nice + " mm", (x0 + x1) / 2, y0 - 8);
    ctx.restore();
  }

  function drawAnno(a) {
    ctx.save();
    if (a.kind === "pos") {
      drawDot(a.x, a.y, "rgba(192,57,43,.9)", a.label || String(a.idx));
    } else {
      // 尺寸框：连接两端 + 标签（类型 + 尺寸 mm）
      // 自动识别框用橙色，手动测量框用红色，便于区分
      const col = a.auto ? "#e67e22" : "#c0392b";
      ctx.strokeStyle = col; ctx.lineWidth = 2;
      ctx.setLineDash([6, 4]);
      const x = Math.min(a.x1, a.x2), y = Math.min(a.y1, a.y2);
      const w = Math.abs(a.x2 - a.x1), h = Math.abs(a.y2 - a.y1);
      ctx.strokeRect(x, y, w, h);
      ctx.setLineDash([]);
      drawDot(a.x1, a.y1, col, "");
      drawDot(a.x2, a.y2, col, "");
      const label = (a.label || a.type || "缺陷") + (a.sizeMm != null ? "  " + a.sizeMm + " mm" : "");
      ctx.font = "bold 15px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "bottom";
      const lx = (a.x1 + a.x2) / 2, ly = Math.min(a.y1, a.y2) - 6;
      const tw = ctx.measureText(label).width + 10;
      ctx.fillStyle = a.auto ? "rgba(230,126,34,.92)" : "rgba(192,57,43,.9)";
      ctx.fillRect(lx - tw / 2, ly - 20, tw, 18);
      ctx.fillStyle = "#fff"; ctx.fillText(label, lx, ly - 4);
    }
    ctx.restore();
  }

  function drawDot(x, y, color, label) {
    ctx.beginPath();
    ctx.arc(x, y, 13, 0, Math.PI * 2);
    ctx.fillStyle = color; ctx.fill();
    if (label) {
      ctx.fillStyle = "#fff";
      ctx.font = "bold 15px sans-serif";
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(label, x, y);
    }
  }

  function canvasPt(e) {
    const r = canvas.getBoundingClientRect();
    return {
      x: (e.clientX - r.left) * (canvas.width / r.width),
      y: (e.clientY - r.top) * (canvas.height / r.height)
    };
  }

  const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

  $("calBtn").addEventListener("click", () => {
    calMode = !calMode; measureMode = false; calPts = [];
    $("calBtn").classList.toggle("active", calMode);
    $("measBtn").classList.remove("active");
    if (calMode) setCalState("标定中：点击参照物的两端（先后顺序无所谓）。");
    else setCalState(pxPerMm ? "已标定，可用「测量缺陷」量取尺寸。" : "未标定。");
  });

  $("measBtn").addEventListener("click", () => {
    if (!pxPerMm) { alert("请先点「标定比例」完成标定，再测量尺寸。"); return; }
    measureMode = !measureMode; calMode = false; measPts = [];
    $("measBtn").classList.toggle("active", measureMode);
    $("calBtn").classList.remove("active");
    if (measureMode) setCalState("测量中：点击缺陷的两端，测得的 mm 会自动填入新缺陷行。");
  });

  canvas.addEventListener("click", (e) => {
    if (canvas.hidden) return;
    const p = canvasPt(e);

    if (calMode) {
      calPts.push(p);
      drawDot(p.x, p.y, "#0b3d91", String(calPts.length));
      if (calPts.length === 2) {
        const d = dist(calPts[0], calPts[1]);
        const real = parseFloat($("cal_len").value);
        calMode = false; $("calBtn").classList.remove("active");
        if (real > 0 && d > 0) {
          pxPerMm = d / real;
          setCalState(`已标定：${real}mm 对应 ${d.toFixed(0)}px（1mm ≈ ${(1 / pxPerMm).toFixed(2)}px）。现在可点「测量缺陷」量取尺寸。`);
        } else {
          setCalState("标定失败：参照物长度需 >0，且两点不能重合。");
        }
        calPts = []; redraw();
      }
      return;
    }

    if (measureMode) {
      measPts.push(p);
      drawDot(p.x, p.y, "#1f8a4c", String(measPts.length));
      if (measPts.length === 2) {
        const d = dist(measPts[0], measPts[1]);
        const mm = d / pxPerMm;
        measureMode = false; $("measBtn").classList.remove("active");
        setCalState(`测得尺寸 ≈ ${mm.toFixed(1)} mm（已标在图上，并填入下方新缺陷行的「尺寸」）`);
        const row = addImpRow({ size: mm.toFixed(1) });
        const type = row ? row.querySelector(".imp-type").value : "defect";
        annos.push({ kind: "box", x1: measPts[0].x, y1: measPts[0].y, x2: measPts[1].x, y2: measPts[1].y,
          type: type, sizeMm: mm, label: defectLabel(type) });
        showAnnos = true; updateAnnoToggle(); redraw();
        measPts = [];
      }
      return;
    }

    // 普通模式：标记缺陷位置（在图上标注一个位置点，并加入缺陷清单）
    const idx = annos.filter(a => a.kind === "pos").length + 1;
    annos.push({ kind: "pos", x: p.x, y: p.y, idx: idx, label: String(idx) });
    showAnnos = true; updateAnnoToggle();
    addImpRow();
    redraw();
  });

  $("clearPhoto").addEventListener("click", () => {
    canvas.hidden = true; annos = []; resetScale(); showAnnos = true; updateAnnoToggle();
    setCalState("未标定：拍摄后点「标定比例」再测距。");
    $("autoBtn").disabled = true;
    $("recState").textContent = "";
  });

  function addImpRow(def) {
    def = def || {};
    const row = document.createElement("div");
    row.className = "imp-row";
    if (def.auto) row.dataset.auto = "1";   // 自动识别生成的行，重跑时会被清除
    const sel = defectTypes().map(d =>
      `<option value="${d.type}" ${def.type === d.type ? "selected" : ""}>${d.label}</option>`).join("");
    row.innerHTML =
      `<select class="imp-type">${sel}</select>` +
      `<input class="imp-size" type="number" placeholder="尺寸(mm)" step="0.1" value="${def.size || ""}" />` +
      `<input class="imp-pore" type="number" placeholder="孔径(mm)" step="0.1" value="${def.pore || ""}" />` +
      `<button class="del" type="button">✕</button>`;
    row.querySelector(".del").addEventListener("click", () => row.remove());
    $("impList").appendChild(row);
    return row;
  }
  $("addImp").addEventListener("click", () => addImpRow());

  function collectImperfections() {
    const out = [];
    $("impList").querySelectorAll(".imp-row").forEach(r => {
      const type = r.querySelector(".imp-type").value;
      const size = parseFloat(r.querySelector(".imp-size").value);
      const pore = parseFloat(r.querySelector(".imp-pore").value);
      const item = { type };
      if (!isNaN(size)) item.size_mm = size;
      if (!isNaN(pore)) item.pore_mm = pore;
      if (item.size_mm != null || item.pore_mm != null) out.push(item);
    });
    return out;
  }

  function collectImprovements() {
    return Array.from(document.querySelectorAll(".impv:checked")).map(c => c.value);
  }

  /* ---------- ⑥ 拍照后自动识别焊接缺陷（端侧启发式） ---------- */
  // 从 canvas 像素计算：平均亮度、对比度、Sobel 边缘密度（均为 0~1）
  function computeImageStats() {
    const w = canvas.width, h = canvas.height;
    if (w === 0 || h === 0) return { mean: 0, contrast: 0, edgeDensity: 0 };
    const data = ctx.getImageData(0, 0, w, h).data;
    const n = w * h;
    const gray = new Float32Array(n);
    let sum = 0, sumSq = 0;
    for (let i = 0; i < n; i++) {
      const r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2];
      const y = 0.299 * r + 0.587 * g + 0.114 * b;
      gray[i] = y; sum += y; sumSq += y * y;
    }
    const mean = sum / n;
    const variance = sumSq / n - mean * mean;
    const contrast = Math.sqrt(Math.max(0, variance)) / 255;
    // Sobel 边缘密度（焊缝表面缺陷通常伴随局部纹理/边缘增多）
    let edge = 0;
    for (let y = 1; y < h - 1; y++) {
      for (let x = 1; x < w - 1; x++) {
        const i = y * w + x;
        const sx = (gray[i - w + 1] + 2 * gray[i + 1] + gray[i + w + 1]) -
                   (gray[i - w - 1] + 2 * gray[i - 1] + gray[i + w - 1]);
        const sy = (gray[i + w - 1] + 2 * gray[i + w] + gray[i + w + 1]) -
                   (gray[i - w - 1] + 2 * gray[i - w] + gray[i - w + 1]);
        if (Math.hypot(sx, sy) > 70) edge++;
      }
    }
    const edgeDensity = edge / n;
    return { mean, contrast, edgeDensity };
  }

  // 自动识别：端侧区域检测，自动在图上框出缺陷并标注位置与尺寸
  // 流程：灰度 → Sobel 边缘幅度 → 自适应阈值 → 连通域(4 邻域) → 非极大抑制 → 逐框定类型/尺寸
  function autoRecognize() {
    if (canvas.hidden) { alert("请先拍摄或选择焊缝照片。"); return; }
    const w = canvas.width, h = canvas.height;
    const data = ctx.getImageData(0, 0, w, h).data;
    const n = w * h;
    const gray = new Float32Array(n);
    let gsum = 0;
    for (let i = 0; i < n; i++) {
      const y = 0.299 * data[i * 4] + 0.587 * data[i * 4 + 1] + 0.114 * data[i * 4 + 2];
      gray[i] = y; gsum += y;
    }
    const gmean = gsum / n;

    // Sobel 边缘幅度
    const mag = new Float32Array(n);
    for (let y = 1; y < h - 1; y++) {
      for (let x = 1; x < w - 1; x++) {
        const i = y * w + x;
        const sx = (gray[i - w + 1] + 2 * gray[i + 1] + gray[i + w + 1]) -
                   (gray[i - w - 1] + 2 * gray[i - 1] + gray[i + w - 1]);
        const sy = (gray[i + w - 1] + 2 * gray[i + w] + gray[i + w + 1]) -
                   (gray[i - w - 1] + 2 * gray[i - w] + gray[i - w + 1]);
        mag[i] = Math.hypot(sx, sy);
      }
    }
    let msum = 0, msq = 0;
    for (let i = 0; i < n; i++) { msum += mag[i]; msq += mag[i] * mag[i]; }
    const mmean = msum / n, mstd = Math.sqrt(Math.max(0, msq / n - mmean * mmean));
    const thresh = Math.max(50, mmean + 2.0 * mstd);

    // 连通域（4 邻域 BFS），过滤过小/过大及与背景无亮度差的区域
    const visited = new Uint8Array(n);
    const raw = [];
    const minArea = Math.max(60, n * 0.0006);
    const maxArea = n * 0.18;
    for (let i = 0; i < n; i++) {
      if (visited[i] || mag[i] < thresh) continue;
      const stack = [i]; visited[i] = 1;
      let minX = w, minY = h, maxX = 0, maxY = 0, cnt = 0, ysum = 0;
      while (stack.length) {
        const p = stack.pop(); cnt++;
        const px = p % w, py = (p / w) | 0; ysum += gray[p];
        if (px < minX) minX = px; if (px > maxX) maxX = px;
        if (py < minY) minY = py; if (py > maxY) maxY = py;
        if (px > 0 && !visited[p - 1] && mag[p - 1] >= thresh) { visited[p - 1] = 1; stack.push(p - 1); }
        if (px < w - 1 && !visited[p + 1] && mag[p + 1] >= thresh) { visited[p + 1] = 1; stack.push(p + 1); }
        if (py > 0 && !visited[p - w] && mag[p - w] >= thresh) { visited[p - w] = 1; stack.push(p - w); }
        if (py < h - 1 && !visited[p + w] && mag[p + w] >= thresh) { visited[p + w] = 1; stack.push(p + w); }
      }
      const bw = maxX - minX + 1, bh = maxY - minY + 1, area = bw * bh;
      if (cnt >= minArea && cnt <= maxArea && bw > 4 && bh > 4) {
        const inMean = ysum / cnt;
        if (Math.abs(inMean - gmean) < 6) continue;   // 与背景无差异，非缺陷
        raw.push({ x1: minX, y1: minY, x2: maxX, y2: maxY, area, bw, bh, inMean });
      }
    }

    // 非极大抑制（IoU>0.6 视为重叠，保留面积大的）
    raw.sort((a, b) => b.area - a.area);
    const boxes = [];
    for (const b of raw) {
      let ov = false;
      for (const k of boxes) {
        const ix = Math.max(0, Math.min(b.x2, k.x2) - Math.max(b.x1, k.x1));
        const iy = Math.max(0, Math.min(b.y2, k.y2) - Math.max(b.y1, k.y1));
        const inter = ix * iy, uni = b.area + k.area - inter;
        if (uni > 0 && inter / uni > 0.6) { ov = true; break; }
      }
      if (!ov) boxes.push(b);
      if (boxes.length >= 12) break;
    }

    // 清除上一轮自动标注（保留用户手动添加的框/点）
    annos = annos.filter(a => !a.auto);
    document.querySelectorAll('#impList .imp-row[data-auto="1"]').forEach(r => r.remove());

    if (boxes.length === 0) {
      setCalState("自动识别未检出明显局部异常（启发式）。仍建议按 ISO 5817 做无损检测复核。");
      $("recState").textContent = "自动识别：未检出明显局部缺陷（启发式区域检测）。";
      redraw();
      return;
    }

    const lines = [];
    boxes.forEach((b, i) => {
      // 类型启发式：近圆暗斑→气孔；亮脊→余高；长暗条→咬边
      const dark = b.inMean < gmean, bright = b.inMean > gmean;
      const aspect = Math.max(b.bw, b.bh) / Math.max(1, Math.min(b.bw, b.bh));
      let type = "defect";
      if (dark && aspect < 1.8) type = "porosity";
      else if (bright) type = "excess_weld_metal";
      else if (dark && aspect >= 1.8) type = "undercut";

      // 尺寸（mm，需先标定；否则留空，由用户点「测量缺陷」补）
      let sizeMm = null;
      if (pxPerMm) {
        const mm = Math.max(b.bw, b.bh) / pxPerMm;
        sizeMm = Number(mm.toFixed(2));
      }
      const cx = ((b.x1 + b.x2) / 2) / w, cy = ((b.y1 + b.y2) / 2) / h;
      // 自动框标注（橙色），重跑时会被清除
      annos.push({
        kind: "box", auto: true,
        x1: b.x1, y1: b.y1, x2: b.x2, y2: b.y2,
        type, sizeMm,
        label: defectLabel(type) + (sizeMm != null ? " " + sizeMm.toFixed(1) + "mm" : "")
      });
      addImpRow({ type, size: sizeMm != null ? sizeMm.toFixed(1) : "", auto: true });
      lines.push(`· #${i + 1} ${defectLabel(type)}（位置 x${(cx * 100).toFixed(0)}% y${(cy * 100).toFixed(0)}%）${
        sizeMm != null ? " 尺寸≈" + sizeMm.toFixed(1) + "mm" : " 尺寸待标定"}`);
    });

    showAnnos = true; updateAnnoToggle(); redraw();
    setCalState(`自动识别并标注 ${boxes.length} 处疑似缺陷（橙色框）。${pxPerMm ? "尺寸已按标定换算 mm。" : "未标定：点「标定比例」后可显示 mm。"}`);
    $("recState").textContent = `自动识别到 ${boxes.length} 处疑似缺陷，已在图上标注：\n` + lines.join("\n") +
      `\n（类型为启发式判断，请在清单中确认；尺寸建议以 LiDAR/量具复核）`;
  }

  $("autoBtn").addEventListener("click", autoRecognize);

  /* ---------- 组装输入 ---------- */
  function readNum(id, def) { const v = parseFloat($(id).value); return isNaN(v) ? def : v; }

  function photoInput() {
    return {
      detail_candidate: DR.matchDetail({
        joint_type: $("joint_type").value, weld_type: $("joint_type").value === "butt" ? "butt" : "fillet",
        loading_direction: $("loading_direction").value, load_carrying: $("load_carrying").checked
      }),
      improvements_applied: collectImprovements(),
      imperfections: collectImperfections()
    };
  }

  function designInput() {
    return {
      joint_type: $("d_joint_type").value,
      weld_type: $("d_weld_type").value,
      loading_direction: $("d_loading_direction").value,
      load_carrying: $("d_load_carrying").checked,
      full_penetration: $("d_full_penetration").checked,
      ground_flush: $("d_ground_flush").checked,
      attachment_length_mm: readNum("d_attachment_length_mm", 60),
      plate_thickness_mm: readNum("d_plate_thickness_mm", 12),
      cope_hole: $("d_cope_hole").checked,
      in_tension_zone: $("d_in_tension_zone").checked,
      stiffener_end: $("d_stiffener_end").value,
      cover_termination: $("d_cover_termination").value,
      misalignment_mm: readNum("d_misalignment_mm", 0),
      runoff_tabs: $("d_runoff_tabs").checked,
      high_cycle: $("d_high_cycle").checked,
      improvements_applied: collectImprovements()
    };
  }

  /* ---------- 综合评估 ---------- */
  function assess() {
    const mode = $("mode").value;
    const design = designInput();
    const photo = photoInput();
    const userParams = {
      delta_sigma: readNum("delta_sigma", 70),
      n_required: readNum("n_required", 2000000),
      gamma_mf: parseFloat($("gamma_mf").value),
      quality_level: $("quality_level").value,
      thickness: readNum("thickness", 12)
    };

    let detailId, dr;
    if (mode === "design") {
      dr = DR.reviewDesign(design); detailId = dr.detail_id;
    } else if (mode === "photo") {
      dr = { detail_id: photo.detail_candidate, warnings: [] };
      detailId = photo.detail_candidate;
    } else {
      dr = DR.reviewDesign(design); detailId = dr.detail_id || photo.detail_candidate;
    }

    if (!detailId || !Eng.findDetail(detailId)) {
      alert("当前启用的疲劳标准包中找不到细节类别 " + detailId +
            "。\n可能是新导入的标准使用不同的 ID 体系 —— 请切换到匹配的疲劳标准，或在该标准包内补充对应条目。");
      return;
    }

    const improvements = photo.improvements_applied;
    const fc = Eng.constantAmplitudeCheck(detailId, userParams.delta_sigma, userParams.n_required,
      { improvementsApplied: improvements, gammaMf: userParams.gamma_mf });
    const impResults = Eng.evaluateImperfections(userParams.thickness, userParams.quality_level, photo.imperfections);

    const plan = (mode === "photo") ? [] : DR.suggestImprovements(design, !fc.pass);
    if (!fc.pass) plan.push({ priority: "high", rule_id: "F1", title: "疲劳强度不满足",
      action: "降低 Δσ / 增加板厚 / 焊趾打磨或 TIG/锤击提升 FAT，或优化细部设计", raises_fat_to: null, effort: "—" });
    const fatigueCritical = impResults.filter(r => r.fatigue_relevant && r.accepted === false);
    fatigueCritical.forEach(r => plan.push({ priority: "medium", rule_id: "I1", title: "缺陷超差: " + r.label,
      action: `「${r.label}」超 ${userParams.quality_level} 级且位于焊趾，建议打磨改善疲劳`, raises_fat_to: null, effort: "低" }));
    const final = []; const seen = new Set();
    plan.forEach(p => { if (!seen.has(p.action)) { seen.add(p.action); final.push(p); } });
    if (!final.length) final.push({ priority: "ok", rule_id: "OK", title: "满足要求",
      action: "结构设计细节与表面质量在当前输入下满足疲劳要求。", raises_fat_to: null, effort: "—" });

    render({ detailId, dr, fc, impResults, plan: final, mode, userParams });
    window.__lastReport = { standards: STD.activeIds(), design, photo, userParams,
      result: { dr, fc, impResults, plan: final } };
    $("report").disabled = false; $("copy").disabled = false;
  }

  /* ---------- 渲染 ---------- */
  function fmt(n) { return isFinite(n) ? n.toExponential(3) : "∞"; }
  function tag(p) {
    const map = { high: "严重", medium: "建议", low: "可优化", ok: "通过" };
    return `<span class="tag ${p}">${map[p] || p}</span>`;
  }

  function render(R) {
    const fc = R.fc;
    const meta = KB().meta || {};
    const fCode = (meta.fatigue && meta.fatigue.code) || "疲劳标准";
    const aCode = (meta.acceptance && meta.acceptance.code) || "验收标准";
    let h = `<h2>评估结果（判定依据：${({ both: "3D+照片", photo: "仅照片", design: "仅3D" })[R.mode]}）</h2>`;
    h += `<div class="kv"><b>采用标准</b><span>疲劳：${fCode} ｜ 验收：${aCode}</span></div>`;
    h += `<div class="kv"><b>细节类别</b><span>${fc.detail_name} (${fc.detail_id})</span></div>`;
    h += `<div class="kv"><b>基准 FAT</b><span>${fc.base_fat}</span></div>`;
    fc.improvements.forEach(im => {
      h += `<div class="kv"><b>改善措施</b><span>${im.label} ×${im.factor} → FAT ${im.fat_after}</span></div>`;
    });
    h += `<div class="kv"><b>有效 FAT</b><span>${fc.effective_fat}</span></div>`;
    h += `<div class="kv"><b>应力幅 Δσ</b><span>${fc.delta_sigma} MPa (γ_Mf=${fc.gamma_mf})</span></div>`;
    h += `<div class="kv"><b>允许次数</b><span>${fmt(fc.n_allowable)}</span></div>`;
    h += `<div class="kv"><b>需求次数</b><span>${fmt(fc.n_required)}</span></div>`;
    h += `<div class="kv"><b>利用率</b><span>${isFinite(fc.utilization) ? fc.utilization.toFixed(3) : "∞"} （&gt;1 不满足）</span></div>`;
    h += `<div class="kv"><b>疲劳结论</b><span class="${fc.pass ? "pass" : "fail"}">${fc.pass ? "满足 ✓" : "不满足 ✗"}</span></div>`;

    if (R.dr && R.dr.warnings && R.dr.warnings.length) {
      h += `<h3>① 识别出的不合理/疲劳不利细部（3D 设计）</h3>`;
      R.dr.warnings.forEach(w => {
        h += `<div class="defbox"><b>${tag(w.severity)} ${w.id} ${w.title}</b><br>${w.finding}</div>`;
      });
    }

    h += `<h3>② 表面缺陷（${aCode} ${R.userParams.quality_level} 级）</h3>`;
    if (!R.impResults.length) h += `<div class="defbox">未记录缺陷。</div>`;
    R.impResults.forEach(r => {
      const st = r.accepted === true ? `<span class="pass">通过</span>` : (r.accepted === false ? `<span class="fail">超差</span>` : "未判定");
      const fr = r.fatigue_relevant ? " <b>[疲劳相关]</b>" : "";
      h += `<div class="kv"><b>${r.label}${fr}</b><span>${st} | ${r.limit || ""}</span></div>`;
    });

    h += `<h3>③ 改善建议（按优先级）</h3><div class="plan">`;
    R.plan.forEach(p => {
      const tgt = p.raises_fat_to ? `（目标 FAT≈${p.raises_fat_to}）` : "";
      h += `<div class="pitem ${p.priority}">${tag(p.priority)} <b>${p.rule_id} ${p.title}</b>` +
           `<div class="pa">${p.action} ${tgt}</div>` +
           (p.effort ? `<div class="pm">工作量：${p.effort}</div>` : "") + `</div>`;
    });
    h += `</div>`;
    h += `<p class="disclaimer">⚠ 辅助判定，非认证检测；结论须由持证人员复核。</p>`;
    $("result").innerHTML = h;
    $("result").hidden = false;
    $("result").scrollIntoView({ behavior: "smooth" });
  }

  /* ---------- ④ 标准包管理（开放接口） ---------- */
  function packMetaLine(p) {
    return `<b>${p.code}</b> · ${p.title} · ${p.region || "—"} · v${p.version || "—"} ` +
           `<span class="tag ${p.verified ? "ok" : "medium"}">${p.verified ? "已校核" : "待校核"}</span>` +
           `<span class="tag ${p.builtin ? "low" : "ok"}">${p.builtin ? "内置" : "导入"}</span>`;
  }

  function renderStdSelects() {
    const a = STD.activeIds();
    ["fatigue", "acceptance"].forEach(kind => {
      const sel = $("std_" + kind); if (!sel) return;
      sel.innerHTML = STD.listByKind(kind).map(p =>
        `<option value="${p.pack_id}" ${p.pack_id === a[kind] ? "selected" : ""}>` +
        `${p.code}｜${p.title}${p.verified ? "" : "（待校核）"}</option>`).join("");
    });
  }

  function renderPackList() {
    const box = $("packList"); if (!box) return;
    const all = STD.list();
    const a = STD.activeIds();
    let h = `<table class="std"><thead><tr><th>标准</th><th>类型</th><th>来源</th><th>状态</th><th>操作</th></tr></thead><tbody>`;
    all.forEach(p => {
      const kindTxt = p.kind === "fatigue" ? "疲劳 FAT/S-N" : "表面验收";
      const isActive = (a[p.kind] === p.pack_id) ? `<span class="tag ok">启用中</span>` : "";
      const act = p.builtin ? "—" : `<button class="btn ghost sm rmv" data-id="${p.pack_id}">移除</button>`;
      h += `<tr><td>${packMetaLine(p)}</td><td>${kindTxt}</td><td>${p.builtin ? "随程序打包" : "本机导入"}</td>` +
           `<td>${isActive}</td><td>${act}</td></tr>`;
    });
    h += `</tbody></table>`;
    box.innerHTML = h;
    box.querySelectorAll(".rmv").forEach(b => {
      b.addEventListener("click", () => {
        const r = STD.removeUserPack(b.getAttribute("data-id"));
        packMsg((r.ok ? "✓ " : "✗ ") + r.message);
        refreshStandards();
      });
    });
  }

  function packMsg(t) { const el = $("packMsg"); if (el) el.innerHTML = t; }

  function download(name, obj) {
    const blob = new Blob([JSON.stringify(obj, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = name; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  function blankTemplate(kind) {
    const base = {
      schema_version: "1.0",
      pack_id: "my-standard-1",        // 全程序唯一 ID（小写、连字符）
      kind: kind,                      // fatigue（疲劳）或 acceptance（表面验收）
      code: "XXX 0000-2025",           // 标准代号，如 GB 50017-2017
      title: "标准中文名",
      region: "CN",                    // EU / CN / INT / US / JP ...
      version: "2025",
      language: "zh",
      verified: false,                 // 数值经原文逐条校核后置 true
      verification_note: "数值来源与校核说明（哪条表、哪一页、是否示例值）"
    };
    if (kind === "fatigue") {
      base.defaults = { ref_N: 2000000, gamma_mf_default: 1.0, sn_m: 3 };
      base.sn_curve = { knee_N: 5000000, cafl_ratio: 0.549, cutoff_ratio: 0.2737, note: "按标准原文填写" };
      base.detail_categories = [
        { id: "X1", fat: 100, name: "示例细节", verified: false, note: "占位值" }
      ];
      base.improvement_methods = [
        { method: "toe_grinding", label: "焊趾打磨", factor: 1.3, max_fat: 125, note: "待校核" }
      ];
    } else {
      base.levels = { B: "最高要求", C: "中等要求", D: "较低要求" };
      base.imperfections = [
        { type: "undercut", label: "咬边", fatigue_relevant: true, note: "",
          limits: { B: { value: 0.05, ref: "t", max_abs: 0.5, formula: "≤0.05t 且最大 0.5" },
                    C: { value: 0.1, ref: "t", max_abs: 1.0, formula: "≤0.1t 且最大 1.0" },
                    D: { value: 0.15, ref: "t", max_abs: 1.5, formula: "≤0.15t 且最大 1.5" } } }
      ];
    }
    return base;
  }

  function bindPackEvents() {
    const sf = $("std_fatigue"), sa = $("std_acceptance");
    if (sf) sf.addEventListener("change", () => {
      try { STD.setActive("fatigue", sf.value); packMsg("✓ 已切换疲劳标准 → " + sf.value); refreshStandards(); }
      catch (e) { packMsg("✗ " + e.message); }
    });
    if (sa) sa.addEventListener("change", () => {
      try { STD.setActive("acceptance", sa.value); packMsg("✓ 已切换验收标准 → " + sa.value); refreshStandards(); }
      catch (e) { packMsg("✗ " + e.message); }
    });

    const pf = $("packFile");
    if (pf) pf.addEventListener("change", (e) => {
      const f = e.target.files && e.target.files[0];
      if (!f) return;
      const rd = new FileReader();
      rd.onload = () => {
        const r = STD.importPack(String(rd.result));
        let msg = (r.ok ? "✓ " : "✗ ") + r.message;
        if (r.errors && r.errors.length) msg += "<br>错误：" + r.errors.join("；");
        if (r.warnings && r.warnings.length) msg += "<br>⚠ " + r.warnings.join("；");
        packMsg(msg);
        refreshStandards();
        pf.value = "";
      };
      rd.readAsText(f, "utf-8");
    });

    const pt = $("packTemplate");
    if (pt) pt.addEventListener("click", () => {
      const kind = confirm("下载「疲劳标准(fatigue)」模板？\n点「取消」下载「表面验收(acceptance)」模板。") ? "fatigue" : "acceptance";
      download("standard-pack-template-" + kind + ".pack.json", blankTemplate(kind));
    });

    const pe = $("packExport");
    if (pe) pe.addEventListener("click", () => {
      try {
        const raw = localStorage.getItem("wf_packs_user_v1");
        if (!raw || raw === "{}") { packMsg("尚未导入任何外部标准包。"); return; }
        download("my-standard-packs.json", JSON.parse(raw));
      } catch (e) { packMsg("✗ 导出失败：" + e.message); }
    });

    const sn = $("packSchemaNote");
    if (sn) sn.innerHTML =
      `<pre class="code">必填字段：
  schema_version  "1.0"
  pack_id         全程序唯一 ID（小写字母/数字/连字符）
  kind            "fatigue"（疲劳 FAT/S-N）或 "acceptance"（表面缺陷验收）
  code            标准代号，如 "GB 50017-2017"
  title           标准名称
  version         版本年份或版次

疲劳包(fatigue) 还需：
  defaults:            { ref_N, gamma_mf_default, sn_m }   参考循环数 / 分项系数 / S-N 斜率
  detail_categories:   [ { id, fat, name, verified?, note? } ]   细节类别 → FAT(MPa)
  improvement_methods: [ { method, label, factor, max_fat } ]    改善措施：系数与 FAT 上限

验收包(acceptance) 还需：
  levels:         { "B": "最高要求", "C": "中等", "D": "较低" }   质量等级（键即下拉框选项）
  imperfections:  [ { type, label, fatigue_relevant, limits: {
                        B: { value, ref: "t"|"abs", max_abs?, max_pore?, formula? }, ... } } ]

通用可选：region / language / verified / verification_note / sn_curve

规则：
  · 导入时自动校验；同 pack_id 再次导入即“升级”（覆盖旧版本，提示 version 变化）
  · 内置包不可移除，导入包可移除；移除后自动回退到内置默认标准
  · 选择即生效，引擎、缺陷类型下拉、质量等级下拉、改善措施勾选全部随标准包变化
  · 数据仅存本机 localStorage，不上传任何服务器</pre>`;
  }

  /* 切换/导入标准后，刷新所有依赖标准的 UI */
  function refreshStandards() {
    renderStdSelects();
    renderPackList();
    renderQualityLevels();
    renderImprovementBox();
    renderStandards();
  }

  /* ---------- ⑤ 标准库（渲染当前启用标准包的全部条目） ---------- */
  function renderStandards() {
    const k = KB();
    const meta = k.meta || {};
    const f = meta.fatigue || {}, a = meta.acceptance || {};
    let h = "";
    h += `<h4>${f.code || "疲劳标准"} — ${f.title || ""} <span class="tag ${f.verified ? "ok" : "medium"}">${f.verified ? "已校核" : "待校核"}</span></h4>`;
    if (f.note) h += `<p class="hint">${f.note}</p>`;
    h += `<table class="std"><thead><tr><th>细节 ID</th><th>名称</th><th>FAT (MPa)</th></tr></thead><tbody>`;
    (k.detail_categories || []).forEach(d => {
      h += `<tr><td>${d.id}</td><td>${d.name}</td><td>${d.fat}</td></tr>`;
    });
    h += `</tbody></table>`;
    h += `<h4>焊趾改善措施（提升 FAT）</h4>`;
    h += `<table class="std"><thead><tr><th>措施</th><th>系数</th><th>上限 FAT</th></tr></thead><tbody>`;
    (k.improvement_methods || []).forEach(m => {
      h += `<tr><td>${m.label}</td><td>×${m.factor}</td><td>${m.max_fat}</td></tr>`;
    });
    h += `</tbody></table>`;

    h += `<h4>${a.code || "验收标准"} — ${a.title || ""} <span class="tag ${a.verified ? "ok" : "medium"}">${a.verified ? "已校核" : "待校核"}</span></h4>`;
    if (a.note) h += `<p class="hint">${a.note}</p>`;
    const lvKeys = Object.keys((k.iso || {}).levels || {});
    h += `<table class="std"><thead><tr><th>缺陷</th>` +
         lvKeys.map(k2 => `<th>${k2}</th>`).join("") + `<th>疲劳相关</th></tr></thead><tbody>`;
    ((k.iso || {}).imperfections || []).forEach(it => {
      const L = it.limits || {};
      const fmtL = (l) => {
        if (!l) return "—";
        if (l.max_pore != null) return `孔径 ≤${l.max_pore}mm`;
        if (l.value != null) return `${l.value}${l.ref === "t" ? "t" : "mm"}${l.max_abs != null ? ` (≤${l.max_abs})` : ""}`;
        return "—";
      };
      h += `<tr><td>${it.label}</td>` + lvKeys.map(k2 => `<td>${fmtL(L[k2])}</td>`).join("") +
           `<td>${it.fatigue_relevant ? "是" : "—"}</td></tr>`;
    });
    h += `</tbody></table>`;
    $("stdLib").innerHTML = h;
  }

  /* ---------- 事件绑定 ---------- */
  $("calc").addEventListener("click", assess);

  $("copy").addEventListener("click", () => {
    const txt = JSON.stringify(window.__lastReport || {}, null, 2);
    if (navigator.clipboard) navigator.clipboard.writeText(txt).then(() => alert("已复制 JSON"));
    else alert(txt);
  });

  /* ---------- 报告导出（iPad 友好：应用内显示 + 下载 HTML + 复制文本 + 尽量打印） ---------- */
  // 说明：iPad「添加到主屏幕」后的 standalone PWA 中 window.print()/window.open 常被忽略，
  // 因此改为在应用内弹窗显示干净报告，并提供「下载 HTML（存到文件）/ 复制文本」可靠路径。
  const REPORT_CSS = `
 body{font-family:-apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;color:#111;max-width:820px;margin:24px auto;padding:0 18px;line-height:1.5}
 h1{color:#0b3d91;font-size:22px;margin:0 0 4px}
 .sub{color:#666;font-size:12px;margin-bottom:14px}
 h2{font-size:15px;border-left:4px solid #0b3d91;padding-left:8px;margin:18px 0 8px}
 table{width:100%;border-collapse:collapse;font-size:13px}
 td{padding:5px 8px;border-bottom:1px solid #eee;vertical-align:top}
 td.k{font-weight:600;width:40%}
 .pass{color:#1f8a4c;font-weight:700}.fail{color:#c0392b;font-weight:700}
 .tag{display:inline-block;padding:1px 7px;border-radius:6px;font-size:11px}
 .high{background:#fdecea;color:#c0392b}.medium{background:#fff4e0;color:#b9770e}
 .low{background:#e7f0ff;color:#0b3d91}.ok{background:#e8f6ee;color:#1f8a4c}
 .box{background:#f7f9fc;border:1px solid #e3e8f0;border-radius:8px;padding:8px 10px;margin:6px 0;font-size:12px}
 .disc{color:#888;font-size:11px;margin-top:16px}`;
  const esc = (x) => String(x == null ? "" : x).replace(/[&<>]/g,
    c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const row2 = (k, v) => `<tr><td class="k">${esc(k)}</td><td>${v}</td></tr>`;

  function reportInner(rep) {
    const R = rep.result;
    const meta = STD.knowledge().meta || {};
    const fCode = (meta.fatigue && meta.fatigue.code) || "疲劳标准";
    const aCode = (meta.acceptance && meta.acceptance.code) || "验收标准";
    const now = new Date().toLocaleString("zh-CN");
    const fc = R.fatigue;
    let h = `<h1>焊缝疲劳合规检查报告</h1>
 <div class="sub">生成时间：${esc(now)} ｜ 依据：${esc(fCode)} ＋ ${esc(aCode)} ｜ 程序内封装标准，离线生成</div>`;
    h += `<h2>疲劳强度</h2><table>`;
    h += row2("细节类别", `${esc(fc.detail_name)} (${esc(fc.detail_id)})`);
    h += row2("基准 FAT", fc.base_fat);
    (fc.improvements || []).forEach(im =>
      h += row2("改善措施", `${esc(im.label)} ×${im.factor} → FAT ${Math.round(im.fat_after)}`));
    h += row2("有效 FAT", Math.round(fc.effective_fat));
    h += row2("应力幅 Δσ", `${fc.delta_sigma} MPa (γ_Mf=${fc.gamma_mf})`);
    h += row2("允许次数", fmt(fc.n_allowable));
    h += row2("需求次数", fmt(fc.n_required));
    h += row2("利用率", `${isFinite(fc.utilization) ? fc.utilization.toFixed(3) : "∞"} （>1 不满足）`);
    h += row2("疲劳结论", `<span class="${fc.pass ? "pass" : "fail"}">${fc.pass ? "满足 ✓" : "不满足 ✗"}</span>`);
    h += `</table>`;
    if (R.dr && R.dr.warnings && R.dr.warnings.length) {
      h += `<h2>① 识别出的不合理/疲劳不利细部（3D 设计）</h2>`;
      R.dr.warnings.forEach(w => {
        h += `<div class="box"><b><span class="tag ${w.severity}">${esc(w.severity)}</span> ${esc(w.id)} ${esc(w.title)}</b><br>${esc(w.finding)}</div>`;
      });
    }
    h += `<h2>② 表面缺陷（${esc(aCode)} ${esc(R.userParams.quality_level)} 级）</h2><table>`;
    if (!R.impResults.length) h += `<tr><td class="k">缺陷</td><td>未记录缺陷</td></tr>`;
    R.impResults.forEach(r => {
      const st = r.accepted === true ? `<span class="pass">通过</span>`
        : (r.accepted === false ? `<span class="fail">超差</span>` : "未判定");
      const fr = r.fatigue_relevant ? " <b>[疲劳相关]</b>" : "";
      h += row2(`${esc(r.label)}${fr}`, `${st} ｜ ${esc(r.limit)}`);
    });
    h += `</table>`;
    h += `<h2>③ 改善建议（按优先级）</h2>`;
    R.plan.forEach(p => {
      const tgt = p.raises_fat_to ? `（目标 FAT≈${p.raises_fat_to}）` : "";
      h += `<div class="box"><b><span class="tag ${p.priority}">${esc(p.priority)}</span> ${esc(p.rule_id)} ${esc(p.title)}</b>` +
           `<div style="margin-top:3px">${esc(p.action)} ${esc(tgt)}</div>` +
           (p.effort ? `<div style="color:#666;font-size:11px">工作量：${esc(p.effort)}</div>` : "") + `</div>`;
    });
    h += `<p class="disc">⚠ 辅助判定，非认证检测；结论须由具备资质人员依据适用规范复核。</p>`;
    return h;
  }

  function reportFullDoc(inner) {
    return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>焊缝疲劳合规检查报告</title>` +
      `<style>${REPORT_CSS}</style></head><body>${inner}</body></html>`;
  }

  function reportText(rep) {
    const R = rep.result, meta = STD.knowledge().meta || {};
    const fCode = (meta.fatigue && meta.fatigue.code) || "疲劳标准";
    const aCode = (meta.acceptance && meta.acceptance.code) || "验收标准";
    const fc = R.fatigue;
    const L = [];
    L.push("焊缝疲劳合规检查报告");
    L.push("生成时间：" + new Date().toLocaleString("zh-CN") + " ｜ 依据：" + fCode + " + " + aCode);
    L.push("");
    L.push("【疲劳强度】");
    L.push("细节类别：" + fc.detail_name + " (" + fc.detail_id + ")");
    L.push("基准 FAT：" + fc.base_fat);
    (fc.improvements || []).forEach(im => L.push("改善措施：" + im.label + " ×" + im.factor + " → FAT " + Math.round(im.fat_after)));
    L.push("有效 FAT：" + Math.round(fc.effective_fat));
    L.push("应力幅 Δσ：" + fc.delta_sigma + " MPa (γ_Mf=" + fc.gamma_mf + ")");
    L.push("允许次数：" + fmt(fc.n_allowable));
    L.push("需求次数：" + fmt(fc.n_required));
    L.push("利用率：" + (isFinite(fc.utilization) ? fc.utilization.toFixed(3) : "∞") + " （>1 不满足）");
    L.push("疲劳结论：" + (fc.pass ? "满足" : "不满足"));
    if (R.dr && R.dr.warnings && R.dr.warnings.length) {
      L.push(""); L.push("【① 不合理/疲劳不利细部】");
      R.dr.warnings.forEach(w => L.push("· " + w.id + " " + w.title + "：" + w.finding));
    }
    L.push(""); L.push("【② 表面缺陷（" + aCode + " " + R.userParams.quality_level + " 级）】");
    if (!R.impResults.length) L.push("未记录缺陷");
    R.impResults.forEach(r => {
      const st = r.accepted === true ? "通过" : (r.accepted === false ? "超差" : "未判定");
      L.push("· " + r.label + (r.fatigue_relevant ? " [疲劳相关]" : "") + "：" + st + " | " + (r.limit || ""));
    });
    L.push(""); L.push("【③ 改善建议】");
    R.plan.forEach(p => L.push("· [" + p.priority + "] " + p.rule_id + " " + p.title + "：" + p.action +
      (p.raises_fat_to ? (" 目标FAT≈" + p.raises_fat_to) : "") + (p.effort ? (" 工作量：" + p.effort) : "")));
    L.push(""); L.push("⚠ 辅助判定，非认证检测；结论须由具备资质人员依据适用规范复核。");
    return L.join("\n");
  }

  function showReport() {
    const rep = window.__lastReport;
    if (!rep) { alert("请先点「计算评估」生成结果，再导出报告。"); return; }
    $("reportBody").innerHTML = reportInner(rep);
    window.__lastReportInner = reportInner(rep);
    $("reportModal").hidden = false;
  }

  function downloadReport() {
    const inner = window.__lastReportInner || reportInner(window.__lastReport);
    const blob = new Blob([reportFullDoc(inner)], { type: "text/html;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = "焊缝疲劳合规检查报告.html";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 3000);
  }

  function fallbackCopy(txt) {
    const ta = document.createElement("textarea"); ta.value = txt;
    ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); alert("报告文本已复制到剪贴板。"); }
    catch (e) { alert(txt); }
    ta.remove();
  }

  function copyReport() {
    const txt = reportText(window.__lastReport);
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(txt).then(() => alert("报告文本已复制。")).catch(() => fallbackCopy(txt));
    } else fallbackCopy(txt);
  }

  function printReport() {
    const inner = window.__lastReportInner || reportInner(window.__lastReport);
    const w = window.open("", "_blank");
    if (!w) { alert("打印被浏览器拦截。请改用「下载 HTML」后在 Safari 中用分享→打印→存 PDF。"); return; }
    w.document.open(); w.document.write(reportFullDoc(inner)); w.document.close();
    w.document.title = "焊缝疲劳合规检查报告";
    setTimeout(() => { try { w.focus(); w.print(); } catch (e) { alert("当前环境打印不可用，请改用「下载 HTML」。"); } }, 400);
  }

  $("report").addEventListener("click", showReport);
  $("rptDownload").addEventListener("click", downloadReport);
  $("rptCopy").addEventListener("click", copyReport);
  $("rptPrint").addEventListener("click", printReport);
  $("rptClose").addEventListener("click", () => { $("reportModal").hidden = true; });

  function updateNet() {
    const el = $("netState");
    if (!el) return;
    el.textContent = navigator.onLine ? "在线（标准仍本地加载）" : "离线就绪";
    el.classList.toggle("pill-off", !navigator.onLine);
  }
  window.addEventListener("online", updateNet);
  window.addEventListener("offline", updateNet);

  /* ---------- 3D 模型导入与对比（按钮接线，渲染由 js/three_viewer.js 提供） ---------- */
  function bind3D() {
    const mf = $("modelFile");
    if (mf) mf.addEventListener("change", (e) => {
      const f = e.target.files && e.target.files[0];
      window.__modelFile = f || null;
      const open = $("openModel"), info = $("modelInfo");
      if (f) {
        open.disabled = false;
        const mb = (f.size / 1048576).toFixed(2);
        const isStep = /\.(step|stp|iges|igs|p21)$/i.test(f.name);
        info.textContent = "已选择：" + f.name + "（" + mb + " MB）。点「打开 3D 对比视图」。" +
          (isStep ? " STEP/IGES 将在 iPad 端侧用 OpenCascade(WASM) 解析，不上传服务器。" : "");
      } else { open.disabled = true; info.textContent = "尚未加载模型。"; }
    });
    const open = $("openModel");
    if (open) open.addEventListener("click", () => {
      if (window.WF3D) window.WF3D.open(window.__modelFile);
      else alert("3D 渲染模块尚未就绪，请刷新页面，或确认 vendor/ 文件完整、Service Worker 已更新。");
    });
    const close = $("modelClose");
    if (close) close.addEventListener("click", () => { $("modelModal").hidden = true; });
    const fill = $("fillDesign");
    if (fill) fill.addEventListener("click", () => { if (window.WF3D) window.WF3D.fillDesign(); });
  }

  bindPackEvents();
  bind3D();
  refreshStandards();
  updateNet();

  // 标注模式开关（位置点 / 尺寸框 的显示与隐藏）
  const annoToggle = $("annoToggle");
  if (annoToggle) annoToggle.addEventListener("click", () => setAnnoMode(!showAnnos));
  updateAnnoToggle();

  /* ---------- Service Worker 注册 ---------- */
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => {
      navigator.serviceWorker.register("sw.js").catch(() => {});
    });
  }
})();
