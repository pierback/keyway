import AppKit
import Foundation
import UniformTypeIdentifiers

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

    var symbolName: String {
        switch self {
        case .play:
            return "play.fill"
        case .pause:
            return "pause.fill"
        case .playPause:
            return "playpause.fill"
        case .next:
            return "forward.end.fill"
        case .previous:
            return "backward.end.fill"
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
    let artworkBase64: String?
    let duration: Double?
    let elapsedTime: Double?
    let elapsedTimestamp: Double?
    let supportedCommands: [MediaRemoteTransportCommand]?

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

    @MainActor
    var artworkImage: NSImage? {
        guard let artworkBase64, !artworkBase64.isEmpty,
              let data = Data(base64Encoded: artworkBase64),
              let image = NSImage(data: data) else {
            return nil
        }
        image.size = NSSize(width: 96, height: 96)

        return image
    }

    var playbackFraction: CGFloat {
        guard let duration, duration > 0, let elapsedTime else {
            return 0
        }
        var elapsed = elapsedTime
        if let elapsedTimestamp, elapsedTimestamp > 0 {
            let now = Date().timeIntervalSince1970
            let delta = now - elapsedTimestamp
            if delta > 0, delta < 600, playbackRate == "1" {
                elapsed += delta
            }
        }

        return min(1, max(0, CGFloat(elapsed / duration)))
    }

    var isCurrentlyPlaying: Bool {
        playbackRate == "1"
    }

    var playbackFreshness: Double {
        elapsedTimestamp ?? 0
    }

    var elapsedFormatted: String? {
        guard let duration, duration > 0, let elapsedTime else {
            return nil
        }
        var elapsed = elapsedTime
        if let elapsedTimestamp, elapsedTimestamp > 0 {
            let now = Date().timeIntervalSince1970
            let delta = now - elapsedTimestamp
            if delta > 0, delta < 600, playbackRate == "1" {
                elapsed += delta
            }
        }
        elapsed = min(elapsed, duration)

        return Self.formatTime(elapsed)
    }

    var remainingFormatted: String? {
        guard let duration, duration > 0, let elapsedTime else {
            return nil
        }
        var elapsed = elapsedTime
        if let elapsedTimestamp, elapsedTimestamp > 0 {
            let now = Date().timeIntervalSince1970
            let delta = now - elapsedTimestamp
            if delta > 0, delta < 600, playbackRate == "1" {
                elapsed += delta
            }
        }
        let remaining = max(0, duration - elapsed)

        return "-\(Self.formatTime(remaining))"
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60

        return String(format: "%d:%02d", m, s)
    }

    var routingIdentity: String {
        if !parentBundleIdentifier.isEmpty {
            return parentBundleIdentifier
        }
        if !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return id
    }

    var isSpotify: Bool {
        let identities = [bundleIdentifier, parentBundleIdentifier].map { $0.lowercased() }
        return identities.contains("com.spotify.client")
            || identities.contains { $0.contains("spotify") }
    }

    var isBrowserLike: Bool {
        if ChromiumBrowserExtensionTransport.isTarget(self) {
            return true
        }

        let identities = [bundleIdentifier, parentBundleIdentifier].map { $0.lowercased() }
        return identities.contains { identity in
            identity.contains("safari")
                || identity.contains("chrome")
                || identity.contains("firefox")
                || identity.contains("brave")
                || identity.contains("arc")
                || identity.contains("helium")
                || identity.contains("browser")
        }
    }

    var isChromiumBrowserLike: Bool {
        if ChromiumBrowserExtensionTransport.isTarget(self) {
            return true
        }

        let identities = [bundleIdentifier, parentBundleIdentifier, displayName].map { $0.lowercased() }
        return identities.contains { identity in
            identity.contains("chrome")
                || identity.contains("chromium")
                || identity.contains("brave")
                || identity.contains("edge")
                || identity.contains("arc")
                || identity.contains("helium")
                || identity.contains("opera")
                || identity.contains("vivaldi")
        }
    }

    func matchesRoutingIdentity(_ identity: String?) -> Bool {
        guard let identity, !identity.isEmpty else {
            return false
        }
        return id == identity
            || routingIdentity == identity
            || bundleIdentifier == identity
            || parentBundleIdentifier == identity
    }

    @MainActor
    var appIcon: NSImage {
        let bundleIDs = [bundleIdentifier, parentBundleIdentifier].filter { !$0.isEmpty }
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                image.size = NSSize(width: 34, height: 34)
                return image
            }
        }

        return NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: appName)
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
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
