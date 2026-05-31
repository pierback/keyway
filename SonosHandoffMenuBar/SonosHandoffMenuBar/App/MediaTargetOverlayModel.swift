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

    func updateTargetsPreservingSelection(_ targets: [MediaRemoteTarget]) {
        let selectedTarget = selectedTarget
        var preservedSelectedTargetID: String?

        if targets.isEmpty {
            self.targets = []
        } else if self.targets.isEmpty {
            self.targets = targets
        } else {
            var consumedIDs = Set<String>()
            var stableTargets: [MediaRemoteTarget] = []
            for existingTarget in self.targets {
                guard let updatedTarget = updatedTarget(
                    matching: existingTarget,
                    in: targets,
                    consumedIDs: consumedIDs
                ) else {
                    continue
                }
                if targets.contains(where: { $0.id == updatedTarget.id }) {
                    consumedIDs.insert(updatedTarget.id)
                }
                if existingTarget.id == selectedTarget?.id {
                    preservedSelectedTargetID = updatedTarget.id
                }
                stableTargets.append(updatedTarget)
            }
            let newTargets = targets.filter { !consumedIDs.contains($0.id) }
            self.targets = stableTargets + newTargets
        }

        guard !self.targets.isEmpty else {
            selectedIndex = 0
            return
        }

        if let preservedSelectedTargetID,
           let preservedIndex = self.targets.firstIndex(where: { $0.id == preservedSelectedTargetID }) {
            selectedIndex = preservedIndex
        } else if let selectedTarget,
                  let preservedIndex = selectedIndex(matching: selectedTarget) {
            selectedIndex = preservedIndex
        } else {
            selectedIndex = min(selectedIndex, self.targets.count - 1)
        }
    }

    private func updatedTarget(
        matching existingTarget: MediaRemoteTarget,
        in targets: [MediaRemoteTarget],
        consumedIDs: Set<String>
    ) -> MediaRemoteTarget? {
        if let exactTarget = targets.first(where: { $0.id == existingTarget.id && !consumedIDs.contains($0.id) }) {
            return exactTarget
        }

        let candidates = targets.filter { candidate in
            !consumedIDs.contains(candidate.id)
                && isSameProcessTarget(candidate, existingTarget)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func selectedIndex(matching selectedTarget: MediaRemoteTarget) -> Int? {
        if let exactIndex = targets.firstIndex(where: { $0.id == selectedTarget.id }) {
            return exactIndex
        }

        let candidates = targets.indices.filter { index in
            isSameProcessTarget(targets[index], selectedTarget)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func isSameProcessTarget(
        _ candidate: MediaRemoteTarget,
        _ target: MediaRemoteTarget
    ) -> Bool {
        candidate.pid == target.pid
            && candidate.routingIdentity == target.routingIdentity
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
