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
#include <cmath>
#include <vector>

#if USE_OCCT
#include <TopoDS_Shape.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS_Face.hxx>
#include <TopLoc_Location.hxx>
#include <BRep_Tool.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_Array1OfTriangle.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <STEPControl_Reader.hxx>
#include <IGESControl_Reader.hxx>
#include <IFSelect_Reader.hxx>
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

            const TColgp_Array1OfPnt&   nodes = tri->Nodes();
            const Poly_Array1OfTriangle& tris = tri->Triangles();
            gp_Trsf trf = loc.Transformation();

            const int base = static_cast<int>(positions.size() / 3);
            const int nNodes = nodes.Length();
            for (int i = 1; i <= nNodes; ++i) {
                gp_Pnt p = nodes.Value(i).Transformed(trf);
                positions.push_back(static_cast<float>(p.X()));
                positions.push_back(static_cast<float>(p.Y()));
                positions.push_back(static_cast<float>(p.Z()));
                normals.push_back(0.f); normals.push_back(0.f); normals.push_back(0.f);
            }
            const int nTris = tris.Length();
            for (int i = 1; i <= nTris; ++i) {
                Poly_Triangle t = tris.Value(i);
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
}

OCCTMesh* occt_read_step(const char* path) {
#if USE_OCCT
    if (!path) return nullptr;
    STEPControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) return nullptr;
    reader.TransferRoots();
    TopoDS_Shape shape = reader.OneShape();
    if (shape.IsNull()) return nullptr;
    return buildMesh(shape);
#else
    (void)path;
    return nullptr;
#endif
}

OCCTMesh* occt_read_iges(const char* path) {
#if USE_OCCT
    if (!path) return nullptr;
    IGESControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) return nullptr;
    reader.TransferRoots();
    TopoDS_Shape shape = reader.OneShape();
    if (shape.IsNull()) return nullptr;
    return buildMesh(shape);
#else
    (void)path;
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
