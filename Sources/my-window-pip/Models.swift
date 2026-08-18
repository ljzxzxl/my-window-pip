import AppKit
import CoreMedia
import Foundation

// MARK: - 捕获来源

/// PiP 的捕获来源。
enum CaptureSource: Equatable {
    /// 单个窗口。`id` 为 CGWindowID，`bundleID` 可能为 nil（无 bundle 的进程）。
    case window(id: CGWindowID, bundleID: String?, appName: String, title: String)
    /// 屏幕区域。`rect` 为 AppKit 全局坐标（左下原点，逻辑点）。
    case region(displayID: CGDirectDisplayID, rect: CGRect)

    /// per-app 偏好（帧率 / 宽度 / 位置）使用的存储键。
    var preferenceKey: String {
        switch self {
        case let .window(_, bundleID, appName, _): return bundleID ?? "app:\(appName)"
        case .region: return Self.regionPreferenceKey
        }
    }

    static let regionPreferenceKey = "__region__"

    var windowID: CGWindowID? {
        if case let .window(id, _, _, _) = self { return id }
        return nil
    }

    var appName: String {
        switch self {
        case let .window(_, _, appName, _): return appName
        case .region: return L.t("屏幕区域", "Screen Region")
        }
    }

    var title: String {
        switch self {
        case let .window(_, _, _, title): return title
        case let .region(_, rect):
            return "\(Int(rect.width))×\(Int(rect.height))"
        }
    }

    var displayTitle: String {
        let t = title
        return t.isEmpty ? appName : "\(appName) · \(t)"
    }
}

// MARK: - 会话状态

/// 帧率档位。
enum FPSStep: Int, CaseIterable {
    case one = 1, five = 5, ten = 10, fifteen = 15, thirty = 30, sixty = 60

    var label: String { "\(rawValue) fps" }

    /// 在档位表中循环到下一档（增强模式按 F 键使用）。
    func next() -> FPSStep {
        let all = FPSStep.allCases
        let idx = all.firstIndex(of: self) ?? 3
        return all[(idx + 1) % all.count]
    }

    static func nearest(to value: Int) -> FPSStep {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .fifteen
    }
}

/// 浮窗层级偏好。
enum WindowLevelMode: String, CaseIterable {
    /// 全局悬浮：所有 Space 可见，尽量盖在全屏应用之上。
    case global
    /// 普通置顶：仅当前 Space，不侵入全屏应用。
    case normal

    /// 比 `.popUpMenu`(101) 低一级：仍压在普通窗口(0)、浮动面板(3)、别的 App 的模态面板(8)、
    /// 菜单栏本体(25) 之上，但让开状态栏工具的下拉菜单——浮窗放右上角时不再挡住那些菜单。
    /// 不用 `.screenSaver`(1000) 就是因为它高于 101。
    static let globalLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    var windowLevel: NSWindow.Level {
        switch self {
        case .global: return Self.globalLevel
        case .normal: return .floating
        }
    }

    var collectionBehavior: NSWindow.CollectionBehavior {
        switch self {
        case .global: return [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .normal: return [.managed, .fullScreenAuxiliary]
        }
    }

    var label: String {
        switch self {
        case .global: return L.t("全局悬浮（所有 Space / 全屏应用之上）", "Global (all Spaces, above full-screen)")
        case .normal: return L.t("普通置顶（仅当前 Space）", "Normal (current Space only)")
        }
    }
}

/// 单个 PiP 会话的可变状态。
struct PiPSessionState {
    var source: CaptureSource
    /// 放大倍率，1.0…20.0
    var zoom: CGFloat = 1.0
    /// 放大中心（源画面归一化坐标，左上原点，0…1）
    var anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var fps: FPSStep = .fifteen
    var autoHide: Bool = false
    var idleDetection: Bool = true
    var isPaused: Bool = false
    /// 被用户完全隐藏（orderOut）
    var isHidden: Bool = false

    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 20.0
}

/// 创建一个 PiP 会话的请求。
struct SessionRequest {
    var source: CaptureSource
    /// 捕获基准矩形（源坐标系、左上原点、逻辑点）：
    /// - 整窗 PiP：`(0, 0, 窗口宽, 窗口高)`
    /// - 窗口内的区域捕获：该区域在窗口内的局部矩形
    /// - 显示器区域捕获：该区域在显示器内的局部矩形
    /// 缩放/平移都在这个基准矩形内部进行。
    var baseSourceRect: CGRect
    /// 基准矩形对应的物理像素尺寸，用于判断放大到多少倍仍有原生像素
    var sourcePixelSize: CGSize
    /// 基准矩形的逻辑尺寸（点），决定初始宽高比
    var sourcePointSize: CGSize
    var fps: FPSStep
    var autoHide: Bool
    var idleDetection: Bool
}

// MARK: - 静止检测

/// 静止检测结论。
struct IdleVerdict {
    var isIdle: Bool
    /// 建议使用的帧率（静止时为 1）
    var suggestedFPS: Int
}

// MARK: - 会话对外事件

/// PiP 会话的运行态，用于驱动占位视图。
enum SessionRuntimeState: Equatable {
    case streaming
    case paused
    /// 源窗口已最小化 / 暂时不可见，等待恢复
    case waitingForSource
    /// 正在重连（第 n 次）
    case reconnecting(attempt: Int)
    /// 源已永久消失
    case sourceLost
    /// 权限缺失
    case permissionDenied
    case failed(message: String)
}

// MARK: - 跨层协议
//
// 说明：协议刻意不带 sender 参数，让捕获层与展示层互不依赖对方的具体类型，
// 由会话层（PiPSession）同时实现两个协议做中转。

/// 捕获引擎向上回调。
protocol CaptureEngineDelegate: AnyObject {
    /// 在捕获队列（**非主线程**）调用，已通过帧闸门过滤，只会收到 `.complete` 帧。
    func captureDidOutput(_ sampleBuffer: CMSampleBuffer)
    /// 主线程调用：引擎即将重建 SCStream；展示层应先重置旧 renderer 时间线。
    func captureWillRestart()
    /// 主线程调用：流已停止（error 为 nil 表示主动停止）。
    func captureDidStop(error: Error?)
    /// 主线程调用：一段时间内未收到有效帧（源可能被最小化或遮挡）。
    func captureDidStall()
}

/// PiP 窗口向上回调（用户交互 → 会话）。
protocol PiPWindowDelegate: AnyObject {
    /// 供窗口读取当前会话状态（渲染菜单勾选、标题栏信息）。
    var currentSessionState: PiPSessionState { get }

    func pipRequestClose()
    /// 请求缩放到指定倍率与锚点（锚点为源画面归一化坐标，左上原点）
    func pipRequestZoom(_ zoom: CGFloat, anchor: CGPoint)
    /// 归一化平移增量（正值表示画面向右/向下移动视野）
    func pipRequestPan(by delta: CGSize)
    func pipRequestZoomReset()
    /// 窗口尺寸变化（已 debounce）：新的逻辑尺寸与所在屏幕的 backingScaleFactor
    func pipDidResize(pointSize: CGSize, scale: CGFloat)
    func pipRequestFPS(_ fps: FPSStep)
    func pipRequestToggleAutoHide()
    /// 请求把全局「自动隐藏透明度」改为指定值（0.05…0.95，5% 一档）
    func pipRequestAutoHideOpacity(_ opacity: CGFloat)
    func pipRequestToggleIdleDetection()
    func pipRequestTogglePause()
    /// 单击浮窗：请求切换到源应用窗口
    func pipRequestActivateSource()
    /// 切换「单击浮窗切换到源应用」开关
    func pipRequestToggleClickToActivate()
    /// 显示层经 flush + 重建后仍无法接收帧，请求会话层重启捕获流。
    func pipRendererRecoveryExhausted()
    /// renderer 卡流已恢复：会话层据此清零重启限流计数。
    func pipRendererDidRecover()
    /// 右键菜单将要更新：会话可趁此按需刷新源窗口标题
    func pipMenuWillOpen()
    /// 拖动窗口时请求上层根据屏幕与其他 PiP 修正位置（尺寸由窗口层保持不变）
    func pipResolveDragFrame(_ proposedFrame: CGRect,
                             modifierFlags: NSEvent.ModifierFlags) -> CGRect
    func pipDidMove()
}
