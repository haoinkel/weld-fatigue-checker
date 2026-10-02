#!/usr/bin/env python3
# eval_weld_vlm.py
# 优化点 C 的 AI Studio 评测脚本：用同一套 ISO 5817 锚定 prompt 调 VLM，
# 验证其"只解释、不改写检测结果"的能力，并产出结构化报告。
#
# 依赖：pip install requests pillow
# 默认后端（硅基流动 SiliconFlow，OpenAI 兼容，按量低价，新用户送免费额度）：
#   export SILICONFLOW_API_KEY=sk-xxx
#   python ml/vlm_eval/eval_weld_vlm.py \
#       --meta ml/vlm_eval/sample_meta.json --images ml/vlm_eval/sample_crops
#   （默认 base-url=https://api.siliconflow.cn/v1/chat/completions，model=Qwen/Qwen3-VL-32B-Instruct）
#
# 备选（通义千问 DashScope，已实测专属域名报 Endpoint.AccessDenied，仅作代码保留）：
#   export DASHSCOPE_API_KEY=sk-xxx
#   python ml/vlm_eval/eval_weld_vlm.py \
#       --provider qwen --model qwen-vl-max \
#       --meta ml/vlm_eval/sample_meta.json --images ml/vlm_eval/sample_crops
#
# 备选（OpenAI 原版）：
#   export OPENAI_API_KEY=sk-xxx
#   python ml/vlm_eval/eval_weld_vlm.py \
#       --provider openai --base-url https://api.openai.com/v1/chat/completions \
#       --model gpt-4o --meta ml/vlm_eval/sample_meta.json
#
# meta JSON 格式（与 App 端 VLMSessionInput 同源）：
#   {"standard":"ISO 5817:2023","plateThicknessMm":12,"weldContext":"角焊缝",
#    "defects":[{"type":"undercut","sizeMm":0.8,"grade":"C","accepted":true}]}

import argparse
import base64
import json
import os
import sys

SYSTEM_PROMPT = """你是一名资深焊接检验师（CSWIP / ISO 17637 目视(VT)视角）。你将收到一份由端侧 AI 视觉模型(YOLOv8)对焊缝外观照片的检测结果，包含：缺陷类型、实测尺寸(mm)、ISO 5817 初评等级与合格性结论。你的任务：
1) 仅做语义解释与处置建议，不得推翻或修改检测器的缺陷类型 / 尺寸 / 等级（检测结果是权威输入，你无权改写）；
2) 对每个缺陷给出：判定依据（对应 ISO 5817:2023 哪一条）、可能的工艺成因、处置建议（打磨 / 补焊 / 返修 / 拒收）；
3) 给出整体焊接质量小结，以及后续无损检测(UT/RT/MT/PT)的建议项；即使判定为合格的缺陷项，也请给出建议的后续 NDT 复检项（如 MT/PT）；
4) 明确声明：本建议为 AI 辅助，不替代认证检验与无损检测结论。
输出严格 JSON：{"summary":"...","items":[{"defect_type":"...","interpretation":"...","recommendation":"..."}]}"""


def build_user_prompt(meta):
    lines = []
    lines.append(f"标准：{meta.get('standard','ISO 5817:2023')}；母材厚度 t = {meta.get('plateThicknessMm',12)} mm。")
    if meta.get("weldContext"):
        lines.append(f"工况/接头：{meta['weldContext']}")
    defects = meta.get("defects", [])
    lines.append(f"检测结果（共 {len(defects)} 项）：")
    for i, d in enumerate(defects, 1):
        size = f"{d['sizeMm']:.2f} mm" if d.get("sizeMm") is not None else "未测"
        g = d.get("grade", "-")
        acc = "合格" if d.get("accepted") else ("超差" if d.get("accepted") is False else "未评")
        lines.append(f"  {i}. {d['type']}  实测={size}  初评等级={g}  结论={acc}")
    lines.append("请严格按 system 指令输出 JSON 报告（不得修改上面任何检测结果）。")
    return "\n".join(lines)


def call_openai(base_url, api_key, model, prompt, images_b64):
    import requests
    content = [{"type": "text", "text": prompt}]
    for b in (images_b64 or []):
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b}"}})
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": content},
        ],
        "temperature": 0.2,
        "response_format": {"type": "json_object"},
    }
    r = requests.post(base_url, headers={"Authorization": f"Bearer {api_key}",
                                          "Content-Type": "application/json"}, json=body, timeout=60)
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


def call_qwen(api_key, model, prompt, images_b64):
    # 通义千问 DashScope 兼容 OpenAI 接口
    # ⚠️ Key 与端点必须成套：
    #  - 公共端点 Key（bailian「API-KEY 管理」页，dashscope.aliyuncs.com 用）
    #  - 「API快捷接入」弹窗给的专属端点 Key（sk-ws- 开头），必须配它弹窗里的
    #    Base Url：https://ws-xxxx.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions
    #    拿专属 Key 调公共端点会 401 invalid_api_key（端点错配，非 Key 错）。
    #    ※ 实测该专属域名在账号层报 Endpoint.AccessDenied（403），已提阿里工单。
    #      替代方案见 call_local()（本地 Qwen2.5-VL，零 Key）。
    return call_openai("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                       api_key, model, prompt, images_b64)


def load_images_b64(img_dir):
    if not img_dir or not os.path.isdir(img_dir):
        return None
    out = []
    for fn in sorted(os.listdir(img_dir)):
        if fn.lower().endswith((".jpg", ".jpeg", ".png")):
            with open(os.path.join(img_dir, fn), "rb") as f:
                out.append(base64.b64encode(f.read()).decode("utf-8"))
    return out or None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", default="openai", choices=["openai", "qwen"])
    ap.add_argument("--base-url", default="https://api.siliconflow.cn/v1/chat/completions")
    ap.add_argument("--model", default="Qwen/Qwen3-VL-32B-Instruct")
    ap.add_argument("--meta", required=True, help="检测结果 meta JSON")
    ap.add_argument("--images", default=None, help="可选：缺陷裁剪图目录(多模态)")
    args = ap.parse_args()

    with open(args.meta, "r", encoding="utf-8") as f:
        meta = json.load(f)
    prompt = build_user_prompt(meta)
    images_b64 = load_images_b64(args.images)

    if args.provider == "qwen":
        api_key = os.environ.get("DASHSCOPE_API_KEY")
        if not api_key:
            sys.exit("缺少环境变量 DASHSCOPE_API_KEY")
        content = call_qwen(api_key, args.model, prompt, images_b64)
    else:
        api_key = os.environ.get("SILICONFLOW_API_KEY") or os.environ.get("OPENAI_API_KEY")
        if not api_key:
            sys.exit("缺少环境变量 SILICONFLOW_API_KEY（或 OPENAI_API_KEY）")
        content = call_openai(args.base_url, api_key, args.model, prompt, images_b64)

    print("===== VLM 原始返回 =====")
    print(content)
    try:
        rep = json.loads(content)
        print("\n===== 解析报告 =====")
        print("summary:", rep.get("summary", ""))
        for it in rep.get("items", []):
            print(f"- {it.get('defect_type')}: {it.get('interpretation')} | 建议: {it.get('recommendation')}")
    except Exception as e:
        print("JSON 解析失败：", e)


if __name__ == "__main__":
    main()
