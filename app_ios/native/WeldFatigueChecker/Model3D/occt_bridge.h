// occt_bridge.h
// 原生 App 直读 STEP/IGES 的 C 接口（Swift 经 Bridging Header 调用）。
// 该头文件不依赖 OCCT，未启用 USE_OCCT 时整套返回 NULL（应用仍可编译运行，STEP 功能提示未启用）。
#ifndef OCCT_BRIDGE_H
#define OCCT_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 单个三维顶点（与模型单位一致，通常为 mm）
typedef struct { float x, y, z; } OCCTVec3f;

// 三角网格：位置 + 逐顶点法线 + 三角形索引（每 3 个索引为一个三角形）
typedef struct {
    OCCTVec3f* positions;
    OCCTVec3f* normals;
    int32_t*   indices;
    int32_t    vertexCount;
    int32_t    indexCount;
} OCCTMesh;

// 读取 STEP (.step/.stp)。成功返回网格，失败/未启用返回 NULL。调用方须用 occt_free_mesh 释放。
OCCTMesh* occt_read_step(const char* path);

// 读取 IGES (.iges/.igs)。成功返回网格，失败/未启用返回 NULL。
OCCTMesh* occt_read_iges(const char* path);

// 释放 occt_read_* 返回的网格（positions/normals/indices 一并释放）。
void occt_free_mesh(OCCTMesh* mesh);

// 返回上一次 occt_read_* 调用失败的具体原因（C 字符串，只读）。成功或首次调用返回空串。
const char* occt_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* OCCT_BRIDGE_H */
