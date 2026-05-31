import Foundation
import SonosHandoffCore

enum MediaTransportCommandRules {
    static func isPlayFamily(_ command: MediaRemoteTransportCommand) -> Bool {
        command == .playPause || command == .pause || command == .play
    }

    static func rowScopedCommand(
        _ command: MediaRemoteTransportCommand,
        for target: MediaRemoteTarget
    ) -> MediaRemoteTransportCommand {
        guard command == .playPause else {
            return command
        }
        return target.isCurrentlyPlaying ? .pause : .play
    }

    static func statusKind(for reason: MediaTransportRoutingReason) -> MediaRouteStatusKind {
        switch reason {
        case .single:
            return .auto
        case .focused:
            return .focused
        case .current:
            return .auto
        case .chooser:
            return .chooser
        }
    }

    static func sortedTargets(
        _ targets: [MediaRemoteTarget],
        activeTargetID: String?
    ) -> [MediaRemoteTarget] {
        targets.sorted { lhs, rhs in
            if lhs.isCurrentlyPlaying != rhs.isCurrentlyPlaying {
                return lhs.isCurrentlyPlaying
            }
            if lhs.playbackFreshness != rhs.playbackFreshness {
                return lhs.playbackFreshness > rhs.playbackFreshness
            }
            let lhsActive = lhs.id == activeTargetID
            let rhsActive = rhs.id == activeTargetID
            if lhsActive != rhsActive {
                return lhsActive
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
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
