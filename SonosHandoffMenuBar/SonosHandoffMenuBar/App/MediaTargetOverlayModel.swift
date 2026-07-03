import Combine
import Foundation

enum MediaTargetOverlayEmptyState: Equatable {
    case discovering
    case confirmedEmpty(detail: String)
}

@MainActor
final class MediaTargetOverlayModel: ObservableObject {
    @Published var command: MediaRemoteTransportCommand?
    @Published private(set) var rows: [SourceRow] = []
    @Published var selectedIndex = 0
    @Published var expanded = false
    @Published var emptyState: MediaTargetOverlayEmptyState = .discovering
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
        emptyState = .discovering
    }

    func updateRowsPreservingSelection(_ rows: [SourceRow]) {
        let selectedID = selectedTarget?.id
        let previousIndex = selectedIndex
        self.rows = rows

        if let selectedID,
           let nextIndex = rows.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = nextIndex
        } else if rows.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(previousIndex, rows.count - 1)
        }
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
