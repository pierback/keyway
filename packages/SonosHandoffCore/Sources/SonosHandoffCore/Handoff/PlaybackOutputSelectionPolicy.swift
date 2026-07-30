import Foundation

public struct PlaybackOutputSelectionPolicy: Sendable {
    public enum UpdateSource: Sendable {
        case activePlaybackObservation
        case directoryRefresh
        case userSelection
        case playbackTransaction
        case reset
    }

    public private(set) var roomName: String?
    private var hasUserSelection = false

    public init() {}

    @discardableResult
    public mutating func update(roomName: String?, source: UpdateSource) -> Bool {
        let roomName = SonosRoomName.normalized(roomName)

        switch source {
        case .activePlaybackObservation:
            guard !hasUserSelection || SonosRoomName.matches(self.roomName, roomName) else {
                return false
            }
        case .directoryRefresh:
            if !SonosRoomName.matches(self.roomName, roomName) {
                hasUserSelection = false
            }
        case .userSelection:
            hasUserSelection = roomName != nil
        case .playbackTransaction, .reset:
            hasUserSelection = false
        }

        self.roomName = roomName
        return true
    }
}
