enum MediaTransportRoutingReason: String {
    case single = "single target"
    case focused = "focused target"
    case current = "current media target"
    case recent = "recent media target"
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
