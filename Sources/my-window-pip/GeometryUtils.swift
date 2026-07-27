import AppKit

/// 坐标与缩放几何工具。所有涉及坐标系转换的计算都必须走这里，避免各处各写一份。
///
/// 坐标系约定：
/// - **AppKit 全局坐标**：左下原点，单位为逻辑点（NSScreen.frame / NSWindow.frame）
/// - **SCK 坐标**：左上原点，相对于所属 display 的左上角，单位为逻辑点（SCStreamConfiguration.sourceRect）
/// - **源归一化坐标**：左上原点，0…1，用于 zoom anchor
enum Geo {

    // MARK: - 尺寸

    /// 逻辑点 → 捕获像素尺寸，并 clamp 到安全范围（避免超大流打满带宽）。
    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = Int((points.width * scale).rounded())
        let h = Int((points.height * scale).rounded())
        return (min(max(w, 2), 4096), min(max(h, 2), 4096))
    }

    // MARK: - 缩放 / 平移

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, PiPSessionState.minZoom), PiPSessionState.maxZoom)
    }

    /// 计算裁剪矩形（在源画面坐标系内，左上原点）。
    /// - Parameters:
    ///   - full: 源画面完整矩形，origin 通常为 .zero
    static func sourceRect(zoom: CGFloat, anchor: CGPoint, full: CGRect) -> CGRect {
        let z = clampZoom(zoom)
        let w = full.width / z
        let h = full.height / z
        var x = full.minX + anchor.x * full.width - w / 2
        var y = full.minY + anchor.y * full.height - h / 2
        x = min(max(x, full.minX), full.maxX - w)
        y = min(max(y, full.minY), full.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 把 anchor 限制在当前倍率下的合法范围内（保证裁剪框不出界）。
    static func clampAnchor(_ anchor: CGPoint, zoom: CGFloat) -> CGPoint {
        let z = clampZoom(zoom)
        guard z > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        let half = 1 / (2 * z)
        return CGPoint(
            x: min(max(anchor.x, half), 1 - half),
            y: min(max(anchor.y, half), 1 - half)
        )
    }

    /// 平移：delta 为归一化的视野位移（相对当前可见区域的比例）。
    static func anchor(_ anchor: CGPoint, pannedBy delta: CGSize, zoom: CGFloat) -> CGPoint {
        let z = clampZoom(zoom)
        let moved = CGPoint(x: anchor.x + delta.width / z, y: anchor.y + delta.height / z)
        return clampAnchor(moved, zoom: z)
    }

    /// 以指针位置为锚缩放：保持 `pointerNorm`（源归一化坐标）在缩放前后指向同一内容。
    static func anchor(zoomingFrom oldAnchor: CGPoint, oldZoom: CGFloat,
                       to newZoom: CGFloat, pointerNorm: CGPoint) -> CGPoint {
        let oz = clampZoom(oldZoom), nz = clampZoom(newZoom)
        guard nz > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        // pointer 在旧视野中的偏移（归一化到整幅画面）
        let dx = pointerNorm.x - oldAnchor.x
        let dy = pointerNorm.y - oldAnchor.y
        // 视野缩小 nz/oz 倍后，为让 pointer 位置不动，anchor 需要向 pointer 靠近同比例
        let ratio = oz / nz
        return clampAnchor(CGPoint(x: pointerNorm.x - dx * ratio,
                                   y: pointerNorm.y - dy * ratio), zoom: nz)
    }

    // MARK: - 视图 ↔ 源坐标

    /// `videoGravity = .resizeAspect` 下，内容在视图内实际占据的矩形（视图坐标，左下原点）。
    static func contentRect(aspect: CGSize, in bounds: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// 视图坐标点（左下原点）→ 当前可见画面的归一化坐标（左上原点，0…1）。
    /// 返回 nil 表示点在内容矩形之外。
    static func viewPointToVisibleNorm(_ point: CGPoint, aspect: CGSize, bounds: CGRect) -> CGPoint? {
        let content = contentRect(aspect: aspect, in: bounds)
        guard content.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - content.minX) / content.width,
            y: 1 - (point.y - content.minY) / content.height   // Y 翻转成左上原点
        )
    }

    /// 当前可见画面归一化坐标 → 整幅源画面归一化坐标（左上原点）。
    static func visibleNormToSourceNorm(_ p: CGPoint, zoom: CGFloat, anchor: CGPoint) -> CGPoint {
        let z = clampZoom(zoom)
        let half = 1 / (2 * z)
        let a = clampAnchor(anchor, zoom: z)
        return CGPoint(x: a.x - half + p.x / z, y: a.y - half + p.y / z)
    }

    /// 视图内的框选矩形 → 新的 (zoom, anchor)。
    static func zoomAndAnchor(forSelection rect: CGRect, aspect: CGSize, bounds: CGRect,
                              currentZoom: CGFloat, currentAnchor: CGPoint) -> (CGFloat, CGPoint)? {
        let content = contentRect(aspect: aspect, in: bounds)
        let sel = rect.intersection(content)
        guard sel.width > 8, sel.height > 8 else { return nil }
        // 选区在当前可见画面中的归一化尺寸
        let visW = sel.width / content.width
        let centerVisible = CGPoint(
            x: (sel.midX - content.minX) / content.width,
            y: 1 - (sel.midY - content.minY) / content.height
        )
        let sourceCenter = visibleNormToSourceNorm(centerVisible, zoom: currentZoom, anchor: currentAnchor)
        let newZoom = clampZoom(currentZoom / visW)
        return (newZoom, clampAnchor(sourceCenter, zoom: newZoom))
    }

    // MARK: - AppKit ↔ SCK 坐标

    /// AppKit 全局矩形（左下原点）→ 指定屏幕的 SCK 局部矩形（左上原点）。
    static func sckRect(fromScreenRect r: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: r.minX - f.minX,
                      y: f.maxY - r.maxY,
                      width: r.width, height: r.height)
    }

    /// 指定屏幕的 SCK 局部矩形（左上原点）→ AppKit 全局矩形（左下原点）。
    static func screenRect(fromSCKRect r: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: r.minX + f.minX,
                      y: f.maxY - r.minY - r.height,
                      width: r.width, height: r.height)
    }

    /// AppKit 全局矩形 → 目标窗口内的局部矩形（左上原点），用于区域捕获落在某窗口内的情形。
    /// - Parameter windowFrameTopLeft: 窗口在「左上原点全局坐标」下的矩形（SCWindow.frame 即为此坐标系）
    static func windowLocalRect(fromScreenRect r: CGRect, windowFrameTopLeft: CGRect,
                                primaryScreenMaxY: CGFloat) -> CGRect {
        // 先把 AppKit 矩形转成左上原点的全局坐标
        let topLeft = CGRect(x: r.minX, y: primaryScreenMaxY - r.maxY, width: r.width, height: r.height)
        return CGRect(x: topLeft.minX - windowFrameTopLeft.minX,
                      y: topLeft.minY - windowFrameTopLeft.minY,
                      width: topLeft.width, height: topLeft.height)
    }

    /// 主屏顶边的 Y 值（CG 全局坐标翻转基准）。
    static var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }

    /// 把矩形收拢进任意可见屏幕，避免浮窗跑到屏幕外。
    static func constrainToVisibleScreens(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }
        if screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return rect }
        let target = (NSScreen.main ?? screens[0]).visibleFrame
        var r = rect
        r.origin.x = min(max(rect.minX, target.minX), target.maxX - rect.width)
        r.origin.y = min(max(rect.minY, target.minY), target.maxY - rect.height)
        return r
    }

    // MARK: - DEBUG 自检

    #if DEBUG
    static func runSelfChecks() {
        let full = CGRect(x: 0, y: 0, width: 1000, height: 500)

        // 1x 时应为完整画面
        let r1 = sourceRect(zoom: 1, anchor: CGPoint(x: 0.5, y: 0.5), full: full)
        assert(abs(r1.width - 1000) < 0.001 && abs(r1.height - 500) < 0.001, "1x 应返回完整画面")

        // 2x 居中
        let r2 = sourceRect(zoom: 2, anchor: CGPoint(x: 0.5, y: 0.5), full: full)
        assert(abs(r2.width - 500) < 0.001 && abs(r2.minX - 250) < 0.001, "2x 居中裁剪不正确")

        // 越界 anchor 应被 clamp 回画面内
        let r3 = sourceRect(zoom: 4, anchor: CGPoint(x: 0, y: 0), full: full)
        assert(r3.minX >= -0.001 && r3.minY >= -0.001, "裁剪框越界")
        let r4 = sourceRect(zoom: 4, anchor: CGPoint(x: 1, y: 1), full: full)
        assert(r4.maxX <= full.maxX + 0.001 && r4.maxY <= full.maxY + 0.001, "裁剪框越界")

        // 平移后仍在合法范围
        let a = anchor(CGPoint(x: 0.5, y: 0.5), pannedBy: CGSize(width: 5, height: 5), zoom: 2)
        assert(a.x <= 0.75 + 0.001 && a.y <= 0.75 + 0.001, "平移未 clamp")

        // 指针锚缩放：指针位置内容保持不动
        let pointer = CGPoint(x: 0.25, y: 0.25)
        let na = anchor(zoomingFrom: CGPoint(x: 0.5, y: 0.5), oldZoom: 1, to: 2, pointerNorm: pointer)
        assert(abs(na.x - 0.25) < 0.26, "指针锚缩放偏移过大")

        // 坐标往返
        if let screen = NSScreen.main {
            let orig = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 80, width: 300, height: 200)
            let back = screenRect(fromSCKRect: sckRect(fromScreenRect: orig, on: screen), on: screen)
            assert(abs(back.minX - orig.minX) < 0.001 && abs(back.minY - orig.minY) < 0.001,
                   "AppKit ↔ SCK 坐标往返不一致")
        }

        // 内容矩形（16:9 塞进 4:3 视图应上下留边）
        let c = contentRect(aspect: CGSize(width: 16, height: 9), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        assert(abs(c.width - 400) < 0.001 && c.height < 400, "contentRect 计算错误")

        Log.debug("Geo 自检通过")
    }
    #endif
}
