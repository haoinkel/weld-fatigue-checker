"""
视觉输入适配层：把一张焊缝照片转换成结构化 JSON（供 fatigue 引擎消费）。
生产环境实现：
  - iPad 原生：Core ML 模型（joint classifier + YOLO 缺陷检测），用 Vision 框架推理；
    几何尺寸由 LiDAR/ARKit 直接测得真实距离（无需参照物）。
  - 云端/桌面：多模态大模型（视觉大模型）看图输出同构 JSON。
本文件提供 (1) JSON Schema 文档 (2) 占位实现 (3) 从 JSON 文件载入输入的接口，
方便在没有训练好模型时先跑通整条流水线。
"""
import json
import os

# 视觉模型应输出（或人工在 UI 中确认）的 JSON Schema
VISION_SCHEMA = {
    "joint_type": "fillet | butt | t_joint | corner | lap",
    "loading_direction": "transverse | longitudinal | unknown",
    "load_carrying": "bool（荷载是否通过焊缝传递，十字接头=true）",
    "geometry": {
        "plate_thickness_mm": "float | null（可由 LiDAR/用户输入获得）",
        "weld_size_mm": "float | null（焊脚尺寸）"
    },
    "detail_candidate": "EN1993-1-9 细节 id，如 W_FILLET_TRANS_NLC",
    "surface_quality_level": "B | C | D | unknown",
    "imperfections": [
        {"type": "undercut", "size_mm": 0.4, "location": "toe"},
        {"type": "porosity", "pore_mm": 0.8}
    ],
    "improvements_applied": ["toe_grinding"],
    "confidence": 0.0
}


class VisionAdapter:
    """占位适配层。替换 analyze() 内部为实现（Core ML / 视觉大模型）。"""

    def analyze(self, image_path):
        """
        输入图片路径，返回 VISION_SCHEMA 结构的 dict。
        占位实现返回 None，调用方应改用 from_json() 提供输入，或接入真实模型。
        """
        raise NotImplementedError(
            "请接入真实识别模型（Core ML / 视觉大模型）。"
            "在模型就绪前，用 VisionAdapter.from_json() 载入人工/预标注输入。"
        )

    @staticmethod
    def from_json(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)


def demo_input():
    """一个示例视觉输入（模拟模型输出），用于演示整条流水线。"""
    return {
        "joint_type": "fillet",
        "loading_direction": "transverse",
        "load_carrying": False,
        "geometry": {"plate_thickness_mm": 12, "weld_size_mm": 8},
        "detail_candidate": "W_FILLET_TRANS_NLC",
        "surface_quality_level": "C",
        "imperfections": [
            {"type": "undercut", "size_mm": 0.4, "location": "toe"},
            {"type": "porosity", "pore_mm": 0.8}
        ],
        "improvements_applied": [],
        "confidence": 0.9,
    }


if __name__ == "__main__":
    print(json.dumps(VISION_SCHEMA, ensure_ascii=False, indent=2))
