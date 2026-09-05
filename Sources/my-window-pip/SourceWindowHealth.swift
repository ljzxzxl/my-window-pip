import Foundation

/// Pure lifecycle decision input. System queries should populate this object; policy must stay testable.
struct SourceWindowObservation: Equatable {
    let cgWindowExists: Bool?
    let processAlive: Bool?
    let ownerPIDMatches: Bool?
    let isOnScreen: Bool?
    let axMinimized: Bool?
}

enum SourceWindowHealth: Equatable {
    case onScreen
    case offScreenAlive
    case minimized
    case missing
    case unknown
}

/// Conservative source-window lifecycle classifier.
/// Unknown states intentionally preserve PiP rather than closing it.
func classifySourceWindowHealth(_ observation: SourceWindowObservation) -> SourceWindowHealth {
    if observation.processAlive == false {
        return .missing
    }
    if observation.ownerPIDMatches == false {
        return .missing
    }
    if observation.axMinimized == true {
        return .minimized
    }
    if observation.cgWindowExists == true {
        if observation.isOnScreen == true {
            return .onScreen
        }
        if observation.axMinimized == false || observation.processAlive == true {
            return .offScreenAlive
        }
    }
    // `cgWindowExists` 只能由 WindowServer 的单 windowID 查询填写；false 是窗口 ID 已不存在的
    // 直接证据，不是 SCK cache miss，因此即使 owner 进程还活着也可以进入 rematch/missing 路径。
    if observation.cgWindowExists == false {
        return .missing
    }
    return .unknown
}
