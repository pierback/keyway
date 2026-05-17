import Foundation

enum SonosPlaybackReadiness: Equatable, Sendable {
    case transportStarted
    case spotifyConnectModeOnly
}

struct SonosTransferVerifier {
    private let soapClient: SonosSOAPClient
    private let activationDelayNanoseconds: UInt64
    private let activationPollAttempts: Int
    private let activationPollDelayNanoseconds: UInt64
    private let playbackPollAttempts: Int
    private let playbackPollDelayNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void

    private static let defaultActivationDelayNanoseconds: UInt64 = 1_000_000_000
    private static let defaultActivationPollAttempts = 1
    private static let defaultActivationPollDelayNanoseconds: UInt64 = 0
    private static let defaultPlaybackPollAttempts = 16
    private static let defaultPlaybackPollDelayNanoseconds: UInt64 = 350_000_000

    init(
        soapClient: SonosSOAPClient,
        activationDelayNanoseconds: UInt64 = Self.defaultActivationDelayNanoseconds,
        activationPollAttempts: Int = Self.defaultActivationPollAttempts,
        activationPollDelayNanoseconds: UInt64 = Self.defaultActivationPollDelayNanoseconds,
        playbackPollAttempts: Int = Self.defaultPlaybackPollAttempts,
        playbackPollDelayNanoseconds: UInt64 = Self.defaultPlaybackPollDelayNanoseconds,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        precondition(activationPollAttempts > 0, "activationPollAttempts must be positive")
        precondition(playbackPollAttempts > 0, "playbackPollAttempts must be positive")
        self.soapClient = soapClient
        self.activationDelayNanoseconds = activationDelayNanoseconds
        self.activationPollAttempts = activationPollAttempts
        self.activationPollDelayNanoseconds = activationPollDelayNanoseconds
        self.playbackPollAttempts = playbackPollAttempts
        self.playbackPollDelayNanoseconds = playbackPollDelayNanoseconds
        self.sleep = sleep
    }

    func waitForSpotifyConnectMode(on target: ConnectSonosTarget) async throws {
        try await sleep(activationDelayNanoseconds)

        var lastURI = ""
        for attempt in 0 ..< activationPollAttempts {
            lastURI = try await currentURI(on: target)
            if Self.isSpotifyConnectURI(lastURI) {
                return
            }

            if attempt + 1 < activationPollAttempts {
                try await sleep(activationPollDelayNanoseconds)
            }
        }

        throw ConnectHandoffError(.transferVerificationFailed, "\(target.roomName) did not enter Spotify Connect mode; CurrentURI=\(lastURI)")
    }

    func playAndVerifyReadiness(on target: ConnectSonosTarget) async throws -> SonosPlaybackReadiness {
        _ = try await soapClient.call(host: target.host, service: "AVTransport", action: "Play", path: "/MediaRenderer/AVTransport/Control", body: """
        <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>
        """)

        return try await waitForPlaybackOrSpotifyConnectReadiness(on: target)
    }

    private func waitForPlaybackOrSpotifyConnectReadiness(on target: ConnectSonosTarget) async throws -> SonosPlaybackReadiness {
        var lastState: String?
        for attempt in 0 ..< playbackPollAttempts {
            lastState = try await transportState(on: target)
            if lastState == "PLAYING" || lastState == "TRANSITIONING" {
                return .transportStarted
            }

            if attempt + 1 < playbackPollAttempts {
                try await sleep(playbackPollDelayNanoseconds)
            }
        }

        let currentURI = try await currentURI(on: target)
        guard Self.isSpotifyConnectURI(currentURI) else {
            throw ConnectHandoffError(.transferVerificationFailed, "\(target.roomName) left Spotify Connect mode; state=\(lastState ?? "unknown") CurrentURI=\(currentURI)")
        }

        return .spotifyConnectModeOnly
    }

    private func currentURI(on target: ConnectSonosTarget) async throws -> String {
        let mediaInfo = try await soapClient.call(host: target.host, service: "AVTransport", action: "GetMediaInfo", path: "/MediaRenderer/AVTransport/Control", body: """
        <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetMediaInfo>
        """)
        return SonosRuntimeSupport.xmlUnescape(SonosRuntimeSupport.firstMatch(#"<CurrentURI>([^<]*)</CurrentURI>"#, in: mediaInfo) ?? "")
    }

    private func transportState(on target: ConnectSonosTarget) async throws -> String? {
        let transportInfo = try await soapClient.call(host: target.host, service: "AVTransport", action: "GetTransportInfo", path: "/MediaRenderer/AVTransport/Control", body: """
        <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo>
        """)
        return SonosRuntimeSupport.firstMatch(#"<CurrentTransportState>([^<]*)</CurrentTransportState>"#, in: transportInfo)
    }

    private static func isSpotifyConnectURI(_ currentURI: String) -> Bool {
        currentURI.hasPrefix("x-sonos-vli:") && currentURI.contains("spotify:")
    }
}
