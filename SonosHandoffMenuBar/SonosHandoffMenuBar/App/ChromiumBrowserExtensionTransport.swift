import Foundation

enum ChromiumBrowserExtensionTransport {
    static let backendName = "chromium_extension"
    static let mediaType = "chromium_extension"
    static let protocolVersion = 4
    static let targetIDPrefix = "chromium-tab:"
    static let nativeMessagingHostName = "com.fpieringer.keyway.chromium"
    static let extensionID = "gmdpkggbaohimgacbclndlfjghgcbael"
    static let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
    static let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
    static let focusResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.focusResult")
    static let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")
    private static let browserFamilyIdentityMatchers: [(family: String, keywords: [String])] = [
        ("helium", ["helium"]),
        ("arc", ["arc"]),
        ("brave", ["brave"]),
        ("edge", ["edge", "microsoft"]),
        ("opera", ["opera"]),
        ("vivaldi", ["vivaldi"]),
        ("chromium", ["chromium"]),
        ("chrome", ["chrome", "google"]),
    ]

    static func isTarget(_ target: MediaRemoteTarget) -> Bool {
        target.mediaType == mediaType || target.id.hasPrefix(targetIDPrefix)
    }

    static func profileGuid(targetID: String) -> String? {
        let parts = targetID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "chromium-tab" else {
            return nil
        }
        return String(parts[1])
    }

    static func browserFamily(target: MediaRemoteTarget) -> String? {
        guard isTarget(target) else {
            return nil
        }
        return target.browserFamily?.lowercased()
    }

    static func legacyBrowserFamily(target: MediaRemoteTarget) -> String? {
        guard !isTarget(target), target.isChromiumBrowserLike else {
            return nil
        }

        let identities = [target.bundleIdentifier, target.parentBundleIdentifier, target.displayName].map { $0.lowercased() }
        return browserFamily(identities: identities)
    }

    static func shadowsLegacyTarget(extensionTarget: MediaRemoteTarget, legacyTarget: MediaRemoteTarget) -> Bool {
        guard isTarget(extensionTarget),
              !isTarget(legacyTarget),
              legacyTarget.isChromiumBrowserLike,
              let extensionFamily = browserFamily(target: extensionTarget),
              let legacyFamily = legacyBrowserFamily(target: legacyTarget)
        else {
            return false
        }
        return extensionFamily == legacyFamily
    }

    private static func browserFamily(identities: [String]) -> String? {
        for matcher in browserFamilyIdentityMatchers
            where identities.contains(where: { identity in matcher.keywords.contains { identity.contains($0) } }) {
            return matcher.family
        }
        return nil
    }

    static func targetDisplayName(browser: String, pageTitle: String) -> String {
        let trimmedBrowser = browser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPageTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedBrowser.isEmpty {
            return trimmedPageTitle.isEmpty ? "Chromium" : trimmedPageTitle
        }
        if trimmedPageTitle.isEmpty {
            return trimmedBrowser
        }
        return "\(trimmedBrowser) - \(trimmedPageTitle)"
    }

    static func supports(command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> Bool {
        guard isTarget(target) else {
            return false
        }

        switch command {
        case .play, .pause, .playPause:
            return true
        case .next, .previous:
            return target.supportedCommands?.contains(command) == true
        }
    }

    static func unsupportedResult(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: false,
            message: "\(command.displayName) is not supported for Chromium extension targets.",
            backend: backendName,
            unsupported: true
        )
    }

    static func disconnectedResult(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: false,
            message: "Chromium extension is disconnected.",
            backend: backendName
        )
    }
}

enum ChromiumBrowserAudioCommand: Sendable {
    case mute
    case volumeDelta(Double)

    var rawValue: String {
        switch self {
        case .mute:
            return "mute"
        case .volumeDelta:
            return "volumeDelta"
        }
    }

    var displayName: String {
        switch self {
        case .mute:
            return "Mute"
        case .volumeDelta:
            return "Volume"
        }
    }

    var volumeDelta: Double? {
        switch self {
        case .mute:
            return nil
        case .volumeDelta(let delta):
            return delta
        }
    }
}
