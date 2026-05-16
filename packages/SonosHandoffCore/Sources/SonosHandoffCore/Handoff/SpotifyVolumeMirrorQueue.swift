import Foundation

actor SpotifyVolumeMirrorQueue {
    typealias MirrorOperation = @Sendable (_ roomName: String, _ volume: Int) async -> Void

    private struct PendingMirror: Sendable {
        let roomName: String
        let volume: Int
        let operation: MirrorOperation
    }

    private var running = false
    private var pendingMirror: PendingMirror?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(roomName: String, volume: Int, operation: @escaping MirrorOperation) {
        let mirror = PendingMirror(roomName: roomName, volume: volume, operation: operation)
        guard running else {
            running = true
            run(mirror)
            return
        }

        pendingMirror = mirror
    }

    func waitUntilIdle() async {
        guard running || pendingMirror != nil else {
            return
        }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func run(_ mirror: PendingMirror) {
        Task.detached(priority: .utility) {
            await mirror.operation(mirror.roomName, mirror.volume)
            await self.completeCurrentMirror()
        }
    }

    private func completeCurrentMirror() {
        if let nextMirror = pendingMirror {
            pendingMirror = nil
            run(nextMirror)
            return
        }

        running = false
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
