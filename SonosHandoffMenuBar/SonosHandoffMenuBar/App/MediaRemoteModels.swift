import Foundation

enum MediaRemoteTransportCommand: String, Codable, Sendable {
    case play
    case pause
    case playPause
    case next
    case previous

    var displayName: String {
        switch self {
        case .play:
            return "Play"
        case .pause:
            return "Pause"
        case .playPause:
            return "Play/Pause"
        case .next:
            return "Next"
        case .previous:
            return "Previous"
        }
    }
}

struct MediaRemoteTarget: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let bundleIdentifier: String
    let parentBundleIdentifier: String
    let displayName: String
    let pid: Int
    let title: String
    let artist: String
    let album: String
    let playbackRate: String
    let mediaType: String?

    var appName: String {
        if !displayName.isEmpty {
            return displayName
        }
        if !parentBundleIdentifier.isEmpty {
            return parentBundleIdentifier
        }
        if !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return "Unknown"
    }

    var detailText: String {
        if !title.isEmpty, !artist.isEmpty {
            return "\(title) — \(artist)"
        }
        if !title.isEmpty {
            return title
        }
        if !artist.isEmpty {
            return artist
        }
        return bundleIdentifier
    }
}

enum MediaRemoteHelperState: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}

struct MediaRemoteHelperHealth: Equatable, Sendable {
    var state: MediaRemoteHelperState
    var message: String
    var pid: Int?
    var lastSnapshotAt: Date?
    var targetCount: Int

    static let stopped = MediaRemoteHelperHealth(
        state: .stopped,
        message: "Not started",
        pid: nil,
        lastSnapshotAt: nil,
        targetCount: 0
    )

    var badgeTitle: String {
        switch state {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        }
    }

    var isHealthy: Bool {
        state == .running
    }
}
