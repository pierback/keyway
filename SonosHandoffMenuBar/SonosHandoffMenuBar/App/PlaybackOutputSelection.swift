import Combine
import Foundation
import SonosHandoffCore

@MainActor
final class PlaybackOutputSelection: ObservableObject {
    @Published private(set) var roomName: String?
    @Published private(set) var selectedGroup: SonosSpeakerGroup?

    func setSelection(roomName: String?, group: SonosSpeakerGroup?) {
        let normalizedRoomName = SonosRoomName.normalized(roomName)
        let normalizedGroup = normalizedRoomName.flatMap { roomName in
            group?.contains(roomName: roomName) == true ? group : nil
        }

        guard !SonosRoomName.matches(self.roomName, normalizedRoomName) || selectedGroup != normalizedGroup else {
            return
        }

        self.roomName = normalizedRoomName
        selectedGroup = normalizedGroup
    }
}
