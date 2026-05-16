import Combine
import Foundation
import SonosHandoffCore

@MainActor
final class PlaybackOutputSelection: ObservableObject {
    @Published private(set) var roomName: String?

    func setRoomName(_ roomName: String?) {
        let normalizedRoomName = SonosRoomName.normalized(roomName)
        guard !SonosRoomName.matches(self.roomName, normalizedRoomName) else {
            return
        }

        self.roomName = normalizedRoomName
    }
}
