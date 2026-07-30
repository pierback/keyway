import Foundation
import SonosHandoffCore

struct PlaybackOperationTicket: Equatable, Sendable {
    let generation: Int
    let roomName: String
}

struct PlaybackTransactionTicket: Equatable, Sendable {
    let authorityTicket: PlaybackAuthorityTicket
    let roomName: String
}

@MainActor
final class PlaybackOperationGate {
    private var authority = PlaybackOperationAuthority()
    private var volumeGeneration = 0
    private var volumeTask: Task<Void, Never>?
    private var transactionTask: Task<Void, Never>?
    private var refreshObservations: (() -> Void)?

    deinit {
        volumeTask?.cancel()
        transactionTask?.cancel()
    }

    func startRuntime(refreshObservations: @escaping () -> Void) {
        authority.start()
        self.refreshObservations = refreshObservations
    }

    func stopRuntime() {
        transactionTask?.cancel()
        transactionTask = nil
        cancelVolume()
        authority.stop()
        refreshObservations = nil
    }

    func beginObservation() -> PlaybackAuthorityTicket? {
        authority.beginObservation()
    }

    func isCurrentObservation(_ ticket: PlaybackAuthorityTicket) -> Bool {
        !Task.isCancelled && authority.canCommitObservation(ticket)
    }

    func runVolume(
        roomName: String,
        operation: @escaping @MainActor @Sendable (PlaybackOperationTicket) async -> Void
    ) {
        volumeTask?.cancel()
        volumeGeneration += 1
        let ticket = PlaybackOperationTicket(generation: volumeGeneration, roomName: roomName)
        volumeTask = Task { @MainActor in
            await operation(ticket)
        }
    }

    func cancelVolume() {
        volumeTask?.cancel()
        volumeTask = nil
        volumeGeneration += 1
    }

    @discardableResult
    func runTransaction(
        roomName: String,
        operation: @escaping @MainActor @Sendable (PlaybackTransactionTicket) async -> Void
    ) -> Bool {
        guard let ticket = beginTransaction(roomName: roomName) else {
            return false
        }

        transactionTask = Task { @MainActor [weak self] in
            await operation(ticket)
            self?.endTransaction(ticket)
        }
        return true
    }

    func beginTransaction(roomName: String) -> PlaybackTransactionTicket? {
        guard let ticket = authority.beginTransaction() else {
            return nil
        }

        return PlaybackTransactionTicket(authorityTicket: ticket, roomName: roomName)
    }

    func endTransaction(_ ticket: PlaybackTransactionTicket) {
        guard authority.endTransaction(ticket.authorityTicket) else {
            return
        }

        transactionTask = nil
        refreshObservations?()
    }

    func cancelTransaction() {
        transactionTask?.cancel()
        transactionTask = nil
        authority.cancelTransaction()
    }

    func isCurrentVolume(_ ticket: PlaybackOperationTicket, selectedRoomName: String?) -> Bool {
        !Task.isCancelled
            && ticket.generation == volumeGeneration
            && SonosRoomName.matches(ticket.roomName, selectedRoomName)
    }

    func isCurrentTransaction(_ ticket: PlaybackTransactionTicket, roomName: String? = nil) -> Bool {
        !Task.isCancelled
            && authority.canCommitTransaction(ticket.authorityTicket)
            && (roomName == nil || SonosRoomName.matches(ticket.roomName, roomName))
    }
}
