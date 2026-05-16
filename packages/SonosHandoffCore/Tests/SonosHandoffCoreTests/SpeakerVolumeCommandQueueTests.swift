import Foundation
import Testing
@testable import SonosHandoffCore

struct SpeakerVolumeCommandQueueTests {
    @Test
    func runsVolumeCommandsSerially() async throws {
        let queue = SpeakerVolumeCommandQueue()
        let volumeService = BlockingSpeakerVolumeAdjuster()

        let first = Task {
            try await queue.volumeDown(using: volumeService, roomName: "Port", step: 5)
        }
        await volumeService.waitForCallCount(1)

        let second = Task {
            try await queue.volumeUp(using: volumeService, roomName: "Port", step: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await volumeService.calls() == [.volumeDown(roomName: "Port", step: 5)])

        await volumeService.releaseNext()
        #expect(try await first.value == 10)

        await volumeService.waitForCallCount(2)
        #expect(await volumeService.maxActiveCount() == 1)

        await volumeService.releaseNext()
        #expect(try await second.value == 20)
        #expect(await volumeService.calls() == [
            .volumeDown(roomName: "Port", step: 5),
            .volumeUp(roomName: "Port", step: 5),
        ])
    }

    @Test
    func cancelledWaitingCommandDoesNotRunAfterSlotReleases() async throws {
        let queue = SpeakerVolumeCommandQueue()
        let volumeService = BlockingSpeakerVolumeAdjuster()

        let first = Task {
            try await queue.volumeDown(using: volumeService, roomName: "Port", step: 5)
        }
        await volumeService.waitForCallCount(1)

        let second = Task {
            try await queue.volumeUp(using: volumeService, roomName: "Port", step: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        second.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)

        await volumeService.releaseNext()
        #expect(try await first.value == 10)

        do {
            _ = try await second.value
            Issue.record("Expected waiting command cancellation to throw")
        } catch is CancellationError {
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await volumeService.calls() == [.volumeDown(roomName: "Port", step: 5)])
    }
}

private enum BlockingVolumeCall: Equatable, Sendable {
    case status(roomName: String)
    case setVolume(roomName: String, volume: Int)
    case volumeDown(roomName: String, step: Int)
    case volumeUp(roomName: String, step: Int)
    case toggleMute(roomName: String)
}

private actor BlockingSpeakerVolumeAdjuster: SpeakerVolumeAdjusting {
    private var storedCalls: [BlockingVolumeCall] = []
    private var activeCount = 0
    private var storedMaxActiveCount = 0
    private var callWaiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        await record(.status(roomName: roomName))
        return SpeakerVolumeStatus(roomName: roomName, host: "port.local", volume: 10, outputFixed: false, muted: false)
    }

    func setVolume(roomName: String, volume: Int) async throws -> Int {
        await record(.setVolume(roomName: roomName, volume: volume))
        return volume
    }

    func volumeDown(roomName: String, step: Int) async throws -> Int {
        await record(.volumeDown(roomName: roomName, step: step))
        return 10
    }

    func volumeUp(roomName: String, step: Int) async throws -> Int {
        await record(.volumeUp(roomName: roomName, step: step))
        return 20
    }

    func toggleMute(roomName: String) async throws -> Bool {
        await record(.toggleMute(roomName: roomName))
        return true
    }

    func waitForCallCount(_ count: Int) async {
        guard storedCalls.count < count else {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiters.append((minimumCount: count, continuation: continuation))
        }
    }

    func releaseNext() {
        precondition(!releaseWaiters.isEmpty, "No blocked volume command is waiting for release")
        releaseWaiters.removeFirst().resume()
    }

    func calls() -> [BlockingVolumeCall] {
        storedCalls
    }

    func maxActiveCount() -> Int {
        storedMaxActiveCount
    }

    private func record(_ call: BlockingVolumeCall) async {
        activeCount += 1
        storedMaxActiveCount = max(storedMaxActiveCount, activeCount)
        storedCalls.append(call)
        resumeSatisfiedCallWaiters()

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        activeCount -= 1
    }

    private func resumeSatisfiedCallWaiters() {
        let satisfied = callWaiters.filter { storedCalls.count >= $0.minimumCount }
        callWaiters.removeAll { storedCalls.count >= $0.minimumCount }
        satisfied.forEach { $0.continuation.resume() }
    }
}
