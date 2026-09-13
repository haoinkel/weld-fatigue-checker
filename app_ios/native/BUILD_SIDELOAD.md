# 免费侧载手册（无 $99 账号、无自有 Mac）

目标：在你**手里的 iPad Pro 2025 (M5, 带 LiDAR)** 上跑起原生 App，
用**免费 Apple ID + Sideloadly** 侧载，不花 $99、不买 Mac。

> 真机已在手 → LiDAR 真值可在 iPad 上验证。唯一缺的是"把源码编成 IPA 的那台 Mac"，
> 这一步交给**云端免费 Mac（GitHub Actions）**或**租一小时云 Mac**完成，你不用拥有 Mac。

---

## 你需要准备的东西

| 项目 | 是否已有 | 说明 |
|------|---------|------|
| iPad Pro 2025 M5（带 LiDAR） | ✅ 已有 | 安装 + LiDAR 真机验证 |
| Windows 电脑 | 需自备 | 跑 Sideloadly 签名安装 |
| 普通 Apple ID（免费） | 需自备 | 就是你的 iCloud 账号，**不是** $99 开发者账号 |
| 能联网的仓库（GitHub） | 需自备 | 走"路径 A"免费云端编译用 |

免费 Apple ID 的限制（须知）：最多同时装 **3 个**自签 App，证书 **7 天**失效需续签。
本 App 未用任何付费能力（ARKit/Photos/PDFKit/LiDAR 均免费），免费账号可正常签名。

---

## 路径 A（推荐，零成本）：GitHub Actions 云端编 IPA

适合：有 GitHub 账号，想"push 一下就拿到 IPA"。**全程无需 $99、无需自有 Mac、无需任何 Secret。**

### A0. 准备仓库（只需做一次）

1. 浏览器打开 https://github.com → 右上角 **＋ → New repository**。
   - Repository name 随便起（如 `weld-fatigue-checker`）。
   - 选 **Public**（免费额度最稳）或 **Private** 均可。
   - **不要**勾选 "Add a README"（保持空仓库，方便首次 push）。
   - 点 **Create repository**。
2. 在本机（Windows）打开终端（Git Bash / PowerShell 均可，需装 Git for Windows），进入工程目录：
   ```bash
   cd "D:/workbuddy/workbuddy学习/weld_fatigue_checker"
   git init
   git add .
   git commit -m "init: weld fatigue checker (native + pwa)"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```
   - 首次 push 会弹窗要你登录 GitHub（或填 Personal Access Token，需 `repo` 权限）。
   - 工程已含 `.github/workflows/build_ipa_sideload.yml` 与 `.gitignore`，push 即带上。

### A1. 触发云端编译

- **方式一（自动）**：上一步 `git push` 后，GitHub 会自动对 `main` 触发工作流。
- **方式二（手动）**：仓库页 → 顶部 **Actions** → 左侧 `Build unsigned IPA (Sideloadly)` →
  右上 **Run workflow** → 选 `main` 分支 → **Run workflow**。

### A2. 等编译 + 下载 IPA

1. 同一 Actions 页会看到一次运行（黄色转圈 → 绿色 ✅），约 **5–15 分钟**。
   - 点进去看日志：应出现 `✅ 未签名 IPA 已生成：build/WeldFatigueChecker-unsigned.ipa`。
2. 运行页底部 **Artifacts** 区 → 点 `WeldFatigueChecker-unsigned` 下载（得到 `.zip`，解压得 `.ipa`）。
   - 这是**未签名** IPA，需要下面用 Sideloadly 在 Windows 上签名。
3. 跳到「在 Windows 上用 Sideloadly 安装」。

> 免费额度提示：GitHub Free 每月有 CI 分钟数，macOS 折算较快；偶尔构建完全够用。
> 若某次运行因"额度用尽"未启动，等次月重置，或把仓库设 Public（Public 仓库 macOS 额度更宽裕）。

> 全程**不需要 $99、不需要 Apple ID 出现在云端、不需要自有 Mac**。
> 云端只负责编译，签名在你自己 Windows 上完成。

---

## 路径 B（没有 GitHub 账户也能用）：租/借一台 Mac 来编

适合：**没有 GitHub 账户**、或想本地完全掌控编译过程。无需 GitHub、无需 $99。

> 没有 GitHub 只是少了"免费云端 CI"这一条；原生 App 编译仍必须在一台 macOS 上完成，
> 所以这一步本质是"弄一台 Mac 的算力"。下面几种方式都不需要 GitHub 账户。

### B1. 租一台按小时计费的云 Mac（推荐，最省事）
远程桌面控制一台真 macOS，跑完即关。编一次约 1 小时足够。

- **XcodeClub / MEGA.io**（专为 iOS 开发，真正按小时，常预装 Xcode，约 $0.5–1/小时）
- **Scaleway Apple Silicon Mac mini**（按量计费，需绑卡；注意有最短计费时长，约 €0.1–0.2/小时）
- **MacStadium**（通常月租，适合长期；短期不划算）

步骤：
1. 注册并开机一台 macOS（选**预装 Xcode**的镜像最好；否则 `xcode-select --install` + App Store 装 Xcode）。
2. 把工程传上去：供应商一般提供 **Web 上传/控制台** 或 **scp**；没有 GitHub 就用这两样，不必 git。
   - 也可把 `weld_fatigue_checker` 整个文件夹打成 zip 上传解压。
3. 进 `app_ios/native` 目录执行：

   ```bash
   bash build.sh ipa
   ```

   产出 `build/WeldFatigueChecker-unsigned.ipa`（未签名）。
4. 把该 IPA 下载回 Windows，跳到「在 Windows 上用 Sideloadly 安装」。

> `bash build.sh ipa` 用 `CODE_SIGNING_ALLOWED=NO` 编出**未签名**包，
> 签名交给 Sideloadly，所以云 Mac 上**不需要**你的 Apple ID、也不需要 $99。

### B2. 借/用别人的 Mac（朋友、网吧、公司闲置机）
在他们的 Mac 上同样执行 `bash build.sh ipa`，把 `WeldFatigueChecker-unsigned.ipa` 拷给你即可。
无需你自己的任何账户。

### B3. 找人代编（freelance / 熟人）
把源码发给有 Mac + 开发者环境的人，请他跑 `bash build.sh ipa` 把**未签名 IPA** 发你；
你回 Windows 用 Sideloadly + 免费 Apple ID 自己签名安装（UDID 注册在你这边完成）。
注意：只发"未签名 IPA"给自己签，别让他用他的 $99 账号给你出正式包（那会变成他的分发）。

### B4. 若愿开"任意"免费 git 账户（非 GitHub）
Codemagic / Bitrise 等 CI 提供**免费 macOS 额度**，可连 **GitLab / Bitbucket** 免费仓库
（不必是 GitHub）。流程与路径 A 几乎一样，只是把 GitHub 换成 GitLab/Bitbucket + Codemagic。
适合"不想用 GitHub 这个网站"但愿意用别的免费账号的人。

### B5. 完全不碰任何账户、也不花钱
只能**先用 PWA 顶着**：自动标注 + 标定已覆盖"检测/位置/尺寸(mm)"，唯一缺的是真·LiDAR mm
（WebKit 不开放深度摄像头，PWA 永远拿不到）。等以后愿意开个账户/租一次 Mac，再补原生 LiDAR。

---

## 在 Windows 上用 Sideloadly 安装

1. 下载安装 **Sideloadly**（https://sideloadly.io ，Windows 版，需装 iTunes/Apple Devices 驱动）。
2. iPad 用数据线连 Windows → 弹窗点「信任」→ 在 iPad 上输密码确认「信任此电脑」。
3. 打开 Sideloadly：
   - **IPA** 选刚才下载的 `WeldFatigueChecker-unsigned.ipa`
   - **Apple ID** 填你的免费账号、**Password** 填账号密码
     （免费账号会触发「应用专用密码」提示，按提示在 appleid.apple.com 生成一个应用专用密码填入）
   - 设备自动识别为你的 iPad
   - 点 **Start** → Sideloadly 会**自动**用免费账号生成描述文件、把你 iPad 的 UDID 注册进去、签名并安装。
4. iPad 上首次打开：
   - 设置 → 通用 → VPN与设备管理 → 在「开发者 App」下信任你的 Apple ID → 返回桌面打开 App。
5. 现在可用**原生 LiDAR**：进「📡 LiDAR」页，对准焊缝即可量取余高/咬边/错边真实 mm。

> Sideloadly 用免费 Apple ID 时会自动处理设备注册与描述文件，无需你去开发者网站手动加 UDID。

---

## 7 天续签（尽量避免每次都连电脑）

免费证书 7 天失效。两种续法：

- **法 1（连电脑）**：7 天后重连 iPad 到 Windows，开 Sideloadly 点 **Start** 重新签名安装。
- **法 2（不连电脑，推荐）**：装 **SideStore**（用 Sideloadly 把 SideStore 本身也侧载一次），
  之后在 iPad 上打开 SideStore → 选本 App → **Refresh**，可无线续签（同样 7 天，但不用电脑）。
  SideStore 首次安装同样走 Sideloadly。

> 提示：免费账号同时只能有 3 个自签 App。SideStore 占 1 个，本 App 占 1 个，留 1 个余量。

---

## 常见坑

- **「无法验证 App」**：设置→通用→VPN与设备管理→信任该开发者账号。每 7 天重签后可能需再信任一次。
- **安装失败/卡住**：确认 iTunes(或 Apple Devices) 驱动已装；iPad 已「信任此电脑」；Apple ID 密码用应用专用密码。
- **Sideloadly 提示设备未注册**：一般会自动注册；若报错，按提示去 appleid.apple.com 查 UDID 并手动加到账号（免费账号也可在 Xcode 外通过 Sideloadly 自动完成，重试即可）。
- **想要 .step/.iges 直读（OCCT）**：需先在 Mac 跑 `./build_occt_ios.sh` 再 `./build.sh ipa`。
  免费侧载同样支持（OCCT 是静态库，已链进 App，Sideloadly 一并签名）。

---

## 与 $99/TestFlight 路线的区别

| 维度 | 本路线（免费侧载） | 路线 A（TestFlight，$99） |
|------|------------------|--------------------------|
| 费用 | 0（GitHub 免费额度内） | $99/年 |
| 证书有效期 | 7 天，需续签 | 90 天（TestFlight 内部测试） |
| 同时安装数 | ≤3 个自签 App | 最多 100 台测试设备 |
| 需要自有 Mac | 否（云端编） | 否（云端编） |
| LiDAR 真机验证 | ✅ 你的 iPad | ✅ 你的 iPad |
| 适合 | 个人自测/长期把玩 | 团队分发/对外测试 |

选免费侧载 = 个人长期使用完全够；若以后要给别人演示或不想每 7 天续签，再升级 $99 + TestFlight 即可（代码不用改）。
