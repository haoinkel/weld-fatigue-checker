# 从建 GitHub 账户到云端编译出 IPA

> 免费 · 无自有 Mac · 无 $99 开发者账号
> 目标：用 GitHub 免费 macOS runner 把原生工程编成【未签名 IPA】，下到 Windows 用
> Sideloadly + 免费 Apple ID 装到你的 iPad Pro 2025 (M5, 带 LiDAR)，即可用原生 LiDAR。

全程只需：GitHub 免费账号 + Windows 电脑 + 一个普通 Apple ID（免费）+ 手里的 iPad。
编译环节由 GitHub 云端 Mac 完成，你不用拥有 Mac、不用花 $99。

---

## 前置清单
- [ ] 能上网的电脑（Windows）
- [ ] 一个邮箱（注册 GitHub 用）
- [ ] 手机（收验证码 / 两步验证）
- [ ] iPad Pro 2025 M5（装 App、验 LiDAR，已在手）

---

## 第 1 步：创建 GitHub 账户

1. 打开 https://github.com → 点右上角 **Sign up**（注册）。
2. 填 **Email / Password / Username** → 完成拼图验证 → **Create account**。
3. 去邮箱点验证链接（**Verify email**）。
4. 开启两步验证（2FA，现在强制）：登录后按提示用验证器 App 或短信绑定。
5. 生成 Personal Access Token（push 代码要用，GitHub 不允许用密码）：
   - 头像 → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**。
   - **Generate new token (classic)** → Note 填 `weld-ipad` → 勾选 **repo**（全部）**＋ workflow（推送 `.github/workflows/*.yml` 工作流文件必需，否则 push 会被拒）** → **Generate token**。
   - **立刻复制** `ghp_...` 那串令牌（页面关闭后看不到第二次，存好）。

## 第 2 步：新建仓库

1. 右上角 **＋ → New repository**。
2. Repository name 填 `weld-fatigue-checker`（随意）。
3. 选 **Public**（免费 macOS 额度最宽裕）或 Private 均可。
4. **不要**勾 "Add a README" → **Create repository**。

## 第 3 步：把工程推到 GitHub

在本机（装了 Git for Windows）打开终端，进入工程目录：

```bash
cd "D:/workbuddy/workbuddy学习/weld_fatigue_checker"
git init
git add .
git commit -m "init: weld fatigue checker"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

- push 要密码时，**粘第 1 步的 token**（不是账号密码）。
- 若提示凭据错误，可把 token 写进地址再 push：
  ```bash
  git remote set-url origin https://<你的用户名>:<TOKEN>@github.com/<你的用户名>/<仓库名>.git
  git push -u origin main
  ```
- 工程里已含 `.github/workflows/build_ipa_sideload.yml` 与 `.gitignore`，会一起上传。

## 第 4 步：触发云端编译

- **自动**：上一步 `git push` 完，GitHub 自动对 `main` 触发工作流 `Build unsigned IPA (Sideloadly)`。
- **手动**：仓库 → **Actions** → 左侧该工作流 → 右上 **Run workflow** → 选 `main` → **Run workflow**。

## 第 5 步：等编译 + 下载 IPA

1. **Actions** 页看那次运行：黄圈 → 绿 ✅（约 **5–15 分钟**）。
   - 点进去看日志，应出现：`✅ 未签名 IPA 已生成：build/WeldFatigueChecker-unsigned.ipa`。
2. 运行页底部 **Artifacts** → 点 `WeldFatigueChecker-unsigned` 下载（zip，解压得 `.ipa`）。
   - 这是**未签名** IPA，需下一步在 Windows 上签名。

## 第 6 步：装到 iPad（下一步）

1. Windows 装 **Sideloadly**（https://sideloadly.io ，需 iTunes/Apple Devices 驱动）。
2. iPad 用数据线连 Windows → 弹窗点「信任」→ 在 iPad 上输密码确认。
3. Sideloadly：选该 IPA + 填免费 Apple ID（用**应用专用密码**）→ **Start**（自动注册 UDID 并签名安装）。
4. iPad：设置 → 通用 → VPN与设备管理 → 信任该账号 → 打开 App，进「📡 LiDAR」量真机 mm。
5. 7 天续签：装 **SideStore** 可无线续，不必每次连电脑。

> 安装/续签/排错的完整细节见 `app_ios/native/BUILD_SIDELOAD.md`。

---

## 常见问题

- **push 被拒 / 要密码**：用 token，不是账号密码；或走"token 写进地址"方式。
- **Actions 没自动跑**：确认默认分支是 `main`（或 `master`，工作流两者都触发）；也可手动 Run workflow。
- **构建失败**：看 Actions 日志；Xcode 版本问题工作流已用 `xcode-select` 兜底。
- **额度用尽**：GitHub Free 每月有 CI 分钟，macOS 折算较快；偶尔构建够用，耗尽等次月或把仓库设 Public。

## 这套链路用到的文件（已备好）
- `.github/workflows/build_ipa_sideload.yml` — 云端编未签名 IPA 并上传 Artifact
- `app_ios/native/build.sh`（`ipa` 目标）— `CODE_SIGNING_ALLOWED=NO` 编未签名包
- `app_ios/native/BUILD_SIDELOAD.md` — Sideloadly 安装/续签/排错详解
- `.gitignore` — 排除 build/ 等产物
