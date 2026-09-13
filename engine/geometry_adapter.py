"""
3D 摄取适配层（可插拔）：把三种 3D 来源归一化为统一的 design_input (见 design_review.DESIGN_SCHEMA)
  - ObjIngestor   : 解析 OBJ 网格，自动算板厚/附件长度等几何尺寸（现已可跑）
  - IfcStepIngestor: 解析 IFC/STEP 真实模型（需 IfcOpenShell / pythonOCC，提供集成点）
  - RenderIngestor : 把 CAD 渲染图当图像，复用视觉模型识别接头（同照片通道）
  - LidarIngestor  : iPad Pro M4 LiDAR 扫描的建成焊缝网格（设备端，提供接口）

所有后端都产出 design_input，交给 design_review.combined_assessment 与照片通道合并校核。
"""
import json
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from engine import design_review


def _read_obj_vertices(path):
    """读取 OBJ，按组(g)收集顶点索引，返回 {group: [ (x,y,z), ... ]} 与全局顶点。"""
    vertices = []
    groups = {}
    cur = None
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if line.startswith("v "):
                _, x, y, z = line.split()
                pt = (float(x), float(y), float(z))
                vertices.append(pt)
                groups.setdefault(cur or "default", []).append(pt)
            elif line.startswith("g "):
                cur = line[2:].strip() or "default"
                groups.setdefault(cur, [])
            elif line.startswith("f "):
                idxs = [int(t.split("/")[0]) for t in line[2:].split()]
                for i in idxs:
                    if 1 <= i <= len(vertices):
                        groups.setdefault(cur or "default", []).append(vertices[i - 1])
    return groups


def obj_to_geometry(path):
    """OBJ -> 各部件包围盒尺寸。返回 {group: {size:[dx,dy,dz], thickness_guess}}。"""
    groups = _read_obj_vertices(path)
    out = {}
    for g, pts in groups.items():
        if not pts:
            continue
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]; zs = [p[2] for p in pts]
        dx, dy, dz = max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)
        out[g] = {"size": [round(dx, 2), round(dy, 2), round(dz, 2)],
                  "thickness_guess": round(min(dx, dy, dz), 2)}
    return out


class DesignIngestor:
    """基类：ingest -> design_input (dict)。"""

    def ingest(self, source, meta=None):
        raise NotImplementedError


class ObjIngestor(DesignIngestor):
    """解析 OBJ：用几何算板厚/附件长，joint_type 等由 meta 提供（UI 让用户确认）。"""

    def ingest(self, source, meta=None):
        geo = obj_to_geometry(source)
        meta = meta or {}
        # 取最小板厚作为 plate_thickness；取最大水平尺寸作为 attachment_length 估计
        thicknesses = [v["thickness_guess"] for v in geo.values() if v["thickness_guess"] > 0]
        plate_t = min(thicknesses) if thicknesses else meta.get("plate_thickness_mm", 0)
        max_ext = max((max(v["size"]) for v in geo.values()), default=0)
        design = {
            "source": f"OBJ:{os.path.basename(source)}",
            "joint_type": meta.get("joint_type"),
            "weld_type": meta.get("weld_type", "fillet"),
            "loading_direction": meta.get("loading_direction"),
            "load_carrying": meta.get("load_carrying", False),
            "full_penetration": meta.get("full_penetration", False),
            "ground_flush": meta.get("ground_flush", False),
            "attachment_length_mm": meta.get("attachment_length_mm", round(max_ext, 1)),
            "plate_thickness_mm": meta.get("plate_thickness_mm", round(plate_t, 1)),
            "cope_hole": meta.get("cope_hole", False),
            "in_tension_zone": meta.get("in_tension_zone", False),
            "_geometry": geo,
        }
        return design


class IfcStepIngestor(DesignIngestor):
    """
    IFC / STEP 真实模型解析（接口占位）。
    生产实现依赖：
      - IFC: IfcOpenShell (pip install ifcopenshell) 读取构件几何与连接关系
      - STEP: pythonOCC / OCC 读取 B-rep，提取板厚、焊缝位置、传力链
    解析后填充 design_input 的几何字段；joint_type 可由构件拓扑推断或用户确认。
    """

    def ingest(self, source, meta=None):
        raise NotImplementedError(
            "IFC/STEP 解析需集成 IfcOpenShell / pythonOCC（见代码注释）。"
            "当前可用 ObjIngestor 验证几何解析流程，或用 RenderIngestor 走图像识别。"
        )


class RenderIngestor(DesignIngestor):
    """CAD 渲染图/截图 -> 复用视觉模型识别接头（与照片通道同源）。"""

    def __init__(self, vision_analyze):
        self.vision_analyze = vision_analyze  # 同 vision_adapter.VisionAdapter.analyze

    def ingest(self, source, meta=None):
        vi = self.vision_analyze(source)  # 返回 vision_input 结构
        # 把视觉识别的接头属性映射到 design_input
        return {
            "source": f"RENDER:{os.path.basename(source)}",
            "joint_type": vi.get("joint_type"),
            "weld_type": "butt" if vi.get("joint_type") == "butt" else "fillet",
            "loading_direction": vi.get("loading_direction"),
            "load_carrying": vi.get("load_carrying", False),
            "full_penetration": None,
            "ground_flush": False,
            "attachment_length_mm": (vi.get("geometry") or {}).get("weld_size_mm"),
            "plate_thickness_mm": (vi.get("geometry") or {}).get("plate_thickness_mm", 0),
            "cope_hole": None,
            "in_tension_zone": None,
        }


class LidarIngestor(DesignIngestor):
    """
    iPad Pro M4 LiDAR 扫描的建成焊缝网格（设备端接口占位）。
    生产实现：ARKit/RealityKit 在端上生成 .usdz/.obj 网格 -> 传回本适配层解析，
    与设计 3D 做偏差/几何比对。此处仅定义接口。
    """

    def ingest(self, source, meta=None):
        raise NotImplementedError("LiDAR 扫描网格在 iPad 端由 ARKit 生成，再走 ObjIngestor 解析。")


if __name__ == "__main__":
    import sys as _sys
    if len(_sys.argv) > 1:
        print(json.dumps(obj_to_geometry(_sys.argv[1]), ensure_ascii=False, indent=2))
