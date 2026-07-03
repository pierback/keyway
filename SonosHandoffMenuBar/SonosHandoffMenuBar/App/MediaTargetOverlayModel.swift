import Combine
import Foundation

@MainActor
final class MediaTargetOverlayModel: ObservableObject {
    @Published var command: MediaRemoteTransportCommand?
    @Published private(set) var rows: [SourceRow] = []
    @Published var selectedIndex = 0
    @Published var expanded = false
    @Published var audioSnapshot = MediaAudioControlSnapshot(
        sonos: .disabled(title: "Sonos", detail: "Checking output"),
        spotify: .disabled(title: "Spotify", detail: "Checking active device"),
        browser: .disabled(title: "Browser", detail: "Select a browser media target")
    )

    var targets: [MediaRemoteTarget] {
        rows.map(\.target)
    }

    var selectedTarget: MediaRemoteTarget? {
        guard rows.indices.contains(selectedIndex) else {
            return nil
        }
        return rows[selectedIndex].target
    }

    func update(
        command: MediaRemoteTransportCommand?,
        rows: [SourceRow]
    ) {
        self.command = command
        self.rows = rows
        selectedIndex = 0
        expanded = false
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else {
            return
        }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    }

    func select(index: Int) {
        guard rows.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }
}
