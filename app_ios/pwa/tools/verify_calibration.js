// 标定比例校验脚本（与 PWA app.js 完全相同的公式）
// 目的：证明校准算法本身正确，并演示"画布被拉伸"会如何引入比例偏差。
// 运行：node tools/verify_calibration.js

// ---- PWA 采用的公式（节选自 js/app.js）----
// 校准：pxPerMm = 校准点像素距 / 参照物实际mm
// 测量：mm = 测量点像素距 / pxPerMm
// canvasPt 把屏幕坐标按 canvas.width/r.width、canvas.height/r.height 分别映射

function pxDist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }

// 场景 A：正视/平面（x、y 轴缩放一致）—— 理想情况
function scenarioFlat() {
  const refRealMm = 100;            // 参照物 100mm
  // 画布内部分辨率（canvas.width × canvas.height），显示等比缩放
  const canvasW = 900, canvasH = 600;
  const scaleX = canvasW / canvasW, scaleY = canvasH / canvasH; // 显示=内部分辨率
  // 校准：参照物在图上横向占 300 内部分辨率像素
  const calA = { x: 100, y: 300 }, calB = { x: 400, y: 300 };
  const pxPerMm = pxDist(calA, calB) / refRealMm; // = 300/100 = 3 px/mm
  // 测量：一个 50mm 缺陷占 150 内部分辨率像素
  const m1 = { x: 500, y: 300 }, m2 = { x: 650, y: 300 };
  const mm = pxDist(m1, m2) / pxPerMm; // = 150/3 = 50
  return { pxPerMm, mm, scaleX, scaleY };
}

// 场景 B：画布被拉伸（显示宽高比≠内部分辨率），x、y 轴 px/mm 不同
// 这正是只设 width:100% 未保证 height:auto 时可能出的问题
function scenarioStretched() {
  const refRealMm = 100;
  const canvasW = 900, canvasH = 600;
  // 显示尺寸被拉伸：宽 900 显示、高被拉成 800（内部分辨率仍是 600 → 纵向压扁）
  const dispW = 900, dispH = 800;
  const sx = canvasW / dispW; // 1.0
  const sy = canvasH / dispH; // 600/800 = 0.75  ← 纵向缩放与横向不同！
  // 校准用"横向"参照（屏幕 300px → 内部 300px）
  const calA = { sx: 100, sy: 300 }, calB = { sx: 400, sy: 300 };
  const calCanvas = { x: calA.sx * sx, y: calA.sy * sy };
  const calCanvasB = { x: calB.sx * sx, y: calB.sy * sy };
  const pxPerMm = pxDist(calCanvas, calCanvasB) / refRealMm; // 3 px/mm（按横向算）
  // 测量一个 50mm 缺陷，但它是"纵向"的（屏幕 150px 高 → 内部 150*0.75=112.5px）
  const m1 = { sx: 500, sy: 300 }, m2 = { sx: 500, sy: 450 };
  const c1 = { x: m1.sx * sx, y: m1.sy * sy };
  const c2 = { x: m2.sx * sx, y: m2.sy * sy };
  const mm = pxDist(c1, c2) / pxPerMm; // = 112.5/3 = 37.5  ← 应为 50，偏差 -25%
  return { pxPerMm, mm };
}

const A = scenarioFlat();
const B = scenarioStretched();
console.log("=== 场景 A（平面/等比，正确）===");
console.log(`  pxPerMm=${A.pxPerMm}  测得 50mm 缺陷 => ${A.mm.toFixed(1)} mm  ${Math.abs(A.mm-50)<1e-6?"✅ 正确":"❌"}`);
console.log("=== 场景 B（画布纵向被拉伸，单标量 pxPerMm 失效）===");
console.log(`  pxPerMm=${B.pxPerMm}  测得 50mm 缺陷 => ${B.mm.toFixed(1)} mm  ${Math.abs(B.mm-50)<1e-6?"✅":"❌ 偏差 "+(((B.mm-50)/50)*100).toFixed(0)+"%"}`);
console.log("\n结论：校准算法本身正确；但显示画布一旦被拉伸（x/y 缩放不一致），");
console.log("单一 pxPerMm 标量会让不同方向的测量系统性偏差。修复：CSS 强制 height:auto 保持等比，");
console.log("并在标定后绘制可视标尺 + 显示整图物理尺寸，供即时人工校核。");
