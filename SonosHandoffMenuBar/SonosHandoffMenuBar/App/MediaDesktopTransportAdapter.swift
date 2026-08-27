import ApplicationServices
import Foundation

@MainActor
final class MediaDesktopTransportAdapter {
    nonisolated private static let spotifyBundleIdentifier = "com.spotify.client"
    nonisolated private static let spotifyAppleEventBackend = "spotify_apple_event"
    nonisolated private static let spotifyCommandQueue = DispatchQueue(
        label: "com.fpieringer.Keyway.spotify-apple-events",
        qos: .userInitiated
    )
    private var spotifySubmissionID: UUID?

    func backendName(for target: MediaRemoteTarget) -> String? {
        guard !ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        guard Self.isSpotifyTarget(target) else {
            return nil
        }

        return Self.spotifyAppleEventBackend
    }

    func submit(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        onResult: @escaping @MainActor @Sendable (MediaRemoteCommandResultEvent) -> Void
    ) -> String? {
        guard let backend = backendName(for: target) else {
            return nil
        }

        submitSpotifyCommand(command: command, target: target, onResult: onResult)
        return backend
    }

    private func submitSpotifyCommand(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        onResult: @escaping @MainActor @Sendable (MediaRemoteCommandResultEvent) -> Void
    ) {
        let submissionID = UUID()
        spotifySubmissionID = submissionID
        Self.spotifyCommandQueue.async { [targetID = target.id] in
            let eventID = Self.spotifyAppleEventID(command: command)
            let playbackStopped = Self.spotifyPlaybackState() == Self.fourCharCode("kPSS")
            let status = playbackStopped
                ? noErr
                : Self.sendAppleEvent(
                    bundleIdentifier: Self.spotifyBundleIdentifier,
                    eventClass: "spfy",
                    eventID: eventID
                )
            let result = MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: UUID().uuidString,
                targetID: targetID,
                command: command.rawValue,
                ok: !playbackStopped && status == noErr,
                message: playbackStopped
                    ? "Spotify has no current desktop track."
                    : status == noErr
                        ? "submitted Spotify AppleEvent command event=\(eventID)"
                        : "Spotify AppleEvent failed status=\(status)",
                backend: Self.spotifyAppleEventBackend
            )
            Task { @MainActor [weak self] in
                guard let self, self.spotifySubmissionID == submissionID else {
                    return
                }
                self.spotifySubmissionID = nil
                onResult(result)
            }
        }
    }

    private static func isSpotifyTarget(_ target: MediaRemoteTarget) -> Bool {
        target.bundleIdentifier == spotifyBundleIdentifier || target.parentBundleIdentifier == spotifyBundleIdentifier
    }

    nonisolated private static func spotifyAppleEventID(command: MediaRemoteTransportCommand) -> String {
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

    nonisolated private static func spotifyPlaybackState() -> OSType? {
        var propertyRecord = AERecord()
        guard AECreateList(nil, 0, true, &propertyRecord) == noErr else {
            return nil
        }
        defer { _ = AEDisposeDesc(&propertyRecord) }

        var desiredClass = OSType(typeProperty)
        guard AEPutParamPtr(
            &propertyRecord,
            AEKeyword(keyAEDesiredClass),
            DescType(typeType),
            &desiredClass,
            MemoryLayout<OSType>.size
        ) == noErr else {
            return nil
        }
        var keyForm = OSType(formPropertyID)
        guard AEPutParamPtr(
            &propertyRecord,
            AEKeyword(keyAEKeyForm),
            DescType(typeEnumerated),
            &keyForm,
            MemoryLayout<OSType>.size
        ) == noErr else {
            return nil
        }
        var keyData = fourCharCode("pPlS")
        guard AEPutParamPtr(
            &propertyRecord,
            AEKeyword(keyAEKeyData),
            DescType(typeType),
            &keyData,
            MemoryLayout<OSType>.size
        ) == noErr,
        AEPutParamPtr(
            &propertyRecord,
            AEKeyword(keyAEContainer),
            DescType(typeNull),
            nil,
            0
        ) == noErr else {
            return nil
        }

        var propertySpecifier = AEDesc()
        guard AECoerceDesc(
            &propertyRecord,
            DescType(typeObjectSpecifier),
            &propertySpecifier
        ) == noErr else {
            return nil
        }
        defer { _ = AEDisposeDesc(&propertySpecifier) }

        var target = AEAddressDesc()
        let targetStatus = spotifyBundleIdentifier.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                spotifyBundleIdentifier.lengthOfBytes(using: .utf8),
                &target
            )
        }
        guard targetStatus == noErr else {
            return nil
        }
        defer { _ = AEDisposeDesc(&target) }

        var event = AppleEvent()
        guard AECreateAppleEvent(
            AEEventClass(kAECoreSuite),
            AEEventID(kAEGetData),
            &target,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        ) == noErr else {
            return nil
        }
        defer { _ = AEDisposeDesc(&event) }
        guard AEPutParamDesc(
            &event,
            AEKeyword(keyDirectObject),
            &propertySpecifier
        ) == noErr else {
            return nil
        }

        var reply = AppleEvent()
        guard AESendMessage(
            &event,
            &reply,
            AESendMode(kAEWaitReply | kAECanInteract | kAECanSwitchLayer),
            60
        ) == noErr else {
            return nil
        }
        defer { _ = AEDisposeDesc(&reply) }

        var state: OSType = 0
        var actualType: DescType = 0
        var actualSize = 0
        guard AEGetParamPtr(
            &reply,
            AEKeyword(keyDirectObject),
            DescType(typeEnumerated),
            &actualType,
            &state,
            MemoryLayout<OSType>.size,
            &actualSize
        ) == noErr,
        actualSize == MemoryLayout<OSType>.size else {
            return nil
        }
        return state
    }

    nonisolated private static func sendAppleEvent(
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
        defer { _ = AEDisposeDesc(&target) }

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
        defer { _ = AEDisposeDesc(&event) }

        return AESendMessage(
            &event,
            nil,
            AESendMode(kAENoReply | kAECanInteract | kAECanSwitchLayer),
            kAEDefaultTimeout
        )
    }

    nonisolated private static func fourCharCode(_ value: String) -> OSType {
        let bytes = Array(value.utf8)
        precondition(bytes.count == 4, "AppleEvent codes must be exactly four bytes.")
        var result: UInt32 = 0
        for byte in bytes {
            result = (result << 8) + UInt32(byte)
        }
        return result
    }
}
