// MetricSizer.swift
// 优化点 B：缺陷公制尺寸（毫米）计算。
//
// 两种来源：
//  1) 基于标定尺度 pxPerMm（LiDAR 标定 / 点测标定 / 参照物标定，已在 Store.applyPhotoScale 使用）。
//  2) 基于 ARKit 深度图 + 相机内参的针孔反投影（不依赖全局标定，逐缺陷更准）。
//
// 深度图由 ARKit 提供，单位已是米（Float32），故"公制"在此是直接的几何换算，
// 不是估计。与 WeldProfileAnalyzer（1D 深度剖面几何量）互补：本模块处理"照片 2D 框 → mm"。
//
// 说明：本环境无 Mac，无法编译验证；所有读深度/反投影均做空值守卫，失败返回 nil，
//       上层据此回退到 pxPerMm 标定或"未标定"显示，绝不让 App 崩溃。

import Foundation
import CoreVideo
import simd
import UIKit

/// 缺陷公制尺寸（毫米）
struct DefectMetric {
    let lengthMm: Double   // 长边（沿焊缝方向 / 横向）
    let widthMm: Double    // 垂直方向（进图纵向，余高维度方向）
    let standoffM: Double  // 缺陷到相机的距离（米，来自深度采样）
    let method: Method

    enum Method: String {
        case scaleBased     // 依赖全局 pxPerMm 标定
        case depthBased     // 逐缺陷深度反投影（更准）
    }

    /// 取用于 ISO 5817 评级的主尺寸（mm）：余高/焊瘤类取 widthMm（纵向-进图），其余取长边
    func primaryMm(type: String) -> Double {
        if type == "overlap" || type == "excess_weld_metal" || type == "excessive_convexity" {
            return widthMm
        }
        return max(lengthMm, widthMm)
    }
}

enum MetricSizer {

    // MARK: - 1) 标定尺度换算（已有路径的统一封装）

    /// 由像素尺寸 + 标定尺度（pxPerMm）得公制尺寸。
    static func fromScale(pixelSize: CGSize, pxPerMm: Double) -> DefectMetric? {
        guard pxPerMm > 0 else { return nil }
        return DefectMetric(
            lengthMm: Double(pixelSize.width) / pxPerMm,
            widthMm:  Double(pixelSize.height) / pxPerMm,
            standoffM: 0,
            method: .scaleBased)
    }

    // MARK: - 2) 深度反投影（逐缺陷，无需全局标定）

    /// 用 ARKit 深度图（米）+ 相机内参做针孔反投影，得到缺陷真实 mm 尺寸。
    /// - rect: 归一化框 0..1（原点左上，与检测器输出一致）
    /// - depth: 深度图 CVPixelBuffer（Float32 米；Disparity/Float16 也能读）
    /// - intrinsics: frame.camera.intrinsics（matrix_float3x3，ARKit 约定 fx=[0][0], fy=[1][1], cx=[2][0], cy=[2][1]）
    /// 返回 nil 表示深度缺失/读取失败（上层回退）。
    static func fromDepth(rect: CGRect, depth: CVPixelBuffer, intrinsics: matrix_float3x3) -> DefectMetric? {
        guard let dM = depthMeters(at: CGPoint(x: rect.midX, y: rect.midY), in: depth),
              dM > 0, dM.isFinite else { return nil }

        let fx = Double(intrinsics.columns.0.x)
        let fy = Double(intrinsics.columns.1.y)
        let cx = Double(intrinsics.columns.2.x)
        let cy = Double(intrinsics.columns.2.y)
        guard fx > 0, fy > 0 else { return nil }

        let W = Double(CVPixelBufferGetWidth(depth))
        let H = Double(CVPixelBufferGetHeight(depth))

        // 框四角（像素，原点左上、y 向下）→ 相机空间（y 向上）反投影，统一用中心深度 dM
        let uL = rect.minX * W, uR = rect.maxX * W
        let vT = rect.minY * H, vB = rect.maxY * H
        let dxL = (uL - cx) / fx * dM
        let dxR = (uR - cx) / fx * dM
        let dyT = -(vT - cy) / fy * dM
        let dyB = -(vB - cy) / fy * dM

        let lengthMm = abs(dxR - dxL) * 1000.0
        let widthMm  = abs(dyB - dyT) * 1000.0
        return DefectMetric(lengthMm: lengthMm, widthMm: widthMm, standoffM: dM, method: .depthBased)
    }

    /// 读取深度图某归一化点的深度（米）。支持 Float32 / Float16 深度与视差格式。
    static func depthMeters(at point: CGPoint, in depth: CVPixelBuffer) -> Double? {
        let W = CVPixelBufferGetWidth(depth)
        let H = CVPixelBufferGetHeight(depth)
        guard W > 0, H > 0 else { return nil }
        let x = min(max(Int(point.x * Double(W)), 0), W - 1)
        let y = min(max(Int(point.y * Double(H)), 0), H - 1)
        let fmt = CVPixelBufferGetPixelFormatType(depth)
        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)

        switch fmt {
        case kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            let ptr = base.assumingMemoryBound(to: Float32.self)
            let fpr = rowBytes / MemoryLayout<Float32>.stride
            let v = ptr[y * fpr + x]
            return v.isFinite ? Double(v) : nil
        case kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            let spr = rowBytes / MemoryLayout<UInt16>.stride
            let v = Float16(bitPattern: ptr[y * spr + x])
            return v.isFinite ? Double(v) : nil
        default:
            return nil
        }
    }
}

// MARK: - CVPixelBuffer(彩色) → UIImage 辅助（供 LiDAR 帧融合彩色检测用）

extension UIImage {
    /// 从 ARKit 相机帧的彩色 CVPixelBuffer 生成 UIImage（竖屏绘制，最大边 ≤720 提速）。
    /// 失败返回 nil（上层跳过融合，不影响既有 LiDAR 候选）。
    static func fromPixelBuffer(_ pb: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        let w = ci.extent.width, h = ci.extent.height
        guard w > 0, h > 0 else { return nil }
        let maxDim: CGFloat = 720
        let scale = min(1.0, maxDim / max(w, h))
        let tw = w * scale, th = h * scale
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tw, height: th))
        return renderer.image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: tw, height: th))
        }
    }
}
