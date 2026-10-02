// occt_bridge.mm
// OpenCascade(OCCT) STEP/IGES → 三角网格 的 Objective-C++ 实现。
//
// 编译要求（在 Mac 上，由 build_occt_ios.sh 准备好 Vendor/OCCT 后开启）：
//   - 用 OCCT 7.8.x 头文件（HEADER_SEARCH_PATHS 指向 Vendor/OCCT/include）
//   - 链接合并后的静态库 libOCCT.a（OTHER_LDFLAGS = -lOCCT -lc++）
//   - 预处理器宏 USE_OCCT=1
//
// 未定义 USE_OCCT 时：本文件仅提供返回 NULL 的桩，应用可正常编译/运行，
// STEP/IGES 导入会在 UI 上提示“请先在 Mac 运行 build_occt_ios.sh”。

#import "occt_bridge.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <cmath>
#include <vector>
#include <cstdio>
#include <cfloat>
#include <cerrno>

// 记录上一次读取失败的具体原因，供 Swift 端 UI 展示（只读）
static char g_occt_err[256] = {0};
static void occt_set_err(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(g_occt_err, sizeof(g_occt_err), fmt, ap);
    va_end(ap);
}
const char* occt_last_error(void) { return g_occt_err; }

#if USE_OCCT
#include <TopoDS_Shape.hxx>
#include <TopoDS.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS_Face.hxx>
#include <TopLoc_Location.hxx>
#include <BRep_Tool.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_Triangle.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Controller.hxx>
#include <IGESControl_Reader.hxx>
#include <IGESControl_Controller.hxx>
// IFSelect_RetDone 等返回状态枚举所在头文件（OCCT 无 IFSelect_Reader.hxx）
#include <IFSelect_ReturnStatus.hxx>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <BRepGProp.hxx>
#include <GProp.hxx>
#include <GProp_GProps.hxx>   // GProp_GProps 完整定义（BRepGProp.hxx 仅前向声明）
#include <TopExp.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Edge.hxx>
#endif

namespace {
#if USE_OCCT
    // 将一个 TopoDS_Shape 网格化并返回带逐顶点法线的三角网格
    OCCTMesh* buildMesh(const TopoDS_Shape& shape) {
        // 增量网格化：线性偏差 0.5mm，相对=否，并行=是，角度偏差 0.5°
        BRepMesh_IncrementalMesh aMesher(shape, 0.5, Standard_False, Standard_True, 0.5);
        aMesher.Perform();
        if (!aMesher.IsDone()) return nullptr;

        std::vector<float>    positions;
        std::vector<float>    normals;
        std::vector<int32_t>  indices;

        for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
            const TopoDS_Face& face = TopoDS::Face(ex.Current());
            TopLoc_Location loc;
            const Handle(Poly_Triangulation)& tri = BRep_Tool::Triangulation(face, loc);
            if (tri.IsNull()) continue;

            gp_Trsf trf = loc.Transformation();
            // OCCT 8.0：Poly_Triangulation 移除了 Nodes()/Triangles() 批量访问器，改用 Node(i)/Triangle(i)
            const int base = static_cast<int>(positions.size() / 3);
            const int nNodes = tri->NbNodes();
            for (int i = 1; i <= nNodes; ++i) {
                gp_Pnt p = tri->Node(i).Transformed(trf);
                positions.push_back(static_cast<float>(p.X()));
                positions.push_back(static_cast<float>(p.Y()));
                positions.push_back(static_cast<float>(p.Z()));
                normals.push_back(0.f); normals.push_back(0.f); normals.push_back(0.f);
            }
            const int nTris = tri->NbTriangles();
            for (int i = 1; i <= nTris; ++i) {
                Poly_Triangle t = tri->Triangle(i);
                Standard_Integer n1, n2, n3;
                t.Get(n1, n2, n3);
                indices.push_back(base + static_cast<int>(n1) - 1);
                indices.push_back(base + static_cast<int>(n2) - 1);
                indices.push_back(base + static_cast<int>(n3) - 1);
            }
        }

        const int vCount = static_cast<int>(positions.size() / 3);
        const int iCount = static_cast<int>(indices.size());
        if (vCount == 0 || iCount == 0) return nullptr;

        // 按相邻面累加计算逐顶点法线
        for (size_t t = 0; t + 2 < indices.size(); t += 3) {
            int a = indices[t], b = indices[t + 1], c = indices[t + 2];
            float ax = positions[3*a], ay = positions[3*a+1], az = positions[3*a+2];
            float bx = positions[3*b], by = positions[3*b+1], bz = positions[3*b+2];
            float cx = positions[3*c], cy = positions[3*c+1], cz = positions[3*c+2];
            float ux = bx-ax, uy = by-ay, uz = bz-az;
            float vx = cx-ax, vy = cy-ay, vz = cz-az;
            float nx = uy*vz - uz*vy;
            float ny = uz*vx - ux*vz;
            float nz = ux*vy - uy*vx;
            normals[3*a] += nx; normals[3*a+1] += ny; normals[3*a+2] += nz;
            normals[3*b] += nx; normals[3*b+1] += ny; normals[3*b+2] += nz;
            normals[3*c] += nx; normals[3*c+1] += ny; normals[3*c+2] += nz;
        }
        for (int v = 0; v < vCount; ++v) {
            float nx = normals[3*v], ny = normals[3*v+1], nz = normals[3*v+2];
            float len = std::sqrt(nx*nx + ny*ny + nz*nz);
            if (len > 1e-8f) { normals[3*v] = nx/len; normals[3*v+1] = ny/len; normals[3*v+2] = nz/len; }
        }

        OCCTMesh* m = static_cast<OCCTMesh*>(std::malloc(sizeof(OCCTMesh)));
        m->vertexCount = vCount;
        m->indexCount  = iCount;
        m->positions = static_cast<OCCTVec3f*>(std::malloc(sizeof(OCCTVec3f) * vCount));
        m->normals   = static_cast<OCCTVec3f*>(std::malloc(sizeof(OCCTVec3f) * vCount));
        m->indices   = static_cast<int32_t*>(std::malloc(sizeof(int32_t) * iCount));
        std::memcpy(m->positions, positions.data(), sizeof(OCCTVec3f) * vCount);
        std::memcpy(m->normals,   normals.data(),   sizeof(OCCTVec3f) * vCount);
        std::memcpy(m->indices,   indices.data(),   sizeof(int32_t) * iCount);
        return m;
    }
#else
    OCCTMesh* buildMesh() { return nullptr; }
#endif

#if USE_OCCT
    // 从 B-rep 提取几何特征向量（供 STEP→EN1993-1-9 细部归类自动回填）
    int extractFeaturesFromShape(const TopoDS_Shape& shape, OCCTFeatures* out) {
        if (!out) return 0;
        std::memset(out, 0, sizeof(OCCTFeatures));
        out->minEdgeLen = -1.0f;   // 标记"尚未取得有效最短边"

        // 包围盒
        Bnd_Box bb;
        BRepBndLib::Add(shape, bb);
        if (!bb.IsVoid()) {
            double xmin, ymin, zmin, xmax, ymax, zmax;
            bb.Get(xmin, ymin, zmin, xmax, ymax, zmax);
            out->bboxX = static_cast<float>(xmax - xmin);
            out->bboxY = static_cast<float>(ymax - ymin);
            out->bboxZ = static_cast<float>(zmax - zmin);
        }

        int faces = 0, edges = 0, solids = 0;
        float minE = FLT_MAX, maxE = 0.0f;
        for (TopExp_Explorer ex(shape, TopAbs_SOLID); ex.More(); ex.Next()) {
            ++solids;
            const TopoDS_Solid& solid = TopoDS::Solid(ex.Current());
            if (solid.IsNull()) continue;
        }
        for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) { ++faces; }
        for (TopExp_Explorer ex(shape, TopAbs_EDGE); ex.More(); ex.Next()) {
            ++edges;
            const TopoDS_Edge& e = TopoDS::Edge(ex.Current());
            if (e.IsNull()) continue;
            GProp_GProps props;
            BRepGProp::LinearProperties(e, props);
            double L = props.Mass();
            if (L > 1e-3) {
                if (L < minE) minE = static_cast<float>(L);
                if (L > maxE) maxE = static_cast<float>(L);
            }
        }
        out->faceCount = faces;
        out->edgeCount = edges;
        out->solidCount = solids;
        out->minEdgeLen = (minE < FLT_MAX) ? minE : -1.0f;
        out->maxEdgeLen = maxE;
        return 1;
    }

    // 按扩展名选择 STEP 或 IGES 读取器，返回 OneShape
    int readOneShape(const char* path, TopoDS_Shape& outShape) {
        std::string p(path);
        bool isIGES = (p.size() >= 4 && (p.substr(p.size() - 4) == ".igs" ||
                                          p.substr(p.size() - 4) == ".IGS"));
        if (isIGES) {
            IGESControl_Controller::Init();
            IGESControl_Reader reader;
            if (reader.ReadFile(path) != IFSelect_RetDone) return 0;
            reader.TransferRoots();
            outShape = reader.OneShape();
        } else {
            STEPControl_Controller::Init();
            STEPControl_Reader reader;
            if (reader.ReadFile(path) != IFSelect_RetDone) return 0;
            reader.TransferRoots();
            outShape = reader.OneShape();
        }
        return outShape.IsNull() ? 0 : 1;
    }
#else
    int extractFeaturesFromShape() { return 0; }
#endif
}

OCCTMesh* occt_read_step(const char* path) {
#if USE_OCCT
    g_occt_err[0] = '\0';
    if (!path) { occt_set_err("路径为空"); return nullptr; }
    // 预检1：fopen 权限/存在性（沙盒权限被释放时在 fopen 一层就暴露，回传 errno）
    FILE* fp = fopen(path, "rb");
    if (!fp) {
        occt_set_err("STEP 无法打开文件(errno=%d: %s)", errno, strerror(errno));
        return nullptr;
    }
    // 预检2：STEP 文件头应为 ISO-10303-21（防止误选其他格式）
    char head[32] = {0};
    size_t nrd = fread(head, 1, 31, fp);
    fclose(fp);
    size_t off = 0;
    while (off < nrd && (head[off]==' '||head[off]=='\t'||head[off]=='\r'||head[off]=='\n')) ++off;
    if (off + 12 > nrd || strncmp(head + off, "ISO-10303-21", 12) != 0) {
        occt_set_err("文件开头不是 ISO-10303-21(可能不是 STEP 文件): \"%.31s\"", head);
        return nullptr;
    }
    STEPControl_Controller::Init();   // 注册 STEP 协议/单位；未初始化时 ReadFile 返回非 RetDone
    STEPControl_Reader reader;
    IFSelect_ReturnStatus stat = reader.ReadFile(path);
    if (stat != IFSelect_RetDone) {
        occt_set_err("STEP ReadFile 返回 %d(非 RetDone，可能是 OCCT 读取器未注册或文件无法解析)", (int)stat);
        return nullptr;
    }
    reader.TransferRoots();
    TopoDS_Shape shape = reader.OneShape();
    if (shape.IsNull()) { occt_set_err("STEP 已读取，但 OneShape 为空(文件无实体几何)"); return nullptr; }
    OCCTMesh* m = buildMesh(shape);
    if (!m) occt_set_err("STEP 几何已加载，但三角网格生成失败(无三角面)");
    return m;
#else
    (void)path;
    occt_set_err("USE_OCCT 未启用(请重新编译含 OCCT 的版本)");
    return nullptr;
#endif
}

OCCTMesh* occt_read_iges(const char* path) {
#if USE_OCCT
    g_occt_err[0] = '\0';
    if (!path) { occt_set_err("路径为空"); return nullptr; }
    // 预检：fopen 权限/存在性
    FILE* fp = fopen(path, "rb");
    if (!fp) {
        occt_set_err("IGES 无法打开文件(errno=%d: %s)", errno, strerror(errno));
        return nullptr;
    }
    fclose(fp);
    IGESControl_Controller::Init();   // 注册 IGES 协议；未初始化时 ReadFile 返回非 RetDone
    IGESControl_Reader reader;
    IFSelect_ReturnStatus stat = reader.ReadFile(path);
    if (stat != IFSelect_RetDone) {
        occt_set_err("IGES ReadFile 返回 %d(非 RetDone，可能是 OCCT 读取器未注册或文件无法解析)", (int)stat);
        return nullptr;
    }
    reader.TransferRoots();
    TopoDS_Shape shape = reader.OneShape();
    if (shape.IsNull()) { occt_set_err("IGES 已读取，但 OneShape 为空"); return nullptr; }
    OCCTMesh* m = buildMesh(shape);
    if (!m) occt_set_err("IGES 几何已加载，但三角网格生成失败(无三角面)");
    return m;
#else
    (void)path;
    occt_set_err("USE_OCCT 未启用(请重新编译含 OCCT 的版本)");
    return nullptr;
#endif
}

void occt_free_mesh(OCCTMesh* mesh) {
    if (!mesh) return;
    std::free(mesh->positions);
    std::free(mesh->normals);
    std::free(mesh->indices);
    std::free(mesh);
}

int occt_extract_features(const char* path, OCCTFeatures* out) {
#if USE_OCCT
    g_occt_err[0] = '\0';
    if (!path || !out) { occt_set_err("参数无效"); return 0; }
    // 预检：fopen 权限/存在性
    FILE* fp = fopen(path, "rb");
    if (!fp) {
        occt_set_err("文件无法打开(errno=%d: %s)", errno, strerror(errno));
        return 0;
    }
    fclose(fp);
    TopoDS_Shape shape;
    if (!readOneShape(path, shape)) {
        occt_set_err("STEP/IGES 读取失败（OCCT 读取器未注册或文件无法解析）");
        return 0;
    }
    int r = extractFeaturesFromShape(shape, out);
    if (!r) occt_set_err("几何特征提取失败");
    return r;
#else
    (void)path; (void)out;
    occt_set_err("USE_OCCT 未启用(请重新编译含 OCCT 的版本)");
    return 0;
#endif
}
