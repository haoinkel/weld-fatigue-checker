// PhotoDefectDetector.swift
// 端侧照片缺陷区域检测（纯 Swift，无 ML 依赖）：灰度 → Sobel 边缘幅度 →
// 自适应阈值 → 4 邻域连通域 → 非极大抑制 → 逐框启发式定类型。
// 返回归一化矩形（0..1），供「自动标注」在照片上框出缺陷位置与尺寸。

import UIKit

struct DetectedDefect {
    let rect: CGRect        // 归一化 0..1（原点左上）
    let type: String
    let pixelSize: CGSize   // 原图像素空间的宽高
    var metric: DefectMetric? = nil   // 优化点 B：公制尺寸(mm)，由 MLDefectDetector.detect 反投影填充；无深度时为 nil
}

/// 按缺陷类型选取测量像素尺寸（ISO 5817 维度语义）：
/// - 余高/焊瘤类（overlap / excess_weld_metal / excessive_convexity）：限值为凸起高度 h（垂直于
///   母材表面），照片中对应「垂直图片（纵向-进图）方向」的 bbox 高，而不是沿焊缝的横向长边。
///   —— 对齐用户要求：余高维度方向 = 纵向-进图方向。
/// - 其余类型维持长边测量（气孔=直径、裂纹=长度、咬边=长度等）。
func defectMeasurePx(type: String, pixelSize: CGSize) -> Double {
    if type == "overlap" || type == "excess_weld_metal" || type == "excessive_convexity" {
        return Double(pixelSize.height)
    }
    return Double(max(pixelSize.width, pixelSize.height))
}

struct PhotoDefectDetector {
    /// 在 UIImage 上检测疑似缺陷区域；maxCount 限制返回数量。
    /// roi：焊缝区域（归一化 0..1，原点左上）；传入时只保留中心落在 roi 内的缺陷，
    ///      区域外的连通块（如非焊缝物体的高光/纹理）一律忽略，避免误报。
    static func detect(in image: UIImage, maxCount: Int = 12, roi: CGRect? = nil) -> [DetectedDefect] {
        guard let cg = image.cgImage else { return [] }
        let w = cg.width, h = cg.height
        guard w > 4, h > 4 else { return [] }

        // 直接转 8bit 灰度，便于逐像素读取
        guard let grayCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        grayCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let dataPtr = grayCtx.data else { return [] }
        let buf = dataPtr.bindMemory(to: UInt8.self, capacity: w * h)

        // 平均灰度
        var gsum = 0
        for i in 0 ..< w * h { gsum += Int(buf[i]) }
        let gmean = Double(gsum) / Double(w * h)

        // Sobel 边缘幅度
        var mag = [Float](repeating: 0, count: w * h)
        var msum = 0.0, msq = 0.0
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let i = y * w + x
                let sx = Int(buf[i - w + 1]) + 2 * Int(buf[i + 1]) + Int(buf[i + w + 1])
                        - Int(buf[i - w - 1]) - 2 * Int(buf[i - 1]) - Int(buf[i + w - 1])
                let sy = Int(buf[i + w - 1]) + 2 * Int(buf[i + w]) + Int(buf[i + w + 1])
                        - Int(buf[i - w - 1]) - 2 * Int(buf[i - w]) - Int(buf[i - w + 1])
                let m = sqrt(Float(sx * sx + sy * sy))
                mag[i] = m
                msum += Double(m); msq += Double(m) * Double(m)
            }
        }
        let mmean = msum / Double(w * h)
        let mstd = sqrt(max(0, msq / Double(w * h) - mmean * mmean))
        let thresh = Float(max(50, Int(mmean + 2.0 * mstd)))

        // 连通域（4 邻域）
        let n = w * h
        var visited = [UInt8](repeating: 0, count: n)
        var raw: [(x1: Int, y1: Int, x2: Int, y2: Int, area: Int, bw: Int, bh: Int, inMean: Double)] = []
        let minArea = max(60, n / 1600)
        let maxArea = n / 5
        for i in 0 ..< n {
            if visited[i] == 1 || mag[i] < thresh { continue }
            var stack = [i]; visited[i] = 1
            var minX = w, minY = h, maxX = 0, maxY = 0, cnt = 0, ysum = 0
            while !stack.isEmpty {
                let p = stack.removeLast(); cnt += 1
                let px = p % w, py = p / w
                ysum += Int(buf[p])
                if px < minX { minX = px }; if px > maxX { maxX = px }
                if py < minY { minY = py }; if py > maxY { maxY = py }
                let ns = [px > 0 ? p - 1 : -1, px < w - 1 ? p + 1 : -1,
                          py > 0 ? p - w : -1, py < h - 1 ? p + w : -1].filter { $0 >= 0 }
                for q in ns where visited[q] == 0 && mag[q] >= thresh {
                    visited[q] = 1; stack.append(q)
                }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1, area = bw * bh
            if cnt >= minArea && cnt <= maxArea && bw > 4 && bh > 4 {
                let inMean = Double(ysum) / Double(cnt)
                if abs(inMean - gmean) < 6 { continue }   // 与背景无亮度差，非缺陷
                raw.append((minX, minY, maxX, maxY, area, bw, bh, inMean))
            }
        }

        // 非极大抑制（IoU>0.6 视为重叠，保留面积大的）
        raw.sort { $0.area > $1.area }
        var boxes: [(x1: Int, y1: Int, x2: Int, y2: Int, area: Int, bw: Int, bh: Int, inMean: Double)] = []
        for b in raw {
            var ov = false
            for k in boxes {
                let ix = max(0, min(b.x2, k.x2) - max(b.x1, k.x1))
                let iy = max(0, min(b.y2, k.y2) - max(b.y1, k.y1))
                let inter = ix * iy, uni = b.area + k.area - inter
                if uni > 0 && Double(inter) / Double(uni) > 0.6 { ov = true; break }
            }
            if !ov { boxes.append(b) }
            if boxes.count >= maxCount { break }
        }

        var out: [DetectedDefect] = []
        for b in boxes {
            let dark = b.inMean < gmean, bright = b.inMean > gmean
            let aspect = Double(max(b.bw, b.bh)) / Double(max(1, min(b.bw, b.bh)))
            var type = "defect"
            if dark && aspect < 1.8 { type = "porosity" }
            // 裂纹（含弧坑裂纹）：细长暗线，长宽比大；启发式，误报需模型提升
            else if dark && aspect >= 4 { type = "crack" }
            else if dark && aspect >= 1.8 { type = "undercut" }
            // 注意：不再把「比背景亮的块」判为余高(excess_weld_metal)。
            // 余高是几何量（焊缝凸起高度），2D 单帧亮度无法判定，必须由 LiDAR 剖面
            // (WeldProfileAnalyzer) 计算。纯 CV 下亮块（高光/反光/纹理）一律忽略。
            else if bright { continue }
            let rect = CGRect(x: Double(b.x1) / Double(w), y: Double(b.y1) / Double(h),
                              width: Double(b.bw) / Double(w), height: Double(b.bh) / Double(h))
            // 焊缝区域闸门：只保留中心落在 roi 内的缺陷
            if let r = roi, !r.contains(CGPoint(x: rect.midX, y: rect.midY)) { continue }
            out.append(DetectedDefect(rect: rect, type: type,
                                       pixelSize: CGSize(width: b.bw, height: b.bh)))
        }
        return out
    }
}
