import Foundation

enum SonosPlaybackReadiness: Equatable, Sendable {
    case transportStarted
    case spotifyConnectModeOnly
}

struct SonosTransferVerifier {
    private let soapClient: SonosSOAPClient
    private let activationDelayNanoseconds: UInt64
    private let playbackPollAttempts: Int
    private let playbackPollDelayNanoseconds: UInt64

    private static let defaultActivationDelayNanoseconds: UInt64 = 1_000_000_000
    private static let defaultPlaybackPollAttempts = 16
    private static let defaultPlaybackPollDelayNanoseconds: UInt64 = 350_000_000

    init(
        soapClient: SonosSOAPClient,
        activationDelayNanoseconds: UInt64 = Self.defaultActivationDelayNanoseconds,
        playbackPollAttempts: Int = Self.defaultPlaybackPollAttempts,
        playbackPollDelayNanoseconds: UInt64 = Self.defaultPlaybackPollDelayNanoseconds
    ) {
        precondition(playbackPollAttempts > 0, "playbackPollAttempts must be positive")
        self.soapClient = soapClient
        self.activationDelayNanoseconds = activationDelayNanoseconds
        self.playbackPollAttempts = playbackPollAttempts
        self.playbackPollDelayNanoseconds = playbackPollDelayNanoseconds
    }

    func waitForSpotifyConnectMode(on target: ConnectSonosTarget) async throws {
        try await Task.sleep(nanoseconds: activationDelayNanoseconds)

        let currentURI = try await currentURI(on: target)
        guard Self.isSpotifyConnectURI(currentURI) else {
            throw ConnectHandoffError(.transferVerificationFailed, "\(target.roomName) did not enter Spotify Connect mode; CurrentURI=\(currentURI)")
        }
    }

    func playAndVerifyReadiness(on target: ConnectSonosTarget) async throws -> SonosPlaybackReadiness {
        _ = try await soapClient.call(host: target.host, service: "AVTransport", action: "Play", path: "/MediaRenderer/AVTransport/Control", body: """
        <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>
        """)

        return try await waitForPlaybackOrSpotifyConnectReadiness(on: target)
    }

    private func waitForPlaybackOrSpotifyConnectReadiness(on target: ConnectSonosTarget) async throws -> SonosPlaybackReadiness {
        var lastState: String?
        for _ in 0 ..< playbackPollAttempts {
            lastState = try await transportState(on: target)
            if lastState == "PLAYING" || lastState == "TRANSITIONING" {
                return .transportStarted
            }

            try await Task.sleep(nanoseconds: playbackPollDelayNanoseconds)
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
