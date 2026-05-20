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
            return details.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Could not transfer to \(roomName)."
        }
    }
}

@MainActor
final class PlaybackTransferActionController {
    private let roomHandoffService: any RoomHandoffPerforming
    private let logger = os.Logger(subsystem: "com.fpieringer.Keyway", category: "Transfer")

    init(environment: AppEnvironment) {
        self.roomHandoffService = environment.roomHandoffService
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
