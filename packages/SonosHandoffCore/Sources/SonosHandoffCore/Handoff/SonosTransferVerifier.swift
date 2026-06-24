import Foundation

enum SonosPlaybackReadiness: Equatable, Sendable {
    case transportStarted
    case spotifyConnectModeOnly
}

struct SonosTransferVerifierTiming: Equatable, Sendable {
    static let full = SonosTransferVerifierTiming(
        activationDelayNanoseconds: 1_000_000_000,
        activationPollAttempts: 1,
        activationPollDelayNanoseconds: 0,
        playbackPollAttempts: 16,
        playbackPollDelayNanoseconds: 350_000_000
    )

    static let coordinatorMigration = SonosTransferVerifierTiming(
        activationDelayNanoseconds: 250_000_000,
        activationPollAttempts: 8,
        activationPollDelayNanoseconds: 150_000_000,
        playbackPollAttempts: 4,
        playbackPollDelayNanoseconds: 150_000_000
    )

    static let connectOnly = SonosTransferVerifierTiming(
        activationDelayNanoseconds: 250_000_000,
        activationPollAttempts: 8,
        activationPollDelayNanoseconds: 150_000_000,
        playbackPollAttempts: 1,
        playbackPollDelayNanoseconds: 0
    )

    let activationDelayNanoseconds: UInt64
    let activationPollAttempts: Int
    let activationPollDelayNanoseconds: UInt64
    let playbackPollAttempts: Int
    let playbackPollDelayNanoseconds: UInt64

    init(
        activationDelayNanoseconds: UInt64,
        activationPollAttempts: Int,
        activationPollDelayNanoseconds: UInt64,
        playbackPollAttempts: Int,
        playbackPollDelayNanoseconds: UInt64
    ) {
        precondition(activationPollAttempts > 0, "activationPollAttempts must be positive")
        precondition(playbackPollAttempts > 0, "playbackPollAttempts must be positive")
        self.activationDelayNanoseconds = activationDelayNanoseconds
        self.activationPollAttempts = activationPollAttempts
        self.activationPollDelayNanoseconds = activationPollDelayNanoseconds
        self.playbackPollAttempts = playbackPollAttempts
        self.playbackPollDelayNanoseconds = playbackPollDelayNanoseconds
    }

    var maximumScheduledDelayNanoseconds: UInt64 {
        activationDelayNanoseconds
            + delayBetweenAttempts(count: activationPollAttempts, delayNanoseconds: activationPollDelayNanoseconds)
            + delayBetweenAttempts(count: playbackPollAttempts, delayNanoseconds: playbackPollDelayNanoseconds)
    }

    private func delayBetweenAttempts(count: Int, delayNanoseconds: UInt64) -> UInt64 {
        UInt64(count - 1) * delayNanoseconds
    }
}

struct SonosTransferVerifier {
    private let soapClient: SonosSOAPClient
    private let timing: SonosTransferVerifierTiming
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        soapClient: SonosSOAPClient,
        timing: SonosTransferVerifierTiming = .full,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.soapClient = soapClient
        self.timing = timing
        self.sleep = sleep
    }

    func waitForSpotifyConnectMode(on target: ConnectSonosTarget) async throws {
        try await sleep(timing.activationDelayNanoseconds)

        var lastURI = ""
        for attempt in 0 ..< timing.activationPollAttempts {
            lastURI = try await currentURI(on: target)
            if Self.isSpotifyConnectURI(lastURI) {
                return
            }

            if attempt + 1 < timing.activationPollAttempts {
                try await sleep(timing.activationPollDelayNanoseconds)
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
        for attempt in 0 ..< timing.playbackPollAttempts {
            lastState = try await transportState(on: target)
            if lastState == "PLAYING" || lastState == "TRANSITIONING" {
                return .transportStarted
            }

            if attempt + 1 < timing.playbackPollAttempts {
                try await sleep(timing.playbackPollDelayNanoseconds)
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
