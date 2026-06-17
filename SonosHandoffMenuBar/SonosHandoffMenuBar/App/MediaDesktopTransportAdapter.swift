import AppKit
import ApplicationServices
import Foundation

enum MediaDesktopTransportBackend: String, Sendable {
    case spotifyAppleEvent = "spotify_apple_event"
}

@MainActor
final class MediaDesktopTransportAdapter {
    private static let spotifyBundleIdentifier = "com.spotify.client"

    func backendName(for target: MediaRemoteTarget) -> String? {
        backend(for: target)?.rawValue
    }

    func backendName(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> String? {
        backend(for: target)?.rawValue
    }

    func keepsPlayPauseToggle(for target: MediaRemoteTarget) -> Bool {
        backend(for: target) != nil
    }

    func submit(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent? {
        guard let backend = backend(for: target) else {
            return nil
        }

        switch backend {
        case .spotifyAppleEvent:
            return submitSpotifyCommand(command: command, target: target)
        }
    }

    private func backend(for target: MediaRemoteTarget) -> MediaDesktopTransportBackend? {
        guard !ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        if Self.isSpotifyTarget(target) {
            return .spotifyAppleEvent
        }
        return nil
    }

    private func submitSpotifyCommand(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        let beforeStatus = Self.spotifyPlaybackStatus()
        guard beforeStatus.error == nil else {
            return MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: UUID().uuidString,
                targetID: target.id,
                command: command.rawValue,
                ok: false,
                message: "Spotify AppleScript status failed: \(beforeStatus.error ?? "unknown")",
                backend: MediaDesktopTransportBackend.spotifyAppleEvent.rawValue,
                unsupported: true
            )
        }
        guard let beforeState = beforeStatus.state,
              let beforeTrack = beforeStatus.track,
              !beforeTrack.isEmpty,
              beforeState == "playing" || beforeState == "paused"
        else {
            return MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: UUID().uuidString,
                targetID: target.id,
                command: command.rawValue,
                ok: false,
                message: "Spotify has no current desktop track; state=\(beforeStatus.state ?? "unknown").",
                backend: MediaDesktopTransportBackend.spotifyAppleEvent.rawValue,
                unsupported: true
            )
        }

        let eventID = Self.spotifyAppleEventID(command: command)
        let status = Self.sendAppleEvent(
            bundleIdentifier: Self.spotifyBundleIdentifier,
            eventClass: "spfy",
            eventID: eventID
        )
        let ok = status == noErr
        if ok, let expectedState = Self.expectedSpotifyState(command: command, beforeState: beforeState),
           !Self.waitForSpotifyState(expectedState) {
            let afterStatus = Self.spotifyPlaybackStatus()
            return MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: UUID().uuidString,
                targetID: target.id,
                command: command.rawValue,
                ok: false,
                message: "Spotify AppleEvent did not reach \(expectedState); state=\(afterStatus.state ?? "unknown").",
                backend: MediaDesktopTransportBackend.spotifyAppleEvent.rawValue
            )
        }

        return MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: ok,
            message: ok ? "submitted Spotify AppleEvent command event=\(eventID)" : "Spotify AppleEvent failed status=\(status)",
            backend: MediaDesktopTransportBackend.spotifyAppleEvent.rawValue
        )
    }

    private static func isSpotifyTarget(_ target: MediaRemoteTarget) -> Bool {
        target.bundleIdentifier == spotifyBundleIdentifier || target.parentBundleIdentifier == spotifyBundleIdentifier
    }

    private static func appleScript(source: String) -> NSAppleScript {
        guard let script = NSAppleScript(source: source) else {
            preconditionFailure("Static desktop automation AppleScript must compile.")
        }
        return script
    }

    private static func spotifyAppleEventID(command: MediaRemoteTransportCommand) -> String {
        switch command {
        case .play:
            return "Play"
        case .pause:
            return "Paus"
        case .playPause:
            return "PlPs"
        case .next:
            return "Next"
        case .previous:
            return "Prev"
        }
    }

    private static func expectedSpotifyState(command: MediaRemoteTransportCommand, beforeState: String) -> String? {
        switch command {
        case .play:
            return "playing"
        case .pause:
            return "paused"
        case .playPause:
            return beforeState == "playing" ? "paused" : "playing"
        case .next, .previous:
            return nil
        }
    }

    private static func waitForSpotifyState(_ expectedState: String) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if spotifyPlaybackStatus().state == expectedState {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func spotifyPlaybackStatus() -> (state: String?, track: String?, error: String?) {
        let script = appleScript(source: spotifyPlaybackStatusAppleScriptSource())
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""
        if let error {
            return (nil, nil, String(describing: error))
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (lines.first, lines.dropFirst().first, nil)
    }

    private static func sendAppleEvent(
        bundleIdentifier: String,
        eventClass: String,
        eventID: String
    ) -> OSStatus {
        var target = AEAddressDesc()
        let targetStatus = bundleIdentifier.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                bundleIdentifier.lengthOfBytes(using: .utf8),
                &target
            )
        }
        guard targetStatus == noErr else {
            return OSStatus(targetStatus)
        }
        defer { AEDisposeDesc(&target) }

        var event = AppleEvent()
        let eventStatus = AECreateAppleEvent(
            AEEventClass(fourCharCode(eventClass)),
            AEEventID(fourCharCode(eventID)),
            &target,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        )
        guard eventStatus == noErr else {
            return OSStatus(eventStatus)
        }
        defer { AEDisposeDesc(&event) }

        return AESendMessage(
            &event,
            nil,
            AESendMode(kAENoReply | kAECanInteract | kAECanSwitchLayer),
            kAEDefaultTimeout
        )
    }

    private static func fourCharCode(_ value: String) -> OSType {
        let bytes = Array(value.utf8)
        precondition(bytes.count == 4, "AppleEvent codes must be exactly four bytes.")
        var result: UInt32 = 0
        for byte in bytes {
            result = (result << 8) + UInt32(byte)
        }
        return result
    }

    private static func spotifyPlaybackStatusAppleScriptSource() -> String {
        #"""
        tell application id "com.spotify.client"
            set playbackState to player state as string
            if playbackState is "stopped" then
                return playbackState
            end if
            return playbackState & linefeed & (name of current track)
        end tell
        """#
    }
}
