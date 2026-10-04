// ImagePreprocessor.swift
// 优化点 A（论文依据：Atlantis ICAE-2025 CLAHE+YOLOv8 船厂非均匀光照；Springer 2025 HAN-YOLO）：
// 「灰度世界白平衡 + CLAHE 局部对比增强」，原用于改善现场光照不均下的召回。
// ⚠️ 2026-10-04 真机判定：训练集预处理不含 CLAHE，推理时叠加构成域偏移，
// 反而诱发满图气孔误报并压掉未熔合（详见 isEnabled 注释）——默认关闭。
//
// 实现约束（本机无 Mac，无法编译验证，以 CI/真机为唯一判据）：
//  - 纯 CoreGraphics + 标准 Swift 数组操作，不引入 Accelerate/vImage（规避 vImage_Buffer 等结构在
//    未知 SDK 下的编译风险）。
//  - 任何异常返回 nil，MLDefectDetector 自动回退原图，绝不让 App 崩溃。
//  - 处理对象为 ROI 裁剪后的小图（≤640px 边），逐像素开销可忽略（通常 < 数 ms）。

import Foundation
import UIKit
import CoreGraphics

struct ImagePreprocessor {
    /// 总开关（默认关闭）。关闭时 enhance 直接返回 nil（走原图）。
    /// 2026-10-04 真机实验判定：训练集预处理不含 CLAHE，推理时叠加构成训练/推理域偏移——
    /// CLAHE 把低纹理图的颗粒噪声增强成满图散斑，恰与"气孔"形态特征吻合，导致任意图
    /// ≥16 处气孔误报（标准档 0.45 阈值都挡不住），并压掉正确的未熔合检出
    /// （同图无 CLAHE 时 ONNX 未熔合 0.771 健康）。关闭后推理输入与训练分布对齐。
    /// 保留实现：现场光照不均场景可经 UI 开关重开，但重开前应先用带 CLAHE 增广的数据微调模型。
    static var isEnabled: Bool = false
    /// CLAHE 裁剪限：tile 内直方图超过 (clipLimit × tilePixels/256) 的部分被裁剪并重分配。
    /// 越大对比越强、噪声越易被放大。建议 1.5~4.0，现场强反光可降到 ~1.5。
    static var clipLimit: Double = 2.0
    /// 分块数（横向 × 纵向），8 → 8×8 自适应均衡
    static var tiles: Int = 8

    /// 对 CGImage 做 白平衡 + CLAHE，返回增强后的 CGImage；关闭或异常时返回 nil（调用方用原图）。
    static func enhance(_ cg: CGImage) -> CGImage? {
        guard isEnabled else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, w < 4096, h < 4096 else { return nil }

        // 1) 取 RGBA 字节（设备 RGB；照片 alpha=255，premultipliedLast 等价于直存）
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let src = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress!, src, w * h * 4)
        }

        // 2) 灰度世界白平衡（消除色偏）
        whiteBalance(&px, count: w * h)

        // 3) 亮度 Y：白平衡后计算 → CLAHE 增强 → 按 Y 比例回投 RGB（保色相）
        var yOld = [UInt8](repeating: 0, count: w * h)
        for i in 0 ..< w * h {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            yOld[i] = UInt8(min(255, max(0, Int(0.299 * r + 0.587 * g + 0.114 * b))))
        }
        var yNew = yOld
        clahe(&yNew, w: w, h: h, tiles: max(2, tiles), clip: clipLimit)
        for i in 0 ..< w * h {
            let old = max(Double(yOld[i]), 1.0)
            let scale = Double(yNew[i]) / old
            px[i * 4]     = sat(Double(px[i * 4])     * scale)
            px[i * 4 + 1] = sat(Double(px[i * 4 + 1]) * scale)
            px[i * 4 + 2] = sat(Double(px[i * 4 + 2]) * scale)
        }

        // 4) 回写
        guard let outCtx = CGContext(data: &px, width: w, height: h,
                                     bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: cs,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return outCtx.makeImage()
    }

    // MARK: - 内部

    private static func sat(_ v: Double) -> UInt8 {
        return UInt8(min(255, max(0, Int(v.rounded()))))
    }

    /// 灰度世界白平衡：把各通道均值拉到全局均值，消除色偏
    private static func whiteBalance(_ px: inout [UInt8], count n: Int) {
        guard n > 0 else { return }
        var sR = 0.0, sG = 0.0, sB = 0.0
        for i in 0 ..< n {
            sR += Double(px[i * 4])
            sG += Double(px[i * 4 + 1])
            sB += Double(px[i * 4 + 2])
        }
        let aR = sR / Double(n), aG = sG / Double(n), aB = sB / Double(n)
        guard aR > 1e-3, aG > 1e-3, aB > 1e-3 else { return }
        let m = (aR + aG + aB) / 3.0
        let gR = m / aR, gG = m / aG, gB = m / aB
        for i in 0 ..< n {
            px[i * 4]     = sat(Double(px[i * 4])     * gR)
            px[i * 4 + 1] = sat(Double(px[i * 4 + 1]) * gG)
            px[i * 4 + 2] = sat(Double(px[i * 4 + 2]) * gB)
        }
    }

    /// 分块限制对比自适应直方图均衡（CLAHE），就地增强 y
    private static func clahe(_ y: inout [UInt8], w: Int, h: Int, tiles: Int, clip: Double) {
        let tx = max(2, tiles), ty = max(2, tiles)
        let tileW = max(1, w / tx), tileH = max(1, h / ty)
        // 每块 LUT[256]
        var lut = [[[UInt8]]](repeating: [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: tx), count: ty)
        for tyi in 0 ..< ty {
            for txi in 0 ..< tx {
                let x0 = txi * tileW, y0 = tyi * tileH
                let x1 = (txi == tx - 1) ? w : x0 + tileW
                let y1 = (tyi == ty - 1) ? h : y0 + tileH
                var hist = [Int](repeating: 0, count: 256)
                for yy in y0 ..< y1 {
                    let base = yy * w
                    for xx in x0 ..< x1 {
                        hist[Int(y[base + xx])] += 1
                    }
                }
                let pixels = max(1, (x1 - x0) * (y1 - y0))
                let limit = max(Int(clip * Double(pixels) / 256.0), 1)
                var clipped = 0
                for i in 0 ..< 256 { if hist[i] > limit { clipped += hist[i] - limit; hist[i] = limit } }
                let redist = clipped / 256
                for i in 0 ..< 256 { hist[i] += redist }
                // CDF
                var cdf = [Int](repeating: 0, count: 256)
                cdf[0] = hist[0]
                for i in 1 ..< 256 { cdf[i] = cdf[i - 1] + hist[i] }
                let cdfMin = cdf.first(where: { $0 > 0 }) ?? 0
                let denom = max(cdf[255] - cdfMin, 1)
                for i in 0 ..< 256 {
                    let v = (Double(cdf[i] - cdfMin) / Double(denom)) * 255.0
                    lut[tyi][txi][i] = UInt8(min(255, max(0, Int(v.rounded()))))
                }
            }
        }
        // 双线性插值（tile 中心位于 (t+0.5)*tileSize）
        var out = [UInt8](repeating: 0, count: w * h)
        for yy in 0 ..< h {
            let fy = Double(yy) / Double(tileH) - 0.5
            let ty0 = min(max(Int(fy.rounded()), 0), ty - 1)
            let ty1 = min(ty0 + 1, ty - 1)
            let wy = fy - Double(ty0)
            for xx in 0 ..< w {
                let fx = Double(xx) / Double(tileW) - 0.5
                let tx0 = min(max(Int(fx.rounded()), 0), tx - 1)
                let tx1 = min(tx0 + 1, tx - 1)
                let wx = fx - Double(tx0)
                let v = Int(y[yy * w + xx])
                let top = Double(lut[ty0][tx0][v]) * (1 - wx) + Double(lut[ty0][tx1][v]) * wx
                let bot = Double(lut[ty1][tx0][v]) * (1 - wx) + Double(lut[ty1][tx1][v]) * wx
                var val = top * (1 - wy) + bot * wy
                out[yy * w + xx] = UInt8(min(255, max(0, Int(val.rounded()))))
            }
        }
        y = out
    }
}
