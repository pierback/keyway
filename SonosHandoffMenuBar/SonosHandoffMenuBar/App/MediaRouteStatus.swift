import Foundation

enum MediaRouteStatusKind: String, Equatable {
    case auto
    case focused
    case chooser
    case unavailable

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .focused:
            return "Focused"
        case .chooser:
            return "Chooser"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct MediaRouteStatus: Equatable {
    var kind: MediaRouteStatusKind
    var target: MediaRemoteTarget?
    var targetCount: Int

    var subtitle: String {
        switch kind {
        case .auto:
            return targetCount == 1 ? "Single media target" : "Automatic routing"
        case .focused:
            return "Foreground or visible window"
        case .chooser:
            return "Choose target"
        case .unavailable:
            return "Start Spotify, browser media, or QuickTime"
        }
    }
}

enum MediaTransportRoutingReason: String {
    case single = "single target"
    case focused = "focused target"
    case current = "current media target"
    case chooser = "chooser"
}

enum MediaTransportDispatchEchoKind: String {
    case automatic
    case chooser
}

struct MediaTransportPendingDispatchEcho {
    let command: MediaRemoteTransportCommand
    let kind: MediaTransportDispatchEchoKind
}
