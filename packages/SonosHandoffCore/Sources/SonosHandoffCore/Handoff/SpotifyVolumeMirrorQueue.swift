import Foundation

actor SpotifyVolumeMirrorQueue {
    typealias MirrorOperation = @Sendable (_ roomName: String, _ volume: Int) async -> Void

    private struct PendingMirror: Sendable {
        let roomName: String
        let volume: Int
    }

    private let operation: MirrorOperation
    private var running = false
    private var pendingMirror: PendingMirror?

    init(operation: @escaping MirrorOperation) {
        self.operation = operation
    }

    func enqueue(roomName: String, volume: Int) {
        let mirror = PendingMirror(roomName: roomName, volume: volume)
        guard running else {
            running = true
            run(mirror)
            return
        }

        pendingMirror = mirror
    }

    private func run(_ mirror: PendingMirror) {
        let operation = operation
        Task.detached(priority: .utility) {
            await operation(mirror.roomName, mirror.volume)
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
    }
}
