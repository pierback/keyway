import Foundation
import Testing
@testable import SonosHandoffCore

struct SpotifyVolumeMirrorQueueTests {
    @Test
    func coalescesIntermediateWritesWhileMirrorIsInFlight() async {
        let queue = SpotifyVolumeMirrorQueue()
        let recorder = VolumeMirrorRecorder()

        await queue.enqueue(roomName: "Port", volume: 10) { roomName, volume in
            await recorder.record(roomName: roomName, volume: volume)
        }
        await recorder.waitForFirstRecord()

        await queue.enqueue(roomName: "Port", volume: 20) { roomName, volume in
            await recorder.record(roomName: roomName, volume: volume)
        }
        await queue.enqueue(roomName: "Port", volume: 30) { roomName, volume in
            await recorder.record(roomName: roomName, volume: volume)
        }
        await queue.enqueue(roomName: "Port", volume: 40) { roomName, volume in
            await recorder.record(roomName: roomName, volume: volume)
        }

        await recorder.releaseFirstRecord()
        await queue.waitUntilIdle()

        let records = await recorder.records()
        #expect(records.map(\.volume) == [10, 40])
        #expect(records.map(\.roomName) == ["Port", "Port"])
    }
}

private struct VolumeMirrorRecord: Equatable, Sendable {
    let roomName: String
    let volume: Int
}

private actor VolumeMirrorRecorder {
    private var storedRecords: [VolumeMirrorRecord] = []
    private var firstRecordWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRecordRelease: CheckedContinuation<Void, Never>?

    func record(roomName: String, volume: Int) async {
        storedRecords.append(VolumeMirrorRecord(roomName: roomName, volume: volume))
        if storedRecords.count == 1 {
            let waiters = firstRecordWaiters
            firstRecordWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstRecordRelease = continuation
            }
        }
    }

    func waitForFirstRecord() async {
        guard storedRecords.isEmpty else {
            return
        }

        await withCheckedContinuation { continuation in
            firstRecordWaiters.append(continuation)
        }
    }

    func releaseFirstRecord() {
        firstRecordRelease?.resume()
        firstRecordRelease = nil
    }

    func records() -> [VolumeMirrorRecord] {
        storedRecords
    }
}
