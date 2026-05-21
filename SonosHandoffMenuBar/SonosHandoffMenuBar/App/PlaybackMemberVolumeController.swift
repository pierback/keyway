import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackMemberVolumeController {
    var onChange: (() -> Void)?
    private(set) var pinnedMixerGroupID: String? {
        didSet { notifyChange() }
    }
    private(set) var memberVolumeRows: [PlaybackMemberVolumeRow] = [] {
        didSet { notifyChange() }
    }
    private var memberVolumeLoadInFlightKey: String?
    private let volumeActions: PlaybackVolumeActionController
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Shortcuts")

    init(volumeActions: PlaybackVolumeActionController) {
        self.volumeActions = volumeActions
    }

    func isMixerPinned(for row: PlaybackOutputRow) -> Bool {
        pinnedMixerGroupID == row.id
    }

    func toggleMixer(for row: PlaybackOutputRow) {
        guard row.isGroup else { return }

        if pinnedMixerGroupID == row.id {
            pinnedMixerGroupID = nil
            memberVolumeRows = []
            return
        }

        pinnedMixerGroupID = row.id
        prepareMemberVolumeRows(for: row)
        loadMemberVolumes(for: row)
    }

    func loadMemberVolumes(for row: PlaybackOutputRow) {
        guard row.isGroup else { return }
        let loadKey = memberVolumeLoadKey(for: row)
        guard memberVolumeLoadInFlightKey != loadKey else { return }

        prepareMemberVolumeRows(for: row)
        memberVolumeLoadInFlightKey = loadKey
        Task { @MainActor in
            let statuses = await loadMemberVolumeStatuses(for: row)
            guard memberVolumeLoadInFlightKey == loadKey else { return }
            memberVolumeLoadInFlightKey = nil
            applyMemberVolumeStatuses(statuses, groupID: row.id)
        }
    }

    func setMemberVolumeFromSlider(rowID: String, locationX: CGFloat, width: CGFloat) {
        guard let index = memberVolumeRows.firstIndex(where: { $0.id == rowID }) else { return }
        memberVolumeRows[index].state.setSliderValue(locationX: Double(locationX), width: Double(width))
    }

    func commitMemberVolume(rowID: String, onMessage: @escaping (String) -> Void) {
        guard let index = memberVolumeRows.firstIndex(where: { $0.id == rowID }) else { return }

        let roomName = memberVolumeRows[index].speaker.roomName
        let desiredVolume = memberVolumeRows[index].state.roundedValue
        memberVolumeRows[index].state.setBusy()

        Task { @MainActor in
            do {
                let volume = try await volumeActions.setMemberVolume(roomName: roomName, volume: desiredVolume)
                updateMemberVolume(rowID: rowID, volume: volume, muted: false)
                logger.info("SonosHandoffMemberVolumeSet result=success room=\(roomName, privacy: .public) volume=\(volume, privacy: .public)")
            } catch {
                restoreMemberVolume(rowID: rowID)
                onMessage("Could not set \(roomName) volume.")
                logger.error("SonosHandoffMemberVolumeSet result=failure room=\(roomName, privacy: .public) volume=\(desiredVolume, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clearPinnedMixerIfSelectionChanged(selectedOutputGroup: SonosSpeakerGroup?) {
        guard let pinnedMixerGroupID else { return }

        guard let selectedOutputGroup, selectedOutputGroup.id == pinnedMixerGroupID else {
            self.pinnedMixerGroupID = nil
            memberVolumeRows = []
            memberVolumeLoadInFlightKey = nil
            return
        }
    }

    func refreshPinnedMixerRows(outputRows: [PlaybackOutputRow], selectedRoomName: String?) {
        guard let pinnedMixerGroupID,
              let row = outputRows.first(where: { $0.id == pinnedMixerGroupID }),
              row.contains(roomName: selectedRoomName)
        else { return }

        loadMemberVolumes(for: row)
    }

    private func prepareMemberVolumeRows(for row: PlaybackOutputRow) {
        guard row.isGroup else {
            memberVolumeRows = []
            return
        }

        let existingRowsByID = Dictionary(uniqueKeysWithValues: memberVolumeRows.map { ($0.id, $0) })
        memberVolumeRows = row.group.members.map { speaker in
            existingRowsByID[speaker.id] ?? PlaybackMemberVolumeRow(
                groupID: row.id,
                speaker: speaker,
                state: loadingMemberState()
            )
        }
    }

    private func loadMemberVolumeStatuses(for row: PlaybackOutputRow) async -> [String: SpeakerVolumeStatus] {
        await withTaskGroup(of: (String, SpeakerVolumeStatus?).self) { group in
            for speaker in row.group.members {
                group.addTask { [volumeActions] in
                    do {
                        let status = try await volumeActions.memberVolumeStatus(roomName: speaker.roomName)
                        return (speaker.id, status)
                    } catch {
                        return (speaker.id, nil)
                    }
                }
            }

            var statuses: [String: SpeakerVolumeStatus] = [:]
            for await (speakerID, status) in group {
                if let status {
                    statuses[speakerID] = status
                }
            }
            return statuses
        }
    }

    private func applyMemberVolumeStatuses(_ statuses: [String: SpeakerVolumeStatus], groupID: String) {
        memberVolumeRows = memberVolumeRows.map { row in
            guard row.groupID == groupID else { return row }

            var next = row
            if let status = statuses[row.id] {
                next.state.applyStatus(status)
                next.confirmedState = next.state
            } else {
                next.restoreConfirmedState()
            }
            return next
        }
    }

    private func updateMemberVolume(rowID: String, volume: Int, muted: Bool) {
        guard let index = memberVolumeRows.firstIndex(where: { $0.id == rowID }) else { return }
        memberVolumeRows[index].state.applyLocalVolume(volume, muted: muted)
        memberVolumeRows[index].confirmedState = memberVolumeRows[index].state
    }

    private func restoreMemberVolume(rowID: String) {
        guard let index = memberVolumeRows.firstIndex(where: { $0.id == rowID }) else { return }
        memberVolumeRows[index].restoreConfirmedState()
    }

    private func loadingMemberState() -> SpeakerVolumeControlState {
        var state = SpeakerVolumeControlState()
        state.setBusy()
        return state
    }

    private func memberVolumeLoadKey(for row: PlaybackOutputRow) -> String {
        let memberIDs = row.group.members.map(\.id).sorted().joined(separator: "|")
        return "\(row.id):\(memberIDs)"
    }

    private func notifyChange() {
        onChange?()
    }
}
