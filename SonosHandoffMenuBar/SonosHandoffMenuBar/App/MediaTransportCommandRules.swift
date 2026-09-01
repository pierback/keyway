import Foundation
import SonosHandoffCore

enum MediaTransportCommandRules {
    static let emptyDiscoveryInterval: TimeInterval = 1.5

    static func isPlayFamily(_ command: MediaRemoteTransportCommand) -> Bool {
        command == .playPause || command == .pause || command == .play
    }

    static func shouldOpenChooserForAutomaticRoute(reachability: MediaSourceReachability?) -> Bool {
        guard let reachability else {
            return true
        }
        switch reachability {
        case .live:
            return false
        case .suspect:
            return true
        }
    }

    static func rowScopedCommand(
        _ command: MediaRemoteTransportCommand,
        for target: MediaRemoteTarget,
        after previousCommand: MediaRemoteTransportCommand?
    ) -> MediaRemoteTransportCommand {
        guard command == .playPause else {
            return command
        }
        if previousCommand == .play {
            return .pause
        }
        if previousCommand == .pause {
            return .play
        }
        return target.isCurrentlyPlaying ? .pause : .play
    }

    static func sortedTargets(
        _ targets: [MediaRemoteTarget],
        preferredTargetID: String?
    ) -> [MediaRemoteTarget] {
        targets.sorted { lhs, rhs in
            if lhs.isCurrentlyPlaying != rhs.isCurrentlyPlaying {
                return lhs.isCurrentlyPlaying
            }
            let lhsPreferred = lhs.id == preferredTargetID
            let rhsPreferred = rhs.id == preferredTargetID
            if lhsPreferred != rhsPreferred {
                return lhsPreferred
            }
            let appOrder = lhs.appName.localizedStandardCompare(rhs.appName)
            if appOrder != .orderedSame {
                return appOrder == .orderedAscending
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    static func targetLogSummary(_ targets: [MediaRemoteTarget]) -> String {
        targets
            .prefix(6)
            .map { target in
                "\(target.appName){id=\(target.id),playing=\(target.isCurrentlyPlaying)}"
            }
            .joined(separator: ",")
    }
}
