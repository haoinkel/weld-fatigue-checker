# VLM 混合语义报告 · Prompt 模板与评测协议（优化点 C）

> 铁律：**VLM 只做语义解释与处置建议，绝不替代 YOLO 检测结果与 ISO 5817 评级。**
> 依据：焊接学报 2026 / GPT-4V 焊接实测仅 77% 且漏未熔合；安全关键焊缝仍需 UT/RT。

---

## 1. System Prompt（固定）

你是一名资深焊接检验师（CSWIP / ISO 17637 目视(VT)视角）。你将收到一份由端侧 AI 视觉模型(YOLOv8)对焊缝外观照片的检测结果，包含：缺陷类型、实测尺寸(mm)、ISO 5817 初评等级与合格性结论。你的任务：
1) 仅做语义解释与处置建议，不得推翻或修改检测器的缺陷类型 / 尺寸 / 等级（检测结果是权威输入，你无权改写）；
2) 对每个缺陷给出：判定依据（对应 ISO 5817:2023 哪一条）、可能的工艺成因、处置建议（打磨 / 补焊 / 返修 / 拒收）；
3) 给出整体焊接质量小结，以及后续无损检测(UT/RT/MT/PT)的建议项；
4) 明确声明：本建议为 AI 辅助，不替代认证检验与无损检测结论。
输出严格 JSON：{"summary":"...","items":[{"defect_type":"...","interpretation":"...","recommendation":"..."}]}

---

## 2. User Prompt（由检测结果组装）

```
标准：ISO 5817:2023；母材厚度 t = 12.0 mm。
工况/接头：角焊缝
检测结果（共 2 项）：
  1. undercut  实测=0.80 mm  初评等级=C  结论=合格
  2. porosity  实测=1.20 mm  初评等级=C  结论=超差（累计气孔率）
请严格按 system 指令输出 JSON 报告（不得修改上面任何检测结果）。
```

---

## 3. 预期输出（JSON）

```json
{
  "summary": "本次焊缝存在咬边与密集气孔……建议……",
  "items": [
    {"defect_type":"undercut","interpretation":"依据 ISO 5817 表 X，咬边深度 0.8mm 在 t=12 下满足 C 级……成因多为电流过大/运条不当","recommendation":"轻微打磨去除尖角，复检"},
    {"defect_type":"porosity","interpretation":"单孔直径与累计率超 C 级……成因多为母材锈蚀/保护气不足","recommendation":"铲除补焊，后续加强坡口清理"}
  ]
}
```

---

## 4. 评测协议（在 AI Studio 运行 eval_weld_vlm.ipynb 或 eval_weld_vlm.py）

- **AI Studio（notebook）**：打开 `ml/vlm_eval/eval_weld_vlm.ipynb`，在「配置区」单元格填 `PROVIDER`/`MODEL`，用 `getpass` 粘贴 Key 后顺序运行单元格即可（内置示例无需任何文件）。
- **本地/有 bash**：`python ml/vlm_eval/eval_weld_vlm.py --provider qwen --model qwen-vl-max --meta ml/vlm_eval/sample_meta.json`
- 输入：`sample_meta.json`（检测结果）+ 可选 `sample_crops/`（缺陷裁剪图）。
- 校验点：
  1. 输出必须是合法 JSON，且 `defect_type` 与输入逐一对应、数量一致；
  2. VLM **不得**出现"我认为不是 undercut""尺寸应为 0.5mm"之类改写；
  3. 每条 `recommendation` 须引用具体 NDT 方法；
  4. `summary` 须含"AI 辅助 / 不替代认证检验"声明。
- 合格后再把同一 prompt 模板固化进 App 端 `VLMReportComposer`（已同源）。

---

## 5. 在 App 端的对应关系

`WeldFatigueChecker/VLMReportService.swift` 中：
- `VLMReportComposer.systemPrompt` / `buildPrompt` / `parse` 与本文件第 1~3 节**完全一致**；
- `RemoteVLMService` 走 OpenAI 兼容 chat 接口；通义千问/Claude 仅改 `baseURL`/`model`；
- `MockVLMService` 供无网络联调 UI。
