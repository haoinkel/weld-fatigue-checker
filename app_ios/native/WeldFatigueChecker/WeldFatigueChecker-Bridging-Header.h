// WeldFatigueChecker-Bridging-Header.h
// 连接 Swift 与 Objective-C/C++ 代码的桥接头。
// 这里仅暴露 OCCT 网格读取的 C 接口；Swift 侧即可直接调用 occt_read_step / occt_read_iges / occt_free_mesh。
#import "Model3D/occt_bridge.h"
