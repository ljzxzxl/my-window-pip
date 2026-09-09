import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 帧闸门：只做「这一帧要不要」与「这一帧长什么样」的廉价判断，无状态。
///
/// 两个职责：
/// 1. `accept` —— 过滤掉 SCK 的非 `.complete` 帧（idle / blank / suspended / started / stopped），
///    这些帧的像素内容不可用于渲染。
/// 2. `fingerprint` —— 对 BGRA 缓冲抽样出一个 64-bit 指纹，供 `IdleDetector` 判断画面是否静止。
///    抽样步长 16 行 × 16 像素，1080p 全屏帧也只读 ~8k 个像素，实测远低于 0.1ms。
enum FrameGate {

    struct ContentGeometry: Equatable {
        /// IOSurface / CVPixelBuffer 的完整像素尺寸。
        let bufferSize: CGSize
        /// SCK 元数据给出的有效内容区域，单位为 surface 像素，原点按 SCK 的左上坐标系解释。
        let visibleRectPixels: CGRect

        var hasPadding: Bool {
            visibleRectPixels.minX > 0.5
                || visibleRectPixels.minY > 0.5
                || abs(visibleRectPixels.maxX - bufferSize.width) > 0.5
                || abs(visibleRectPixels.maxY - bufferSize.height) > 0.5
        }
    }

    /// 指纹抽样步长（行 / 列，单位：像素）
    static let sampleStride = 16

    // MARK: - 帧状态

    /// 只放行 `.complete` 帧；解析不出 attachments 时放行（宁可多渲染一帧，也不要黑屏）。
    static func accept(_ sb: CMSampleBuffer) -> Bool {
        guard let status = status(sb) else { return true }
        return status == .complete
    }

    /// 取出 SCK 写在 attachment 里的帧状态，解析失败返回 nil。
    static func status(_ sb: CMSampleBuffer) -> SCFrameStatus? {
        guard let raw = attachments(sb)?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    // MARK: - 帧指纹

    /// 抽样指纹：BGRA 缓冲每 16 行取一次、每行每 16 像素取一次，累加成 UInt64（FNV-1a 混合）。
    ///
    /// 返回 nil 的情况：不是 BGRA / 是平面格式 / 锁定失败 / 尺寸不合法 —— 调用方应视为
    /// 「本帧无法判断」，不要据此判定静止。
    static func fingerprint(_ sb: CMSampleBuffer) -> UInt64? {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return nil }
        // 只处理我们自己配置的 32BGRA 打包格式，其它格式的行内布局不同，读了会算错
        guard CVPixelBufferGetPixelFormatType(px) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(px) else { return nil }
        guard CVPixelBufferLockBaseAddress(px, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }

        let width = CVPixelBufferGetWidth(px)
        let height = CVPixelBufferGetHeight(px)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(px)
        // 严格边界检查：一行至少要装得下 width 个 BGRA 像素，否则说明假设不成立，直接放弃
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(1, sampleStride)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a offset basis

        var y = 0
        while y < height {
            let row = bytes + y * bytesPerRow
            var x = 0
            while x < width {
                let p = row + x * 4
                // 只取 B/G/R 三通道：A 在屏幕捕获里恒为 255，参与计算纯属浪费
                let v = UInt64(p[0]) | (UInt64(p[1]) << 8) | (UInt64(p[2]) << 16)
                hash = (hash ^ v) &* 0x100_0000_01b3
                x += stride
            }
            y += stride
        }
        // 把尺寸混进指纹：分辨率变了必须算「画面有变化」
        hash = (hash ^ UInt64(width)) &* 0x100_0000_01b3
        hash = (hash ^ UInt64(height)) &* 0x100_0000_01b3
        return hash
    }

    // MARK: - attachment 附加信息

    /// 本帧实际有效内容的像素尺寸（`contentRect` × `scaleFactor`）。
    static func contentRectPixelSize(_ sb: CMSampleBuffer) -> CGSize? {
        contentGeometry(sb)?.visibleRectPixels.size
    }

    /// SCK 的 IOSurface 可能比有效窗口内容更大（尤其窗口重连/全屏切换后），黑边并不是源内容。
    /// `contentRect` 的 attachment 是 surface 坐标，但在 `scalesToFit` 路径里不同 macOS / 源窗口
    /// 会同时带 `scaleFactor` 与 `contentScale`；固定只乘其中一个会在重连后留下几像素黑边。
    /// 这里把几种合法换算映射到真实 pixel-buffer，选择面积最大的合法候选（也就是最贴近
    /// surface 的那个），renderer 再据此逐帧裁掉动态 padding。
    static func contentGeometry(_ sb: CMSampleBuffer) -> ContentGeometry? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
              let info = attachments(sb),
              let dict = info[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }

        let scaleFactor = positiveCGFloat(info[.scaleFactor]) ?? 1
        let contentScale = positiveCGFloat(info[.contentScale])
        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let visible = resolvedVisibleRectPixels(
            contentRect: rect,
            scaleFactor: scaleFactor,
            contentScale: contentScale,
            bufferSize: bufferSize
        ) else { return nil }
        return ContentGeometry(bufferSize: bufferSize, visibleRectPixels: visible)
    }

    /// 把 SCK 的 contentRect 解析到实际 pixel-buffer 坐标。拆成纯函数供回归测试。
    static func resolvedVisibleRectPixels(
        contentRect: CGRect,
        scaleFactor: CGFloat,
        contentScale: CGFloat?,
        bufferSize: CGSize
    ) -> CGRect? {
        guard bufferSize.width > 1, bufferSize.height > 1,
              contentRect.minX.isFinite, contentRect.minY.isFinite,
              contentRect.width.isFinite, contentRect.height.isFinite,
              contentRect.width > 1, contentRect.height > 1 else { return nil }

        var factors: [CGFloat] = [scaleFactor]
        if let contentScale, contentScale.isFinite, contentScale > 0 {
            factors.append(scaleFactor * contentScale)
            factors.append(contentScale)
        }
        factors.append(1)

        var unique: [CGFloat] = []
        for factor in factors where factor.isFinite && factor > 0 {
            if !unique.contains(where: { abs($0 - factor) < 0.0001 }) { unique.append(factor) }
        }

        let surfaceBounds = CGRect(origin: .zero, size: bufferSize)
        let tolerance: CGFloat = 2
        var candidates: [CGRect] = []
        for factor in unique {
            let candidate = CGRect(
                x: contentRect.minX * factor,
                y: contentRect.minY * factor,
                width: contentRect.width * factor,
                height: contentRect.height * factor
            )
            guard candidate.minX >= -tolerance, candidate.minY >= -tolerance,
                  candidate.maxX <= bufferSize.width + tolerance,
                  candidate.maxY <= bufferSize.height + tolerance else { continue }
            let clipped = candidate.intersection(surfaceBounds)
            guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { continue }
            candidates.append(clipped)
        }

        return candidates.max {
            ($0.width * $0.height) < ($1.width * $1.height)
        }
    }

    private static func positiveCGFloat(_ value: Any?) -> CGFloat? {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let number = value as? CGFloat {
            raw = Double(number)
        } else {
            raw = nil
        }
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        return CGFloat(raw)
    }

    /// 本帧的脏矩形数量。SCK 只在内容真的变化时才写入非空 `dirtyRects`，
    /// 因此这是一条「画面是否变化」的廉价旁证：`IdleDetector` 在不抽样的帧上用它兜底，
    /// 避免漏掉两次指纹采样之间的变化。解析不出返回 nil。
    static func dirtyRectCount(_ sb: CMSampleBuffer) -> Int? {
        guard let info = attachments(sb), let rects = info[.dirtyRects] as? NSArray else { return nil }
        return rects.count
    }

    // MARK: - 私有

    private static func attachments(_ sb: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]] else { return nil }
        return array.first
    }
}
