// BuildInfo.swift
// 构建版本戳：CI 构建时由 .github/workflows/build_ipa_sideload.yml 的
// "Stamp build SHA" 步骤自动覆写为真实 git 短提交号；本地默认 dev。
// 用途：真机验收时在扫描页顶栏显示 "Build xxxxxxx"，一眼判定侧载的是新包还是旧
// artifact（历史痛点：用户反复侧载到旧 run 产物，导致"修了没生效"的假象）。
// 本文件允许被 CI 覆写，不要手工维护其内容。

import Foundation

enum BuildInfo {
    static let gitSHA = "dev"
    static let buildTime = "local"
}
