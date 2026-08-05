import Foundation

struct ChromiumBrowserExtensionSnapshotEnvelope: Decodable {
    let protocolVersion: Int
    let profileGuid: String
    let connectionID: String
    let connectionGeneration: UInt64
    let epoch: Int?
    let resumed: Bool?
    let browserProcessIdentifier: Int
}

struct ChromiumBrowserExtensionCommandResultEnvelope: Decodable {
    let protocolVersion: Int
    let requestID: String
    let connectionID: String
    let connectionGeneration: UInt64
}

struct ChromiumBrowserExtensionFocusResultEnvelope: Decodable {
    let protocolVersion: Int
    let requestID: String
    let connectionID: String
    let connectionGeneration: UInt64
}

struct ChromiumBrowserExtensionPendingCommand {
    let startedAt: TimeInterval
    let commandName: String
    let targetID: String
    let connectionID: String
    let connectionGeneration: UInt64
    let resultHandler: (MediaRemoteCommandResultEvent) -> Void
}

struct ChromiumBrowserExtensionPendingFocus {
    let startedAt: TimeInterval
    let targetID: String
    let connectionID: String
    let connectionGeneration: UInt64
    let resultHandler: (SourceFocusResult) -> Void
}

struct ChromiumBrowserExtensionCommandPayload: Encodable {
    let type: String
    let protocolVersion: Int
    let requestID: String
    let targetID: String
    let command: String
    let volumeDelta: Double?
    let connectionID: String
}

struct ChromiumBrowserExtensionFocusPayload: Encodable {
    let type: String
    let protocolVersion: Int
    let requestID: String
    let targetID: String
    let connectionID: String
}

struct ChromiumBrowserExtensionSnapshotPayload: Decodable {
    let protocolVersion: Int
    let profileGuid: String
    let connectionID: String
    let targets: [ChromiumBrowserExtensionTargetPayload]
}

struct ChromiumBrowserExtensionTargetPayload: Decodable {
    let id: String
    let browser: String
    let browserFamily: String?
    let browserDisplayName: String?
    let browserBundleIdentifier: String?
    let browserProcessIdentifier: Int
    let url: String
    let pageTitle: String
    let title: String
    let artist: String
    let album: String?
    let playing: Bool
    let muted: Bool?
    let duration: Double?
    let elapsedTime: Double?
    let supportedCommands: [String]

    var mediaRemoteTarget: MediaRemoteTarget {
        MediaRemoteTarget(
            id: id,
            bundleIdentifier: browserBundleIdentifier ?? ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            parentBundleIdentifier: "",
            displayName: ChromiumBrowserExtensionTransport.targetDisplayName(
                browser: browserDisplayName ?? browser,
                pageTitle: pageTitle
            ),
            pid: browserProcessIdentifier,
            title: title.isEmpty ? pageTitle : title,
            artist: artist.isEmpty ? url : artist,
            album: album ?? pageTitle,
            playbackRate: playing ? "1" : "0",
            mediaType: ChromiumBrowserExtensionTransport.mediaType,
            artworkBase64: nil,
            duration: duration,
            elapsedTime: elapsedTime,
            elapsedTimestamp: Date().timeIntervalSince1970,
            supportedCommands: supportedCommands.compactMap(MediaRemoteTransportCommand.init(rawValue:)),
            muted: muted,
            browserFamily: browserFamily,
            browserDisplayName: browserDisplayName,
            browserBundleIdentifier: browserBundleIdentifier
        )
    }
}
