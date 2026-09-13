# 焊缝疲劳检查器 · iPad 可安装 PWA（今日即可装）

无需 Mac、无需开发者账号。用 iPad Safari「添加到主屏幕」即可像原生 App 一样**离线使用**。
逻辑与 Python/Swift 原型同源：`KnowledgeBank`(EN1993-1-9+ISO5817) / `Engine`(FAT/改善/S-N/验收) /
`DesignReview`(R1~R16 规则 + 改型建议)。

目标设备：**iPad Pro 2025 11 英寸（M5）**。

---

## 两个标准已封装在程序里

标准**不是联网查询**，而是直接打包进程序、随安装进入设备：

| 标准 | 封装位置 | 用途 |
|---|---|---|
| EN 1993-1-9:2005 | `js/knowledge.js` → `detail_categories`（24 条细节 + 4 种改善措施） | 细节类别 → FAT |
| ISO 5817:2023 | `js/knowledge.js` → `iso.imperfections`（5 类缺陷 B/C/D 限值） | 表面缺陷验收 |

- App 内 **④ 标准库** 页签可展开查看全部封装内容（FAT 表、改善系数、缺陷限值），
  现场可直接查表，也可据此核对数据来源。
- `sw.js` 已把全部资源（含知识库）缓存进 Service Worker，**断网可用、不回传任何数据**。

---

## 关于 LiDAR（重要）

本机（iPad Pro 2025 M5）**带激光雷达**，但 LiDAR 深度数据由 **ARKit 独占**，
**Safari 中的网页读不到**。因此：

- **本 PWA**：用「参照物标定」——拍照时放入直尺 / Aruco 码 / 银行卡(85.6mm)，
  点「📏 标定比例」点击参照物两端，再点「📐 测量缺陷」点击缺陷两端，即得出真实 mm 尺寸。
- **原生 App**（`../native/`）：才能真正调用 LiDAR 自动测距，免参照物。

> ⚠ PWA 受浏览器能力限制：**无端侧 Core ML 推理、无 ARKit/LiDAR 深度**。
> 要做相机端侧自动识别 + 自动测距，请走 `../native/`（SwiftUI 工程，需 Mac 编译）。
> 本 PWA 已含：相机取景、参照物标定、缺陷测距与标注、完整规则引擎、标准库、离线 PDF 报告。

---

## 在 iPad 上安装（3 步）

PWA 必须**首次通过 HTTPS 加载一次**才能"添加到主屏幕"并离线缓存（Service Worker 要求安全上下文）。

**方式 A：静态托管（推荐，最简单）**
1. 把本 `pwa/` 目录整体上传到任意支持 HTTPS 的静态托管：
   - GitHub Pages（仓库设置 → Pages → 选分支/目录）
   - Netlify Drop（拖文件夹即上线，自动 HTTPS）
   - 任意带有效证书的 Web 服务器
2. 在 iPad 用 Safari 打开该网址。
3. 点 Safari 底部 **分享 ⇪ → "添加到主屏幕"** → 命名"焊缝疲劳检查" → 添加。
   桌面即出现图标，点击进入即全屏离线 App。

**方式 B：本机临时（开发/演示）**
1. 桌面运行：`python -m http.server 8000`（在本 pwa 目录内）。
2. 用 `cloudflared tunnel --url http://localhost:8000`（或 ngrok）拿到 HTTPS 临时地址。
3. iPad Safari 打开该 HTTPS 地址 → 添加到主屏幕。

> 仅需联网这一次；之后 Service Worker（`sw.js`）已缓存全部资源，断网也能用。

---

## 本地预览 / 自测

```bash
cd pwa
python -m http.server 8000      # 桌面浏览器打开 http://localhost:8000 验证 UI
node tools/test_pwa_engine.js   # 验证引擎逻辑（FAT/规则/改善计划/ISO验收）
```

## 文件
```
pwa/
├── index.html            # 应用外壳（外观检查 / 3D设计 / 荷载结果）
├── styles.css
├── manifest.webmanifest  # PWA 安装元数据
├── sw.js                 # 离线缓存 Service Worker
├── icons/                # icon-192 / icon-512 PNG（工具生成）
└── js/
    ├── knowledge.js      # ★ EN1993-1-9 + ISO5817 知识库（随程序打包，离线）
    ├── engine.js         # 疲劳校核引擎
    ├── design_rules.js   # R1~R16 设计规则 + 改型建议
    └── app.js            # UI 交互（参照物标定 / 缺陷测距 / 标准库渲染）
```

## 合规
辅助判定工具，非认证检测；结论须由具备资质人员依据适用规范复核。
