/* 3D 模型导入与实物对比（iPad PWA）
 * - STEP/IGES：OpenCascade(WASM, occt-import-js) 端侧解析
 * - GLB/GLTF/OBJ/STL：three.js 加载器
 * - 渲染：three.js + OrbitControls；照片叠加 / 并排对比
 * 依赖 index.html 中的 importmap("three") 与 vendor/occt-import-js.js 提供的全局 occtimportjs()
 */
import * as THREE from "three";
import { OrbitControls } from "../vendor/loaders/OrbitControls.js";
import { OBJLoader } from "../vendor/loaders/OBJLoader.js";
import { STLLoader } from "../vendor/loaders/STLLoader.js";
import { GLTFLoader } from "../vendor/loaders/GLTFLoader.js";

let renderer, scene, camera, controls, modelGroup, rafId;
let stageInited = false;
let occtPromise = null;
let lastSize = null;          // 上次加载模型的包围盒尺寸 {x,y,z}（模型单位，假设 mm）

function getOcct() {
  if (occtPromise) return occtPromise;
  occtPromise = new Promise((resolve, reject) => {
    if (typeof occtimportjs === "undefined") {
      reject(new Error("occt-import-js 未加载（vendor/occt-import-js.js 缺失）"));
      return;
    }
    // locateFile 让 WASM 从 ./vendor/ 加载（离线由 Service Worker 缓存）
    occtimportjs({ locateFile: (p) => new URL("./vendor/" + p, document.baseURI).href })
      .then(resolve)
      .catch(reject);
  });
  return occtPromise;
}

function initStage() {
  const canvas = document.getElementById("modelCanvas");
  const stage = document.getElementById("modelStage");
  const w = stage.clientWidth || 600;
  const h = stage.clientHeight || 420;
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setSize(w, h, false);
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0xf4f6fb);

  camera = new THREE.PerspectiveCamera(45, w / h, 0.1, 100000);
  camera.position.set(0, 0, 300);

  controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.08;

  scene.add(new THREE.AmbientLight(0xffffff, 0.75));
  const d1 = new THREE.DirectionalLight(0xffffff, 0.9); d1.position.set(1, 1.2, 1); scene.add(d1);
  const d2 = new THREE.DirectionalLight(0xffffff, 0.4); d2.position.set(-1, -0.5, -1); scene.add(d2);

  const grid = new THREE.GridHelper(200, 20, 0xcccccc, 0xe6e9f2);
  scene.add(grid);

  modelGroup = new THREE.Group();
  scene.add(modelGroup);

  const ro = new ResizeObserver(() => onResize());
  ro.observe(stage);

  stageInited = true;
  animate();
}

function onResize() {
  if (!renderer) return;
  const stage = document.getElementById("modelStage");
  const w = stage.clientWidth || 600;
  const h = stage.clientHeight || 420;
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}

function animate() {
  rafId = requestAnimationFrame(animate);
  if (controls) controls.update();
  if (renderer) renderer.render(scene, camera);
}

function clearModel() {
  if (!modelGroup) return;
  while (modelGroup.children.length) {
    const c = modelGroup.children.pop();
    if (c.geometry) c.geometry.dispose();
    if (c.material) c.material.dispose();
  }
}

function frameModel() {
  const box = new THREE.Box3().setFromObject(modelGroup);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const maxd = Math.max(size.x, size.y, size.z) || 1;
  modelGroup.position.sub(center);            // 居中
  const dist = maxd / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)));
  camera.position.set(0, 0, dist * 1.4);
  camera.near = maxd / 100;
  camera.far = maxd * 100;
  camera.updateProjectionMatrix();
  controls.target.set(0, 0, 0);
  controls.update();
  return size;
}

function meshFromOcct(m) {
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(m.attributes.position, 3));
  if (m.attributes.normal) g.setAttribute("normal", new THREE.Float32BufferAttribute(m.attributes.normal, 3));
  if (m.index) g.setIndex(new THREE.Uint32BufferAttribute(m.index, 1));
  return g;
}

async function loadFile(file) {
  const name = file.name.toLowerCase();
  const buf = await file.arrayBuffer();
  const geos = [];

  if (name.endsWith(".step") || name.endsWith(".stp") || name.endsWith(".p21") ||
      name.endsWith(".iges") || name.endsWith(".igs")) {
    const occt = await getOcct();
    let meshes;
    if (name.endsWith(".iges") || name.endsWith(".igs")) {
      meshes = occt.ReadIgesFile(new Uint8Array(buf), null).meshes;
    } else {
      meshes = occt.ReadStepFile(new Uint8Array(buf), null).meshes;
    }
    if (!meshes || !meshes.length) throw new Error("STEP/IGES 未解析出任何网格（可能为空文件或格式不被支持）。");
    meshes.forEach((m) => geos.push(meshFromOcct(m)));

  } else if (name.endsWith(".obj")) {
    const txt = new TextDecoder().decode(buf);
    const obj = new OBJLoader().parse(txt);
    obj.traverse((o) => { if (o.isMesh && o.geometry) geos.push(o.geometry); });
    if (!geos.length && obj.geometry) geos.push(obj.geometry);

  } else if (name.endsWith(".stl")) {
    geos.push(new STLLoader().parse(buf));

  } else if (name.endsWith(".glb") || name.endsWith(".gltf")) {
    const gltf = await new GLTFLoader().parseAsync(buf, "");
    gltf.scene.traverse((o) => { if (o.isMesh && o.geometry) geos.push(o.geometry); });

  } else {
    throw new Error("不支持的格式：" + file.name + "（支持 .step/.stp/.iges/.glb/.gltf/.obj/.stl）");
  }

  if (!geos.length) throw new Error("模型未包含任何网格几何。");

  clearModel();
  geos.forEach((geometry) => {
    geometry.computeVertexNormals();
    const mat = new THREE.MeshStandardMaterial({
      color: 0x88a0c8, metalness: 0.25, roughness: 0.65, side: THREE.DoubleSide,
    });
    modelGroup.add(new THREE.Mesh(geometry, mat));
  });
  lastSize = frameModel();
  return lastSize;
}

function setPhotoOverlay() {
  const photo = document.getElementById("modelPhoto");
  const canvas = document.getElementById("canvas");
  if (canvas && canvas.width > 0 && !canvas.hidden) {
    try {
      photo.src = canvas.toDataURL("image/png");
      photo.hidden = false;
      return;
    } catch (e) { /* tainted canvas 等情况忽略 */ }
  }
  photo.hidden = true;
}

function bindStageControls() {
  const split = document.getElementById("splitChk");
  const op = document.getElementById("photoOpacity");
  const stage = document.getElementById("modelStage");
  const photo = document.getElementById("modelPhoto");
  split.addEventListener("change", () => {
    stage.classList.toggle("split", split.checked);
    if (split.checked) photo.hidden = false;       // 并排时强制显示照片
  });
  op.addEventListener("input", () => {
    if (!split.checked) photo.style.opacity = op.value;
  });
}

/* ---------- 公开接口（app.js 调用） ---------- */
window.WF3D = {
  async open(file) {
    const status = document.getElementById("modelStatus");
    const modal = document.getElementById("modelModal");
    if (!file) { alert("请先选择 3D 模型文件。"); return; }
    modal.hidden = false;
    if (!stageInited) { try { initStage(); bindStageControls(); } catch (e) { status.textContent = "WebGL 初始化失败：" + e.message; return; } }
    status.textContent = "正在解析 " + file.name + "（端侧）…";
    try {
      const size = await loadFile(file);
      setPhotoOverlay();
      status.textContent = "已加载：" + file.name + " ｜ 包围盒 " +
        size.x.toFixed(1) + " × " + size.y.toFixed(1) + " × " + size.z.toFixed(1) +
        "（模型单位，通常 mm）。双指拖动旋转、捏合缩放；勾选「并排」可左图右模对比。";
      const fill = document.getElementById("fillDesign");
      if (fill) fill.disabled = false;
    } catch (e) {
      status.textContent = "✗ 解析失败：" + e.message;
    }
  },

  // 把模型包围盒尺寸填入“② 3D 设计合理性审查”表单（单位按模型单位，通常 mm）
  fillDesign() {
    if (!lastSize) { alert("尚未成功加载模型。"); return; }
    const dims = [lastSize.x, lastSize.y, lastSize.z].sort((a, b) => a - b); // 升序
    const thickness = dims[0], length = dims[2];   // 最小边≈板厚，最大边≈长度
    const t = document.getElementById("d_plate_thickness_mm");
    const l = document.getElementById("d_attachment_length_mm");
    if (t) t.value = thickness.toFixed(1);
    if (l) l.value = length.toFixed(1);
    alert("已填入（模型单位，通常 mm，如不一致请人工换算）：\n板厚 t ≈ " +
      thickness.toFixed(1) + " mm\n附件长度 ≈ " + length.toFixed(1) + " mm");
  },
};
