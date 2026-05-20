import Foundation

@MainActor
final class PlaybackSliderCommitter {
    typealias RoomStillSelected = @MainActor @Sendable (_ roomName: String) -> Bool
    typealias Commit = @MainActor @Sendable (_ roomName: String, _ desiredVolume: Int) -> Void

    private var task: Task<Void, Never>?
    private(set) var isEditing = false

    private static let debounceNanoseconds: UInt64 = 120_000_000

    deinit {
        task?.cancel()
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(
        roomName: String,
        desiredVolume: Int,
        roomStillSelected: @escaping RoomStillSelected,
        commit: @escaping Commit
    ) {
        cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled, roomStillSelected(roomName) else {
                return
            }

            commit(roomName, desiredVolume)
        }
    }
}
