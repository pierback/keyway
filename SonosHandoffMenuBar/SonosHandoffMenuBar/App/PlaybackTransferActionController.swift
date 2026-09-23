import Foundation
import os
import SonosHandoffCore

struct PlaybackTransferOutcome: Sendable {
    let roomName: String
    let result: TransferResult

    var failureMessage: String {
        switch result {
        case .success:
            return ""
        case .failure(_, let details):
            let details = details.trimmingCharacters(in: .whitespacesAndNewlines)

            return details.isEmpty ? "Could not transfer to \(roomName)." : details
        }
    }
}

@MainActor
final class PlaybackTransferActionController {
    private let roomHandoffService: any RoomHandoffPerforming
    private let logger = os.Logger(subsystem: "com.fpieringer.Keyway", category: "Transfer")

    init(roomHandoffService: any RoomHandoffPerforming) {
        self.roomHandoffService = roomHandoffService
    }

    func transfer(to speaker: SonosSpeaker, verification: RoomHandoffVerificationMode = .full) async -> PlaybackTransferOutcome {
        let roomName = speaker.roomName
        logger.info("SonosHandoffTransfer state=started room=\(roomName, privacy: .public) host=\(speaker.host, privacy: .public)")

        let result = await roomHandoffService.transfer(toRoomName: roomName, verification: verification)
        switch result {
        case .success:
            logger.info("SonosHandoffTransfer state=succeeded room=\(roomName, privacy: .public)")
        case .failure(let code, let details):
            logger.error("SonosHandoffTransfer state=failed room=\(roomName, privacy: .public) code=\(code.rawValue, privacy: .public) details=\(details, privacy: .public)")
        }

        return PlaybackTransferOutcome(roomName: roomName, result: result)
    }

    /// The Spotify Connect device name of this Mac's Spotify app, if Spotify currently lists it.
    static func localSpotifyComputerPlaybackDeviceName(
        using activePlaybackObserver: any SpotifyActivePlaybackObserving
    ) async throws -> String? {
        try await activePlaybackObserver.availablePlaybackDevices().first { device in
            !device.isRestricted && isLocalSpotifyComputer(name: device.name, type: device.type)
        }?.name
    }

    static func isLocalSpotifyComputer(name: String, type: String) -> Bool {
        type.caseInsensitiveCompare("Computer") == .orderedSame
            && localSpotifyComputerDeviceNames().contains {
                normalizedSpotifyDeviceName($0) == normalizedSpotifyDeviceName(name)
            }
    }

    private static func localSpotifyComputerDeviceNames() -> [String] {
        let host = Host.current()
        let hostName = ProcessInfo.processInfo.hostName
        let rawCandidates = [
            host.localizedName,
            host.name,
            hostName,
            hostName.split(separator: ".").first.map(String.init),
        ]
        var seenNames = Set<String>()
        return rawCandidates.compactMap { candidate in
            guard let name = SonosRoomName.normalized(candidate) else {
                return nil
            }
            guard seenNames.insert(normalizedSpotifyDeviceName(name)).inserted else {
                return nil
            }
            return name
        }
    }

    private static func normalizedSpotifyDeviceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }
}
