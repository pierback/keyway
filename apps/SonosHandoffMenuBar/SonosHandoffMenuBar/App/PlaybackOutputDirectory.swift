import Foundation
import SonosHandoffCore

struct PlaybackOutputRefresh: Sendable {
    let rows: [PlaybackOutputRow]
    let speakers: [SonosSpeaker]
    let selectedRoomName: String?
    let menuMessage: String?
}

struct PlaybackOutputRow: Identifiable, Equatable, Sendable {
    let group: SonosSpeakerGroup

    var id: String {
        group.id
    }

    var displayName: String {
        group.displayName
    }

    var coordinator: SonosSpeaker {
        group.coordinator ?? group.members[0]
    }

    var isGroup: Bool {
        group.members.count > 1
    }

    func contains(roomName: String?) -> Bool {
        group.contains(roomName: roomName)
    }
}

enum PlaybackGroupMembership: Equatable, Sendable {
    case coordinator
    case member
    case available
}

struct PlaybackGroupEditRow: Identifiable, Equatable, Sendable {
    let speaker: SonosSpeaker
    let membership: PlaybackGroupMembership

    var id: String {
        speaker.id
    }

    var isInGroup: Bool {
        membership == .coordinator || membership == .member
    }

    var isCoordinator: Bool {
        membership == .coordinator
    }
}

@MainActor
final class PlaybackOutputDirectory {
    private let discoveryCache: PlaybackDiscoveryCache
    private let outputSelectionResolver = SonosOutputSelectionResolver()

    init(environment: AppEnvironment) {
        self.discoveryCache = PlaybackDiscoveryCache(groupingStateReader: environment.groupingStateReader)
    }

    init(groupingStateReader: any SonosGroupingStateReading, configStore: any ConfigStoring) {
        self.discoveryCache = PlaybackDiscoveryCache(groupingStateReader: groupingStateReader)
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

    private func refresh(from state: SonosGroupState, currentRoomName: String?) -> PlaybackOutputRefresh {
        let rows = state.groups.map(PlaybackOutputRow.init(group:))
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

actor PlaybackDiscoveryCache {
    private let groupingStateReader: any SonosGroupingStateReading
    private var cachedState: SonosGroupState?
    private var backgroundRefreshTask: Task<Void, Never>?

    init(groupingStateReader: any SonosGroupingStateReading) {
        self.groupingStateReader = groupingStateReader
    }

    func startBackgroundRefresh() {
        guard backgroundRefreshTask == nil else {
            return
        }

        let groupingStateReader = groupingStateReader
        backgroundRefreshTask = Task(priority: .utility) { [weak self] in
            do {
                let state = try await groupingStateReader.discoverGroupState()
                await self?.finishBackgroundRefresh(state: state)
            } catch {
                await self?.finishBackgroundRefresh(state: nil)
            }
        }
    }

    func cachedSnapshot() -> SonosGroupState? {
        cachedState
    }

    func refresh() async throws -> SonosGroupState {
        if let backgroundRefreshTask {
            await backgroundRefreshTask.value
            if let cachedState {
                return cachedState
            }
        }

        let state = try await groupingStateReader.discoverGroupState()
        cachedState = state
        return state
    }

    private func finishBackgroundRefresh(state: SonosGroupState?) {
        if let state {
            cachedState = state
        }
        backgroundRefreshTask = nil
    }
}
