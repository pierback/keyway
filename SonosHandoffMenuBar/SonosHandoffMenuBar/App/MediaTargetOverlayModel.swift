import Combine
import Foundation

@MainActor
final class MediaTargetOverlayModel: ObservableObject {
    @Published var command: MediaRemoteTransportCommand?
    @Published var targets: [MediaRemoteTarget] = []
    @Published var selectedIndex = 0
    @Published var expanded = false
    @Published var audioSnapshot = MediaAudioControlSnapshot(
        sonos: .disabled(title: "Sonos", detail: "Checking output"),
        spotify: .disabled(title: "Spotify", detail: "Checking active device"),
        browser: .disabled(title: "Browser", detail: "Select a browser media target")
    )

    var selectedTarget: MediaRemoteTarget? {
        guard targets.indices.contains(selectedIndex) else {
            return nil
        }
        return targets[selectedIndex]
    }

    func update(
        command: MediaRemoteTransportCommand?,
        targets: [MediaRemoteTarget]
    ) {
        self.command = command
        self.targets = targets
        selectedIndex = 0
        expanded = false
    }

    func moveSelection(by delta: Int) {
        guard !targets.isEmpty else {
            return
        }
        selectedIndex = (selectedIndex + delta + targets.count) % targets.count
    }

    func select(index: Int) {
        guard targets.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }
}
