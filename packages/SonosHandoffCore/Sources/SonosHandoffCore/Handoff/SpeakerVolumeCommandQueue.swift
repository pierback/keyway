import Foundation

public enum SpeakerVolumeCommandQueueError: Error, Equatable, Sendable {
    case waitQueueFull
}

public actor SpeakerVolumeCommandQueue {
    public static let shared = SpeakerVolumeCommandQueue()

    private enum SlotGrant {
        case acquired
        case cancelled
        case queueFull
    }

    private struct OperationWaiter {
        let id: Int
        let continuation: CheckedContinuation<SlotGrant, Never>
    }

    private static let maxWaitingOperations = 32

    private var operationInFlight = false
    private var waiters: [OperationWaiter] = []
    private var pendingWaiterIDs: Set<Int> = []
    private var cancelledWaiterIDs: Set<Int> = []
    private var nextWaiterID = 0

    public init() {}

    public func volumeStatus(
        using volumeService: any SpeakerVolumeAdjusting,
        roomName: String
    ) async throws -> SpeakerVolumeStatus {
        try await run {
            try await volumeService.volumeStatus(roomName: roomName)
        }
    }

    public func setVolume(
        using volumeService: any SpeakerVolumeAdjusting,
        roomName: String,
        volume: Int
    ) async throws -> Int {
        try await run {
            try await volumeService.setVolume(roomName: roomName, volume: volume)
        }
    }

    public func volumeDown(
        using volumeService: any SpeakerVolumeAdjusting,
        roomName: String,
        step: Int
    ) async throws -> Int {
        try await run {
            try await volumeService.volumeDown(roomName: roomName, step: step)
        }
    }

    public func volumeUp(
        using volumeService: any SpeakerVolumeAdjusting,
        roomName: String,
        step: Int
    ) async throws -> Int {
        try await run {
            try await volumeService.volumeUp(roomName: roomName, step: step)
        }
    }

    public func toggleMute(
        using volumeService: any SpeakerVolumeAdjusting,
        roomName: String
    ) async throws -> Bool {
        try await run {
            try await volumeService.toggleMute(roomName: roomName)
        }
    }

    public func setMute(
        using volumeService: any SpeakerVolumeAdjusting,
        roomName: String,
        muted: Bool
    ) async throws -> Bool {
        try await run {
            try await volumeService.setMute(roomName: roomName, muted: muted)
        }
    }

    private func run<Result: Sendable>(
        _ operation: @Sendable @escaping () async throws -> Result
    ) async throws -> Result {
        switch await acquireOperationSlot() {
        case .acquired:
            break
        case .cancelled:
            throw CancellationError()
        case .queueFull:
            throw SpeakerVolumeCommandQueueError.waitQueueFull
        }

        defer {
            releaseOperationSlot()
        }

        guard !Task.isCancelled else {
            throw CancellationError()
        }

        return try await operation()
    }

    private func acquireOperationSlot() async -> SlotGrant {
        guard !Task.isCancelled else {
            return .cancelled
        }

        guard operationInFlight else {
            operationInFlight = true
            return .acquired
        }

        guard waiters.count < Self.maxWaitingOperations else {
            return .queueFull
        }

        nextWaiterID += 1
        let waiterID = nextWaiterID
        pendingWaiterIDs.insert(waiterID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil {
                    pendingWaiterIDs.remove(waiterID)
                    continuation.resume(returning: .cancelled)
                    return
                }

                waiters.append(OperationWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func releaseOperationSlot() {
        guard !waiters.isEmpty else {
            operationInFlight = false
            return
        }

        let waiter = waiters.removeFirst()
        pendingWaiterIDs.remove(waiter.id)
        waiter.continuation.resume(returning: .acquired)
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            if pendingWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
            return
        }

        let waiter = waiters.remove(at: index)
        pendingWaiterIDs.remove(id)
        waiter.continuation.resume(returning: .cancelled)
    }
}
