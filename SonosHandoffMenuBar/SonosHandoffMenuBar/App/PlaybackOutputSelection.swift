import Combine
import Foundation
import SonosHandoffCore

@MainActor
final class PlaybackOutputSelection: ObservableObject {
    typealias UpdateSource = PlaybackOutputSelectionPolicy.UpdateSource

    @Published private(set) var roomName: String?
    @Published private(set) var selectedGroup: SonosSpeakerGroup?
    private var policy = PlaybackOutputSelectionPolicy()

    func update(roomName: String?, group: SonosSpeakerGroup?, source: UpdateSource) {
        guard policy.update(roomName: roomName, source: source) else {
            return
        }

        let normalizedRoomName = policy.roomName
        let normalizedGroup = normalizedRoomName.flatMap { roomName in
            group?.contains(roomName: roomName) == true ? group : nil
        }

        guard !SonosRoomName.matches(self.roomName, normalizedRoomName) || selectedGroup != normalizedGroup else {
            return
        }

        selectedGroup = normalizedGroup
        self.roomName = normalizedRoomName
        SonosVolumeMonitor.shared.setTarget(
            roomName: normalizedRoomName,
            scope: (normalizedGroup?.members.count ?? 0) > 1 ? .group : .member
        )
    }
}
