import Foundation
import SonosHandoffCore

struct PlaybackOutputRefresh: Sendable {
    let state: SonosGroupState
    let rows: [PlaybackOutputRow]
    let speakers: [SonosSpeaker]
    let selectedRoomName: String?
    let selectedGroup: SonosSpeakerGroup?
    let groupEditRows: [PlaybackGroupEditRow]
    let menuMessage: String?
}

typealias PlaybackOutputRow = SonosOutputRow
typealias PlaybackGroupEditRow = SonosGroupMembershipRow

@MainActor
final class PlaybackOutputDirectory {
    private let discoveryCache: SonosGroupStateCache
    private let inspectionResolver = SonosGroupingInspectionResolver()

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
        let report = inspectionResolver.report(
            in: state,
            activeRoomName: currentRoomName,
            spotifyPlaying: currentRoomName != nil,
            previousSpeakerIDs: nil
        )
        let speakers = state.speakers
        return PlaybackOutputRefresh(
            state: state,
            rows: report.outputRows,
            speakers: speakers,
            selectedRoomName: report.selectedRoomName,
            selectedGroup: report.selectedGroup,
            groupEditRows: report.groupEditRows,
            menuMessage: speakers.isEmpty ? "No Sonos speakers found on this network." : nil
        )
    }
}
