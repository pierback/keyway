import AppKit
import ApplicationServices
import Foundation

enum MediaDesktopTransportBackend: String, Sendable {
    case spotifyAppleEvent = "spotify_apple_event"
    case heliumJavaScript = "helium_javascript"
}

@MainActor
final class MediaDesktopTransportAdapter {
    private static let spotifyBundleIdentifier = "com.spotify.client"
    private static let heliumBundleIdentifier = "net.imput.helium"

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
        case .heliumJavaScript:
            guard Self.isHeliumSupported(command) else {
                return MediaRemoteCommandResultEvent(
                    type: "commandResult",
                    requestID: UUID().uuidString,
                    targetID: target.id,
                    command: command.rawValue,
                    ok: false,
                    message: "Helium does not support \(command.displayName).",
                    backend: MediaDesktopTransportBackend.heliumJavaScript.rawValue,
                    unsupported: true
                )
            }
            return submitHeliumCommand(command: command, target: target)
        }
    }

    static func targetsIncludingDesktopAutomationTargets(_ targets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        let heliumAvailability = heliumActiveTabMediaAvailable()
        if heliumAvailability == false {
            return targets.filter { !isHeliumTarget($0) }
        }
        guard !targets.contains(where: isHeliumTarget),
              heliumAvailability == true,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: heliumBundleIdentifier).first,
              !app.isTerminated
        else {
            return targets
        }

        return targets + [MediaRemoteTarget(
            id: "\(heliumBundleIdentifier):\(app.processIdentifier):desktop",
            bundleIdentifier: heliumBundleIdentifier,
            parentBundleIdentifier: "",
            displayName: app.localizedName ?? "Helium",
            pid: Int(app.processIdentifier),
            title: "Browser media",
            artist: "",
            album: "",
            playbackRate: "",
            mediaType: "desktop_automation",
            artworkBase64: nil,
            duration: nil,
            elapsedTime: nil,
            elapsedTimestamp: nil,
            supportedCommands: nil
        )]
    }

    private func backend(for target: MediaRemoteTarget) -> MediaDesktopTransportBackend? {
        if Self.isSpotifyTarget(target) {
            return .spotifyAppleEvent
        }
        if Self.isHeliumTarget(target) {
            return .heliumJavaScript
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

    private func submitHeliumCommand(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        let result = Self.runHeliumJavaScriptCommand(command: command)
        return MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: result.ok,
            message: result.ok ? "submitted Helium JavaScript command state=\(result.message)" : "Helium JavaScript failed: \(result.message)",
            backend: MediaDesktopTransportBackend.heliumJavaScript.rawValue
        )
    }

    private static func isSpotifyTarget(_ target: MediaRemoteTarget) -> Bool {
        target.bundleIdentifier == spotifyBundleIdentifier || target.parentBundleIdentifier == spotifyBundleIdentifier
    }

    private static func isHeliumTarget(_ target: MediaRemoteTarget) -> Bool {
        target.bundleIdentifier == heliumBundleIdentifier || target.parentBundleIdentifier == heliumBundleIdentifier
    }

    private static func isHeliumSupported(_ command: MediaRemoteTransportCommand) -> Bool {
        switch command {
        case .play, .pause, .playPause:
            return true
        case .next, .previous:
            return false
        }
    }

    private static func heliumActiveTabMediaAvailable() -> Bool? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: heliumBundleIdentifier).contains(where: { !$0.isTerminated }) else {
            return false
        }
        let script = appleScript(source: heliumMediaAvailabilityAppleScriptSource())
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""
        if error != nil {
            return nil
        }
        if output == "media" {
            return true
        }
        if output == "no_windows" || output == "no_media" {
            return false
        }
        return nil
    }

    private static func runHeliumJavaScriptCommand(command: MediaRemoteTransportCommand) -> (ok: Bool, message: String) {
        let script = appleScript(source: heliumJavaScriptCommandAppleScriptSource(command: command))
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""
        if let error {
            return (false, String(describing: error))
        }
        let ok = output == "paused" || output == "playing" || output == "play_requested"
            || output == "already_playing" || output == "already_paused"
        return (ok, output)
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

    private static func heliumMediaAvailabilityAppleScriptSource() -> String {
        #"""
tell application id "net.imput.helium"
    if (count of windows) = 0 then return "no_windows"
    return execute active tab of front window javascript "(() => { const hasMediaSource = element => Boolean(element.currentSrc || element.src || element.querySelector('source')); const isReady = element => !element.ended && hasMediaSource(element); const direct = Array.from(document.querySelectorAll('video,audio')).filter(isReady); if (direct.length > 0) return 'media'; const seen = new Set(); const roots = [document]; for (let index = 0; index < roots.length; index += 1) { const root = roots[index]; root.querySelectorAll('video,audio').forEach(element => { if (!seen.has(element)) seen.add(element); }); root.querySelectorAll('*').forEach(element => { if (element.shadowRoot) roots.push(element.shadowRoot); }); root.querySelectorAll('iframe,frame').forEach(frame => { const source = frame.getAttribute('src') || ''; const sameOrigin = source === '' || source.startsWith('about:') || new URL(frame.src || source, location.href).origin === location.origin; const sandbox = frame.getAttribute('sandbox'); const sandboxAllowsSameOrigin = sandbox === null || sandbox.split(/\\s+/).includes('allow-same-origin'); if (sameOrigin && sandboxAllowsSameOrigin && frame.contentDocument) roots.push(frame.contentDocument); }); } for (const element of seen) { if (isReady(element)) return 'media'; } return 'no_media'; })()"
end tell
"""#
    }

    private static func heliumJavaScriptCommandAppleScriptSource(command: MediaRemoteTransportCommand) -> String {
        let action = heliumJavaScriptAction(command: command)
        return #"""
tell application id "net.imput.helium"
    if (count of windows) = 0 then return "no_windows"
    return execute active tab of front window javascript "(() => { const command = '\#(action)'; const hasMediaSource = element => Boolean(element.currentSrc || element.src || element.querySelector('source')); const isReady = element => !element.ended && hasMediaSource(element); const isPlaying = element => !element.paused && !element.ended; const direct = Array.from(document.querySelectorAll('video,audio')).filter(isReady); const directPlaying = direct.filter(isPlaying); if (command === 'pause' && directPlaying.length > 0) { directPlaying.forEach(element => element.pause()); return 'paused'; } if (command === 'play' && directPlaying.length > 0) return 'already_playing'; if (command === 'playPause' && directPlaying.length > 0) { directPlaying.forEach(element => element.pause()); return 'paused'; } const collectDeepMedia = () => { const media = []; const seen = new Set(); const roots = [document]; for (let index = 0; index < roots.length; index += 1) { const root = roots[index]; root.querySelectorAll('video,audio').forEach(element => { if (!seen.has(element)) { seen.add(element); media.push(element); } }); root.querySelectorAll('*').forEach(element => { if (element.shadowRoot) roots.push(element.shadowRoot); }); root.querySelectorAll('iframe,frame').forEach(frame => { const source = frame.getAttribute('src') || ''; const sameOrigin = source === '' || source.startsWith('about:') || new URL(frame.src || source, location.href).origin === location.origin; const sandbox = frame.getAttribute('sandbox'); const sandboxAllowsSameOrigin = sandbox === null || sandbox.split(/\\s+/).includes('allow-same-origin'); if (sameOrigin && sandboxAllowsSameOrigin && frame.contentDocument) roots.push(frame.contentDocument); }); } return media; }; const deep = collectDeepMedia().filter(isReady); const deepPlaying = deep.filter(isPlaying); if (command === 'pause') { if (deepPlaying.length > 0) { deepPlaying.forEach(element => element.pause()); return 'paused'; } return direct.length + deep.length > 0 ? 'already_paused' : 'no_media'; } if (deepPlaying.length > 0) { if (command === 'play') return 'already_playing'; deepPlaying.forEach(element => element.pause()); return 'paused'; } const playable = deep.length > 0 ? deep : direct; const visibleArea = element => { const rect = element.getBoundingClientRect(); const view = element.ownerDocument.defaultView || window; const width = Math.max(0, Math.min(rect.right, view.innerWidth) - Math.max(rect.left, 0)); const height = Math.max(0, Math.min(rect.bottom, view.innerHeight) - Math.max(rect.top, 0)); return width * height; }; playable.sort((left, right) => visibleArea(right) - visibleArea(left) || ((right.videoWidth || 1) * (right.videoHeight || 1)) - ((left.videoWidth || 1) * (left.videoHeight || 1)) || right.duration - left.duration); const target = playable[0]; if (!target) return 'no_media'; target.play(); return target.paused ? 'play_requested' : 'playing'; })()"
end tell
"""#
    }

    private static func heliumJavaScriptAction(command: MediaRemoteTransportCommand) -> String {
        switch command {
        case .play:
            return "play"
        case .pause:
            return "pause"
        case .playPause:
            return "playPause"
        case .next, .previous:
            preconditionFailure("Helium JavaScript only supports play, pause, and play/pause.")
        }
    }
}
