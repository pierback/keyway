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

    static let recentlyPausedInterval: TimeInterval = 15 * 60

    /// Tiers: playing, paused within `recentlyPausedInterval`, idle. Playing Spotify always leads. Within a tier the
    /// most recent of "started/stopped playing" and "picked in Keyway" wins; unresponsive rows sink; idle apps rank above idle tabs.
    static func sortedTargets(
        _ rows: [SourceRow],
        recentTargetID: String?,
        recentPickedAt: Date?,
        now: Date
    ) -> [MediaRemoteTarget] {
        func tier(_ row: SourceRow) -> Int {
            if row.target.isCurrentlyPlaying {
                return 0
            }
            if let stoppedAt = row.playbackStoppedAt, now.timeIntervalSince(stoppedAt) <= recentlyPausedInterval {
                return 1
            }
            return 2
        }
        func lastActivity(_ row: SourceRow) -> Date {
            let playback = row.target.isCurrentlyPlaying ? row.playbackStartedAt : row.playbackStoppedAt
            let picked = row.id == recentTargetID ? recentPickedAt : nil
            return max(playback ?? .distantPast, picked ?? .distantPast)
        }

        return rows.sorted { lhs, rhs in
            if tier(lhs) != tier(rhs) {
                return tier(lhs) < tier(rhs)
            }
            if tier(lhs) == 0, lhs.target.isSpotify != rhs.target.isSpotify {
                return lhs.target.isSpotify
            }
            if lhs.reachability.isSuspect != rhs.reachability.isSuspect {
                return !lhs.reachability.isSuspect
            }
            if lastActivity(lhs) != lastActivity(rhs) {
                return lastActivity(lhs) > lastActivity(rhs)
            }
            if lhs.target.isBrowserLike != rhs.target.isBrowserLike {
                return !lhs.target.isBrowserLike
            }
            let appOrder = lhs.target.appName.localizedStandardCompare(rhs.target.appName)
            if appOrder != .orderedSame {
                return appOrder == .orderedAscending
            }
            let titleOrder = lhs.target.title.localizedStandardCompare(rhs.target.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        .map(\.target)
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
