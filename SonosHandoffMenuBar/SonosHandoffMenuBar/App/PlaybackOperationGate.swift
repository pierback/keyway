import Foundation
import SonosHandoffCore

struct PlaybackOperationTicket: Equatable, Sendable {
    let generation: Int
    let roomName: String
}

@MainActor
final class PlaybackOperationGate {
    private var volumeGeneration = 0
    private var transferGeneration = 0
    private var volumeTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?

    deinit {
        volumeTask?.cancel()
        transferTask?.cancel()
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

    func runTransfer(
        roomName: String,
        operation: @escaping @MainActor @Sendable (PlaybackOperationTicket) async -> Void
    ) {
        transferTask?.cancel()
        transferGeneration += 1
        let ticket = PlaybackOperationTicket(generation: transferGeneration, roomName: roomName)
        transferTask = Task { @MainActor in
            await operation(ticket)
        }
    }

    func isCurrentVolume(_ ticket: PlaybackOperationTicket, selectedRoomName: String?) -> Bool {
        ticket.generation == volumeGeneration && SonosRoomName.matches(ticket.roomName, selectedRoomName)
    }

    func isCurrentTransfer(_ ticket: PlaybackOperationTicket, loadingRoomName: String?) -> Bool {
        ticket.generation == transferGeneration && SonosRoomName.matches(ticket.roomName, loadingRoomName)
    }
}
