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
        let ticket = beginVolume(roomName: roomName)
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
        let ticket = beginTransfer(roomName: roomName)
        transferTask = Task { @MainActor in
            await operation(ticket)
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        transferGeneration += 1
    }

    private func beginVolume(roomName: String) -> PlaybackOperationTicket {
        volumeGeneration += 1
        return PlaybackOperationTicket(generation: volumeGeneration, roomName: roomName)
    }

    func isCurrentVolume(_ ticket: PlaybackOperationTicket, selectedRoomName: String?) -> Bool {
        ticket.generation == volumeGeneration && Self.roomNamesMatch(ticket.roomName, selectedRoomName)
    }

    private func beginTransfer(roomName: String) -> PlaybackOperationTicket {
        transferGeneration += 1
        return PlaybackOperationTicket(generation: transferGeneration, roomName: roomName)
    }

    func isCurrentTransfer(_ ticket: PlaybackOperationTicket, loadingRoomName: String?) -> Bool {
        ticket.generation == transferGeneration && Self.roomNamesMatch(ticket.roomName, loadingRoomName)
    }

    private static func roomNamesMatch(_ lhs: String, _ rhs: String?) -> Bool {
        SonosRoomName.matches(lhs, rhs)
    }
}
