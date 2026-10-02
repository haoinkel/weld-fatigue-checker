# 焊缝缺陷样本采集 SOP（气孔专项 + 扩展类储备）

> 目的：解决「优化点 D：缺陷类别扩展」的第一个硬阻塞——`raw_mine` 中 **porosity（气孔）专项样本为 0**；
> 同时为后续 7 类重训（solid_inclusion 夹渣 / spatter 飞溅）积累原始数据。
> 本 SOP 是**数据准备**，重训仍需下月在 AI Studio 完成（见第五节）。

---

## 0. 现状

- 视觉模型当前为 **5 类**：`porosity / crack / undercut / overlap / unfused`
  （见 `ml/yolov8n_weld.yaml`、`ml/raw_mine/classes.txt`）。
- `ml/raw_mine/` 已有 `mine_001~003`（已标 undercut 等），但 **porosity 专项样本为 0**，是最紧迫的阻塞。
- 扩展类 **solid_inclusion（夹渣）/ spatter（飞溅）** 已在 `iso5817.json` 与 `KnowledgeBank` 预留
  （`verified:false`，仅作标准库扩展占位），待重训纳入。

---

## 1. 拍摄规范（iPad Pro 2025 11" M5 相机）

- **光照**：均匀漫射光，避免强反光 / 硬阴影；户外选阴天或补光。
- **距离**：20–40 cm，使焊缝占画面 1/3 ~ 2/3。
- **角度**：每处缺陷拍「正对 + 45° 斜视」各一张（利于深度/尺寸复核）。
- **数量目标（重训前）**：
  - `porosity` 气孔：**≥200 张图 / ≥400 框**（当前 0，优先补齐）。
  - 扩展类储备：`solid_inclusion` ≥80 张、`spatter` ≥80 张（可选，为 7 类重训准备）。
- **标注质量 > 数量**：框贴边、不漏标；单图多个同类缺陷分别标。

---

## 2. 标注格式（YOLO txt，与现有 5 类一致）

`<class_id> <cx> <cy> <w> <h>`（坐标归一化 0~1）。

- **5 类**：`0 porosity` / `1 crack` / `2 undercut` / `3 overlap` / `4 unfused`
- **7 类规划（重训时）**：在 5 类后追加 `5 solid_inclusion` / `6 spatter`
  —— 见 `ml/raw_mine/classes_7cls.txt`。
- **工具**：labelImg / makesense.ai（导出 YOLO txt）；VOC xml 亦被 `weld_train.py` 的 `parse_voc` 支持。

---

## 3. 闭环到重训（参考 `数据集自增模板_5类缺陷.md`）

1. 把整理好的 `raw_mine/`（含 `images/`、`labels/`、`classes.txt`）上传 AI Studio `/home/aistudio/work/`。
2. `weld_train.py` 加 `SOURCE_NAMES['mine']` 与 `SOURCES` 两项（模板已有示例）。
3. 跑 `%run weld_train.py --fresh`；控制台确认 `[合并] mine: 保留图-标对 N` 与 `各类框数`。
4. 验收线：porosity mAP50 ≥ 0.85；crack / undercut **recall ≥ 0.9**。
5. 跑满 120 轮后脚本自动导出 `WeldDefectModel.mlpackage`（带 NMS）。
6. **7 类扩展（下一步，非本次）**：改用 `ml/yolov8n_weld_7cls.yaml`（nc:7）+ 7 类 data yaml + `classes_7cls.txt`；
   重训后**必须**同步改 `MLDefectDetector.classNames` / `labelMap` 顺序，否则 argmax 错位。
7. 下载新 mlpackage 覆盖 `app_ios/native/WeldFatigueChecker/WeldDefectModel.mlpackage/`，
   回本机 `git add` 后推送。

---

## 4. 检查清单

- [ ] `raw_mine/classes.txt` 顺序正确（5 类；7 类重训时换 `classes_7cls.txt`）
- [ ] 每个有缺陷的图都有同名 `.txt`
- [ ] class_id 用 0~4（或 7 类 0~6），且只对应合法类
- [ ] 坐标归一化到 0~1，无超界、无负数
- [ ] `weld_train.py` 已加 `mine` 源
- [ ] 运行 `--fresh` 并见合并日志 + `各类框数`
- [ ] 气孔框数达标（≥400）后再重训
