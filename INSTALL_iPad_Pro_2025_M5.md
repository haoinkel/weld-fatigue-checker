# iPad Pro 2025 11 英寸（M5 芯片）— 焊缝疲劳检查器安装及使用说明

> 适用对象：在 iPad Pro 2025（11"、M5，含 LiDAR）上安装并使用「焊缝疲劳合规检查器」。
> 程序基于 EN 1993-1-9:2005 与 ISO 5817:2023 两本标准，并预留开放接口，方便后续补充 GB 50017、IIW-2259、AWS D1.1、BS 7608、DNV-RP-C203、JSSC 等标准。
>
> 本说明文档同时适用于两种安装形态，按需二选一：
>
> | 形态 | 优点 | 缺点 | 推荐场景 |
> |---|---|---|---|
> | **A. PWA 渐进式 Web App** | 今日即可装，不需 Mac，不需要证书 | 受浏览器能力限制，无 LiDAR、无端侧 Core ML | 现场快速试用、给同事演示 |
> | **B. 原生 SwiftUI App** | 真·生产级（Core ML 端侧推理 + LiDAR 免参照物自动测距） | 需一台 Mac + Xcode | 长期生产使用、要求离线完整功能 |

---

## 目录
- [1. 设备 / 系统要求](#1-设备--系统要求)
- [2. 安装形态 A：PWA（推荐先走这条路）](#2-安装形态-apwa推荐先走这条路)
- [3. 安装形态 B：原生 SwiftUI App](#3-安装形态-b原生-swiftui-app)
- [4. 首次使用流程](#4-首次使用流程)
- [5. 拍焊缝照时的建议](#5-拍焊缝照时的建议)
- [6. 标准包管理（开放接口）](#6-标准包管理开放接口)
- [7. 出报告](#7-出报告)
- [8. 常见问题](#8-常见问题)
- [9. 数据安全 & 离线保证](#9-数据安全--离线保证)
- [10. 免责声明](#10-免责声明)

---

## 1. 设备 / 系统要求

| 项 | 要求 |
|---|---|
| 设备 | iPad Pro 11 英寸（2025 款） |
| 芯片 | Apple M5（含 16 核 Neural Engine，能本地跑 Core ML 模型） |
| 系统 | iPadOS 17 及以上（推荐 iPadOS 18） |
| 存储 | 形态 A：约 5 MB；形态 B：约 80 MB（含 Core ML 模型） |
| 网络 | 首次安装时联网即可；之后完全离线运行 |
| 账户 | 无需 Apple ID（A 形态）；B 形态需 Apple Developer 账户才可发布到 App Store，免费账户可生成 7 天证书供内部分发 |

---

## 2. 安装形态 A：PWA（推荐先走这条路）

### 2.1 把程序文件放到一个网址
本程序是一组静态文件（HTML + JS + JSON），需要托管到一个 **HTTPS 的网址** 才能装到 iPad。

最容易的三种方法（任选其一，5 分钟内完成）：

#### 方法 ① Netlify Drop（最快，零账号也可拖文件）
1. 浏览器打开 https://app.netlify.com/drop （注意 `https`）。
2. 把整个目录 `app_ios/pwa/` **拖到网页中央**（包括子目录 `js/`、`icons/` 等）。
3. 30 秒后你会得到一个形如 `https://random-name-123.netlify.app/` 的网址。

#### 方法 ② GitHub Pages（推荐长期使用）
1. 在 GitHub 新建仓库，例如 `weld-fatigue-checker`。
2. 把 `app_ios/pwa/` 内的全部内容上传到仓库根目录。
3. `Settings → Pages → Build from main branch` → 保存。
4. 几分钟后你会得到 `https://你的用户名.github.io/weld-fatigue-checker/`。

#### 方法 ③ 内网自建 / 私有云
把目录放在一台内网机器（Nginx / IIS / Python `http.server`），配上 HTTPS 证书（Let's Encrypt 或公司内网 CA）。
> ⚠ **iPad Safari 严格要求 HTTPS**，明文 HTTP 无法注册 Service Worker，也就装不成 PWA。

### 2.2 在 iPad 上安装
1. iPad 打开 Safari，访问上一步的网址（例如 `https://xxx.netlify.app/`）。
2. 等待页面加载完成（第一次需联网，Service Worker 会缓存全部资源）。
3. 点击底部分享按钮（方框 + 向上箭头）→ **添加到主屏幕**。
4. 名称写"焊缝疲劳检查"→ **添加**。
5. 回到主屏幕，应能看到带 ⚡ 图标的 App。点开即可全屏运行。

### 2.3 验证离线
将 iPad 飞行模式后再打开 App，能正常加载与所有功能即表示离线安装成功。顶部状态会显示「离线就绪」。

### 2.4 安装注意事项
- 一定要用 **Safari**（不要用 Chrome / Edge，iOS 不允许它们安装 PWA）。
- 添加到主屏幕后，**iOS 会留一份独立窗口**，没有浏览器地址栏（看起来像原生 App）。
- 在「设置 → Safari → 高级 → JavaScript」必须开启（默认开着）。
- 如果出现空白页：在「设置 → Safari → 高级 → 网站数据」中清除该域名的数据，然后重开 Safari。

---

## 3. 安装形态 B：原生 SwiftUI App

> 仅当你有 Mac + Xcode + 想要 LiDAR 免参照物测距 时才走这条路。本文档只列步骤，详见 `app_ios/native/README.md`。

### 3.1 准备一台 Mac
- Mac（macOS 14 Sonoma 或更新）
- App Store 下载并安装 **Xcode 16.x**（须与 iPadOS 18 兼容的版本）
- 命令行工具：`xcode-select --install`

### 3.2 创建 Xcode 工程
1. 启动 Xcode → File → New → Project → **iOS → App**。
2. 填：Product Name `WeldFatigueChecker`，Interface **SwiftUI**，Language **Swift**，Bundle Identifier 自有（如 `com.yourorg.weldfatiguechecker`）。
3. 把 `app_ios/native/WeldFatigueChecker/` 内所有 `.swift` 文件、 `Resources/` 目录、 `Info.plist` 拖入工程。
4. 在 Xcode **Signing & Capabilities** 中：
   - 选你的 Apple ID（免费账户即可，但 7 天有效）
   - 勾选 Capabilities 中加入 ARKit（用 LiDAR 时）
5. 把 iPad 通过 USB-C 接到 Mac，Xcode 顶栏选你的 iPad → Run（⌘R）。

### 3.3 不签名内部安装（AltStore / Sideloadly）
如果你不想连 Xcode 跑，可以：
1. Xcode → Product → **Archive** → Distribute App → **iOS App Store → Export**。
2. 用 [AltStore](https://altstore.io) 或 [Sideloadly](https://sideloadly.io) 在 iPad 上自助签名安装。
3. ⚠ 自签名安装后 **7 天过期**（免费账号）或 **365 天**（付费开发者）；过期重新签名即可。

### 3.4 标准包如何打进 App
- 内置标准包：放在 `app_ios/native/WeldFatigueChecker/Resources/packs/*.pack.json`，编译时 Xcode 会自动复制进 `.ipa` 包内，App 启动即可读取。
- 用户导入：用户在 App 内点击「导入标准包」选 `.pack.json`，文件会写入 App 的 `Documents/StandardPacks/` 目录。在「文件」App 中 App 的"文稿"目录下可见，便于 AirDrop 传入多台 iPad 共享。

---

## 4. 首次使用流程

### 4.1 决定判定依据
App 启动后，到「③ 荷载参数」页，**判定依据** 下拉：

- **综合：3D 定 FAT + 照片定缺陷**（最常见，用于真正项目的评估）
- **仅照片：识别接头定 FAT + 缺陷**（最省事，但要求照片角度能看清接头形式）
- **仅 3D 设计：审查细部合理性**（设计阶段细审，暂不评疲劳寿命）

### 4.2 录入焊缝外观（仅 PWA 与原生 App 通用思路）
1. 点「拍摄 / 选择照片」：iPad 相机拍摄或从相册选；
2. 检查图像是否清晰包含整段焊缝、附近 5cm 母材、焊趾；
3. 点击照片标出缺陷位置（红点）→ 自动加入"已识别/标注的缺陷"；
4. 用「参照物 + 比例标定」量出每处缺陷的真实尺寸：
   - 场景里放直尺 / Aruco / 银行卡片（默认 85.6 mm）；
   - 点「📏 标定比例」→ 点参照物两端 → 填入实际长度 → 自动换算 `px/mm`；
   - 再点「📐 测量缺陷」→ 点缺陷两端 → 真实 mm 自动填到缺陷行。
   - 原生 App 形态 B 可用 **LiDAR 自动测距**，无需参照物。
5. 填入：接头类型 / 荷载方向 / 母材板厚 / 质量等级 / 已实施的焊趾改善措施。

### 4.3 录入 3D 设计（设计 / 综合模式）
1. 到「② 3D 设计合理性审查」页，按实际 CAD/IFC 模型填入：
   - 接头类型 / 焊缝类型 / 荷载方向 / 是否承载 / 是否全熔透 / 是否打磨齐平
   - 附件长度 / 板厚 / 是否切孔 / 是否在拉应力区
   - 加劲肋端部 / 盖板端部 / 错边量 / 引收弧板 / 是否高周
2. 勾上"已实施的焊趾改善措施"。

### 4.4 录入荷载参数
1. 应力幅 Δσ（MPa）：**这一项必须由设计/仿真/传感器给出**，照片给不了。
   > 经验：起重机主梁典型 Δσ ≈ 60–100 MPa；桥梁典型 ≈ 30–80 MPa。
2. 需求循环次数 N：
   - 默认 **2 000 000**（相当于 EN 标准中的 2×10⁶ 参考循环）。
   - 如做桥梁评估：常按 5 000 000 ~ 10 000 000 取。
3. 疲劳分项系数 γ_Mf：
   - 1.00：现场已有监控数据；
   - 1.15：详细评估，含疲劳载荷谱；
   - 1.35：简化评估（保守）。

### 4.5 计算评估
- 点「计算评估」→ 出来结果：
  - 细节类别与基准 FAT
  - 改善后的有效 FAT
  - 允许循环次数 vs 需求循环次数
  - **利用率 ≤1 → 满足 ✓；>1 → 不满足 ✗**
- 同一屏还会给出：
  - ① 识别出的不合理细部（按 R1~R16）——严重度标签 + 整改动作 + 目标 FAT + 工作量
  - ② 表面缺陷验收结果（依 ISO 5817 质量等级 B/C/D）
  - ③ 改善建议（按优先级排序）

---

## 5. 拍焊缝照时的建议

| 关键点 | 做法 |
|---|---|
| 光线 | 自然光 + 阴影下补光；避免金属反光直射镜头 |
| 角度 | 镜头与焊缝表面 **≈30°–45°**；不要正对焊缝 |
| 距离 | 30–60 cm，避免广角畸变 |
| 视野 | 整段焊缝 + 两端至少 50 mm 母材，方便看附件长度 |
| 比例 | 拍时**随手放参照物**（直尺 / Aruco / 银行卡片）；PWA 测距完全靠它 |
| 锐度 | 点聚焦焊缝后再按快门；微小裂纹要观察出焦糊状咬边的转变 |
| 多角度 | 关键节点拍 2 张（俯视 + 接近侧视）便于补全 3D 估值 |

---

## 6. 标准包管理（开放接口）

本程序最重要的特性之一 —— **不需要改一行代码就能加新标准**。

### 6.1 已内置（随程序打包、离线可用）
- **EN 1993-1-9:2005** — 疲劳 FAT/S-N（24 条细节类别）
- **ISO 5817:2023** — 焊缝表面缺陷验收（5 类缺陷、B/C/D 等级）

### 6.2 添加第二本标准（三种方式任选）

#### 方式 ① 在 PWA 中直接导入（最快）
1. 准备一个符合 schema 的 JSON 文件（例如 `gb50017-2017.pack.json`）。
2. 模板可在 PWA 中点「下载空白模板」获取。
3. 在 App 内「④ 标准包管理」→ 「导入标准包」→ 选文件。
4. 导入后下拉框立刻出现新标准，**选它即生效**。

#### 方式 ② 在原生 App 中导入
1. 把 `.pack.json` 通过 AirDrop 发到 iPad。
2. 在「文件」App 选择 iPad 内的文件 → 用"WeldFatigueChecker"打开。
3. 或在 App 内「标准包」→ 「导入」选择文件。
4. 也可把文件放进 Files App 内 `WeldFatigueChecker → StandardPacks` 目录，App 自动扫描识别。

#### 方式 ③ 直接打进 App 包（适合 OTA 升级）
1. 把 `.pack.json` 放到 `app_ios/native/WeldFatigueChecker/Resources/packs/`。
2. 重新编译 iPad App → 新版安装后可用。

### 6.3 如何编写新标准包
JSON Schema v1.0 字段（建议复制模板后改）：

```
必填字段：
  schema_version   "1.0"
  pack_id          全程序唯一 ID（小写字母/数字/连字符）
  kind             "fatigue"（疲劳 FAT/S-N）或 "acceptance"（表面缺陷验收）
  code             标准代号，如 "GB 50017-2017"
  title            标准名称
  version          版本年份或版次

疲劳包(fatigue) 还需要：
  defaults         { ref_N, gamma_mf_default, sn_m }                ←参考循环数 / 分项系数 / S-N 斜率
  detail_categories [ { id, fat, name, verified?, note? } ]         ←细节类别 → FAT(MPa)
  improvement_methods[ { method, label, factor, max_fat, note? } ]  ←改善措施：系数与 FAT 上限

验收包(acceptance) 还需要：
  levels           { "B": "最高要求", "C": "中等", "D": "较低" }    ←质量等级（键即下拉框选项）
  imperfections    [ { type, label, fatigue_relevant, limits: {
                       B: { value, ref: "t"|"abs", max_abs?, max_pore?, formula? }, ... } } ]

通用可选：region / language / verified / verification_note / sn_curve
```

完整模板下载见 PWA 「下载空白模板」或原生 App 「复制标准包空白模板」按钮，或仓库 `samples/gb50017-2017.pack.json`。

### 6.4 升级已存在的标准
同一个 `pack_id` 再次导入 = **升级**（用新字段覆盖旧版本，提示 version 变化）。同一类型（fatigue/acceptance）保证有且只有一个被启用。

### 6.5 移除 / 回退
- 内置包（随程序打包）**不可移除**。
- 导入包可移除：被移除后该 kind 的启用项会自动回退到内置默认标准。

### 6.6 注意事项
- `verified=false` 的标准包只能作 demo，**正式用于工程判定前须用原文逐条校核**。
- FAT 值随版本演进：建议在 `verification_note` 字段记下与原文表号/页码/版本日期，方便升级后审计。
- 切换疲劳标准后，3D 审查的 R1~R16 规则需要针对新标准的细节 ID 重新映射（如 GB 50017 用 J1–J9）；当前版本以 EN1993-1-9 ID 为主，要做 GB 时把 `DesignReviewer.matchDetail` 函数补一份新规则即可。

---

## 7. 出报告

### 形态 A：PWA
- 点「导出报告(PDF)」→ 调用 iOS 打印对话框 → 选"保存到文件"或"标记"成 PDF。
- 也可点「复制 JSON」复制完整结构化结果（便于后续二次处理）。

### 形态 B：原生 App
- 形态 B 在结果视图内置「生成 PDF」按钮，用 PDFKit 直接生成带照片标注框的 PDF 报告，无需弹系统打印框。
- 文件自动保存到 App 内"文稿"目录，并出现在「文件」App 中。

### 报告内容
- 头部：采用的疲劳标准与验收标准（含版本、校核状态）
- ① 疲劳强度：细节类别 → 基准 FAT → 改善后有效 FAT → Δσ → 允许/需求次数 → 利用率 → 结论
- ② 识别出的不合理/疲劳不利细部（R1~R16）：含严重度、描述、改型动作、目标 FAT、工作量
- ③ 表面缺陷验收：每条 → 阈值 vs 实测 → 是否通过 → 是否疲劳相关
- ④ 改善建议（按优先级排序）
- ⚠ 免责声明

---

## 8. 常见问题

**Q1. 添加到主屏幕后图标不是 ⚡ / 不是完整 App 截图？**
A：Safari 默认会用当前页面的截图。可在「设置 → Safari → 高级 → Website Data」清除该域缓存后重试一次"添加到主屏幕"。

**Q2. Service Worker 没注册，离线打不开？**
A：① 必须 HTTPS。② iOS 15.4 之前对 SW 支持差，请升级到 iPadOS 17+。③ Safari 的「阻止跨站跟踪」或「阻止所有 Cookie」**不影响 PWA**，放心。

**Q3. 评估后显示"当前启用的疲劳标准包中找不到细节类别"？**
A：你启用了一个新标准（不同 ID 体系），但 3D / 照片映射函数沿用 EN1993-1-9 的 ID。处理办法有两种：① 切回 EN1993-1-9；② 给新标准在包内补上 EN 兼容的 id（`id` 字段），或在 `DesignReviewer` 加一份新标准的匹配规则。

**Q4. 计算"不满足"，但 Δσ 很小 / N 也小？**
A：检查以下：① 接头类型与"是否承载"是否勾错——这俩决定 FAT 差一个等级（71 → 80 → 125）。② 是否勾上了"已打磨齐平/全熔透/焊趾改善"。③ γ_Mf 是否被设成 1.35。④ 选择的标准包是否被错误切到 GB 之类（ID 不同时）。

**Q5. 缺陷尺寸测出来偏大或偏小？**
A：参照物放的位置太斜 / 拍摄角度偏大都会让 px/mm 估算偏。原生形态 B 用 LiDAR 直接测世界距离能避免。PWA 形态下：① 镜头正对工件，② 参照物放置在**与缺陷同一平面**，③ 不要用鱼眼/超广角镜头。

**Q6. ISO 5817 阈值看起来"过严/过松"？**
A：`knowledge/iso5817.json` 中是按常见经验填的示例值，正式用前**必须**用你手上的 ISO 5817:2023 原文坐实。可下载该标准的高分辨率扫描件后用 PDF 工具逐条核。每一个包都支持 `verified` 字段 + `verification_note` 字段，记得改后置 true 并写明出处。

**Q7. 我手上有大量符合别的标准（如 JSSC、IIW）的焊缝图，能不能直接做成第二个 App？**
A：完全可以。复制一份仓库，把 `standards_fatigue_id` 函数补成新标准的 id 映射，把 `resources/packs/*.pack.json` 换成新标准即可。

---

## 9. 数据安全 & 离线保证

| 维度 | 形态 A PWA | 形态 B 原生 App |
|---|---|---|
| 数据落盘 | iPad Safari 网页存储（同源策略） | iPad App 沙盒 Documents |
| 是否上传网络？ | **否**（除非点"导出"） | **否** |
| 网络依赖 | 首次加载后**完全离线** | **完全离线** |
| 标准来源 | `js/packs.js` 内嵌，可源码查看 | `Resources/packs/*.pack.json` 随 App 打包 |
| 用户照片 | 留在网页内存 | 留在 App 沙盒（不会出现在相册） |
| 卸载 App 后 | 数据清空 | 数据清空 |

两个形态都**不联网、不上传、回溯可审计**。若需长时间存档，请在导出报告时一并归档到企业网盘。

---

## 10. 免责声明

⚠ **本程序为辅助判定工具，非认证检测/认证设计软件。**

- 评估结果仅供工程技术人员参考。
- **最终设计判定与签字必须由具备相应资质的人员（含计算书、原文复核、必要的理化试验）作出**。
- 程序内置数值（尤其 `iso5817.json`、`en1993_1_9.json` 中标 `verified=false` 的条目）须以原文校核后用于工程判定。
- 程序不构成对任何工程质量、寿命或安全的保证。
- 输出报告底部永久标注免责声明。
