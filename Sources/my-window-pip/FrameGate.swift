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
    ///
    /// 用途：`scalesToFit` 下输出缓冲可能带黑边，或源窗口尺寸变化后输出还没跟上，
    /// 上层可据此判断「源尺寸变了」并重算输出分辨率 / 宽高比。解析不出返回 nil。
    static func contentRectPixelSize(_ sb: CMSampleBuffer) -> CGSize? {
        guard let info = attachments(sb),
              let dict = info[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        let scale = (info[.scaleFactor] as? CGFloat) ?? 1
        let factor = scale > 0 ? scale : 1
        let size = CGSize(width: rect.width * factor, height: rect.height * factor)
        guard size.width > 0, size.height > 0 else { return nil }
        return size
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
