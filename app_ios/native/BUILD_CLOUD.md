# 云端构建并发布到 TestFlight（无需自有 Mac）

目标：在 **GitHub Actions 托管的云端 Mac** 上自动编译 `WeldFatigueChecker`，
通过 **TestFlight** 装到你的 **iPad Pro（M5，带 LiDAR）** 上。
你只需要：**Apple Developer 账号（$99/年）** + 一台带 LiDAR 的 iPad + 一个 GitHub 仓库。
**不需要购买 Mac**。

> 说明：iOS 原生 App 只能在 macOS + Xcode 编译，本方案把"那台 Mac"换成云端 runner。
> LiDAR 必须在真机验证——模拟器没有深度摄像头，所以最终一定是在你 iPad 上测。

---

## 0. 前置：把工程推到 GitHub

```bash
cd weld_fatigue_checker
git init
git add -A
git commit -m "WeldFatigueChecker 初始提交"
gh repo create weldfatiguechecker --private   # 或网页新建后关联
git branch -M main
git push -u origin main
```

> 本目录已包含：`.github/workflows/build_testflight.yml`、`app_ios/native/Gemfile`、
> `app_ios/native/fastlane/{Fastfile,Appfile}`、`app_ios/native/build.sh`、
> `app_ios/native/tools/gen_xcodeproj.py`。

---

## 1. Apple Developer 与 App Store Connect 准备

1.  enroll Apple Developer Program（https://developer.apple.com/programs/ ，约 $99/年）。
2.  App Store Connect → Users and Access → **Integrations → App Store Connect API**：
    点 **+** 生成 Key，权限选 **App Manager**（或 Admin）。记下 **Issuer ID** 与 **Key ID**，
    下载 `.p8` 文件（只此一次）。
3.  App Store Connect → **My Apps** → 新建 App：
    - Bundle ID 填 `com.yourorg.weldfatiguechecker`（必须与下面第 4 步一致）。
    - 记下你的 **Team ID**（Membership 页面可查）。

---

## 2. 证书仓库（match 用）

1.  在 GitHub 新建一个**私有**仓库，例如 `weldfatigue-certs`（空仓库即可）。
2.  生成一个有 `repo` 权限的 **Personal Access Token (PAT)**（Settings → Developer settings → PAT）。
3.  构造 `MATCH_GIT_URL`：
    ```
    https://<你的PAT>@github.com/<你的用户名>/weldfatigue-certs.git
    ```
4.  想一个 `MATCH_PASSWORD`（用于加密证书库，自己记住）。

> 首次 CI 运行 `match` 会自动创建发布证书 + 描述文件并上传到 Apple，存进该私有库，
> 之后复用。无需你本地有 Mac。

---

## 3. 在 GitHub 仓库配置 Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret，添加：

| 名称 | 值 |
|------|-----|
| `ASC_API_KEY_ID` | 第 1 步的 Key ID |
| `ASC_API_KEY_ISSUER_ID` | 第 1 步的 Issuer ID |
| `ASC_API_KEY_P8` | 第 1 步下载的 `.p8` 文件**全文内容** |
| `MATCH_GIT_URL` | 第 2 步构造的带 PAT 的 URL |
| `MATCH_PASSWORD` | 第 2 步的加密口令 |
| `TEAM_ID` | 你的 Apple Developer Team ID |

---

## 4. 统一 Bundle ID（如与上面不同）

App Store 里建的 Bundle ID 必须与工程一致。若你用了别的 ID，改两处：
- `app_ios/native/WeldFatigueChecker.xcodeproj` 中 `PRODUCT_BUNDLE_IDENTIFIER`
  （重新生成：`cd app_ios/native && python3 tools/gen_xcodeproj.py`，生成后在 Xcode 或
   用 `sed` 改 `PRODUCT_BUNDLE_IDENTIFIER`；或在 `fastlane/Appfile` 写死）。
- `app_ios/native/fastlane/Appfile` 里的 `app_identifier`。

---

## 5. 触发构建

```bash
git push origin main        # 或去 GitHub → Actions → 手动 Run workflow
```

云端 Mac 会：`gen_xcodeproj.py` → `match`(建/取证书) → `build_app`(归档) →
`upload_to_testflight`。约 5–15 分钟。完成后：

- 你的 iPad 打开 **TestFlight** App → 出现 `WeldFatigueChecker` → 安装。
- 在 iPad 上即可使用**原生 LiDAR 自动识别焊缝/缺陷并测真实 mm**。

---

## 6. 如果以后借到 Mac（可选，更快的本地验证）

```bash
cd app_ios/native
./build.sh sim            # 模拟器编译，验证能否通过（无需 Apple ID）
./build.sh archive <TEAM_ID>   # 归档 .xcarchive
# Xcode → Window → Organizer → 分发到 TestFlight / Ad Hoc
```

---

## 7. 已知限制

- **OCCT（.step/.iges 直读）默认不编**：CI 不构建 OCCT 静态库，STEP/IGES 导入会提示
  "OCCT 未启用"，其余格式与 LiDAR/标注均正常。需要 STEP 时，在 Mac 上先跑
  `./build_occt_ios.sh` 再 `archive`。
- **LiDAR 行为只能真机验证**：模拟器/CI 无法测深度，请务必在 iPad Pro(M5) 上确认。
- **免费额度**：GitHub 私有库 macOS 每月约 50 分钟、Codemagic 免费 500 分钟，单次构建
  5–15 分钟，偶发使用基本免费。
