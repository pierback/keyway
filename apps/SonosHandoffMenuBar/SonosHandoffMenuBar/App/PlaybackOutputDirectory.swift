import Foundation
import SonosHandoffCore

struct PlaybackOutputRefresh: Sendable {
    let rows: [PlaybackOutputRow]
    let speakers: [SonosSpeaker]
    let selectedRoomName: String?
    let menuMessage: String?

    var selectedGroup: SonosSpeakerGroup? {
        guard let selectedRoomName else {
            return nil
        }

        return rows.first { $0.contains(roomName: selectedRoomName) }?.group
    }
}

typealias PlaybackOutputRow = SonosOutputRow
typealias PlaybackGroupEditRow = SonosGroupMembershipRow

@MainActor
final class PlaybackOutputDirectory {
    private let discoveryCache: SonosGroupStateCache
    private let outputSelectionResolver = SonosOutputSelectionResolver()
    private let outputGroupOrderingResolver = SonosOutputGroupOrderingResolver()

    init(environment: AppEnvironment) {
        self.discoveryCache = SonosGroupStateCache(groupingStateReader: environment.groupingStateReader)
    }

    init(groupingStateReader: any SonosGroupingStateReading, configStore: any ConfigStoring) {
        self.discoveryCache = SonosGroupStateCache(groupingStateReader: groupingStateReader)
    }

    func startBackgroundRefresh() async {
        await discoveryCache.startBackgroundRefresh()
    }

    func cachedRefresh(currentRoomName: String?) async -> PlaybackOutputRefresh? {
        guard let cachedState = await discoveryCache.cachedSnapshot() else {
            return nil
        }

        return refresh(from: cachedState, currentRoomName: currentRoomName)
    }

    func refresh(currentRoomName: String?) async throws -> PlaybackOutputRefresh {
        let state = try await discoveryCache.refresh()
        return refresh(from: state, currentRoomName: currentRoomName)
    }

    func refreshAfterBackgroundRefresh(currentRoomName: String?) async throws -> PlaybackOutputRefresh {
        let state = try await discoveryCache.refreshAfterBackgroundRefresh()
        return refresh(from: state, currentRoomName: currentRoomName)
    }

    private func refresh(from state: SonosGroupState, currentRoomName: String?) -> PlaybackOutputRefresh {
        let orderedGroups = outputGroupOrderingResolver.orderedGroups(
            state.groups,
            currentRoomName: currentRoomName
        )
        let rows = orderedGroups.compactMap(PlaybackOutputRow.init(group:))
        let speakers = state.speakers
        let selectedRoomName = selectedRoomName(currentRoomName: currentRoomName, in: state.groups)
        return PlaybackOutputRefresh(
            rows: rows,
            speakers: speakers,
            selectedRoomName: selectedRoomName,
            menuMessage: speakers.isEmpty ? "No Sonos speakers found on this network." : nil
        )
    }

    private func selectedRoomName(currentRoomName: String?, in groups: [SonosSpeakerGroup]) -> String? {
        outputSelectionResolver.selectedRoomName(
            currentRoomName: currentRoomName,
            groups: groups
        )
    }
}
