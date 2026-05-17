public enum SonosGroupingReadinessIssue: String, Equatable, Sendable {
    case noVisibleSpeakers = "no_visible_speakers"
    case noActiveSpotifyPlayback = "no_active_spotify_playback"
    case spotifyPlaybackNotPlaying = "spotify_playback_not_playing"
    case activeSpotifyRoomNotVisible = "active_spotify_room_not_visible"
    case noStandaloneCandidate = "no_standalone_candidate"
    case noCoordinatorReplacement = "no_coordinator_replacement"

    public var blocksValidation: Bool {
        switch self {
        case .noVisibleSpeakers,
             .noActiveSpotifyPlayback,
             .spotifyPlaybackNotPlaying,
             .activeSpotifyRoomNotVisible:
            return true
        case .noStandaloneCandidate,
             .noCoordinatorReplacement:
            return false
        }
    }
}

public enum SonosGroupingValidationScope: String, Equatable, Sendable {
    case none = "none"
    case standaloneJoinAndRemoval = "standalone_join_remove"
    case coordinatorRemoval = "coordinator_remove"
    case full = "full"
}

public struct SonosGroupingReadinessReport: Equatable, Sendable {
    public let issues: [SonosGroupingReadinessIssue]
    public let activeRoomName: String?
    public let activeGroup: SonosSpeakerGroup?
    public let coordinator: SonosSpeaker?
    public let standaloneSpeaker: SonosSpeaker?
    public let coordinatorReplacement: SonosSpeaker?

    public init(
        issues: [SonosGroupingReadinessIssue],
        activeRoomName: String?,
        activeGroup: SonosSpeakerGroup?,
        coordinator: SonosSpeaker?,
        standaloneSpeaker: SonosSpeaker?,
        coordinatorReplacement: SonosSpeaker?
    ) {
        self.issues = issues
        self.activeRoomName = activeRoomName
        self.activeGroup = activeGroup
        self.coordinator = coordinator
        self.standaloneSpeaker = standaloneSpeaker
        self.coordinatorReplacement = coordinatorReplacement
    }

    public var hasActiveVisibleGroup: Bool {
        activeRoomName != nil && activeGroup != nil && coordinator != nil
    }

    public var blockingIssues: [SonosGroupingReadinessIssue] {
        issues.filter(\.blocksValidation)
    }

    public var capabilityIssues: [SonosGroupingReadinessIssue] {
        issues.filter { !$0.blocksValidation }
    }

    public var canValidateStandaloneJoinAndRemoval: Bool {
        blockingIssues.isEmpty && standaloneSpeaker != nil
    }

    public var canValidateCoordinatorRemoval: Bool {
        blockingIssues.isEmpty && coordinatorReplacement != nil
    }

    public var canValidateAnyMutation: Bool {
        canValidateStandaloneJoinAndRemoval || canValidateCoordinatorRemoval
    }

    public var validationScope: SonosGroupingValidationScope {
        switch (canValidateStandaloneJoinAndRemoval, canValidateCoordinatorRemoval) {
        case (true, true):
            return .full
        case (true, false):
            return .standaloneJoinAndRemoval
        case (false, true):
            return .coordinatorRemoval
        case (false, false):
            return .none
        }
    }
}

public struct SonosGroupingReadinessResolver: Sendable {
    public init() {}

    public func report(
        in state: SonosGroupState,
        playback: SpotifyPlaybackDeviceStatus?
    ) -> SonosGroupingReadinessReport {
        let activeRoomName = SonosRoomName.normalized(playback?.deviceName)
        let activeGroup = activeRoomName.flatMap { roomName in
            state.groups.first { $0.contains(roomName: roomName) }
        }
        let coordinator = activeGroup?.coordinator
        let standaloneSpeaker = standaloneSpeaker(in: state, outside: activeGroup)
        let coordinatorReplacement = coordinatorReplacement(in: activeGroup, coordinator: coordinator)
        let issues = issues(
            state: state,
            playback: playback,
            activeRoomName: activeRoomName,
            activeGroup: activeGroup,
            standaloneSpeaker: standaloneSpeaker,
            coordinatorReplacement: coordinatorReplacement
        )

        return SonosGroupingReadinessReport(
            issues: issues,
            activeRoomName: activeRoomName,
            activeGroup: activeGroup,
            coordinator: coordinator,
            standaloneSpeaker: standaloneSpeaker,
            coordinatorReplacement: coordinatorReplacement
        )
    }

    private func issues(
        state: SonosGroupState,
        playback: SpotifyPlaybackDeviceStatus?,
        activeRoomName: String?,
        activeGroup: SonosSpeakerGroup?,
        standaloneSpeaker: SonosSpeaker?,
        coordinatorReplacement: SonosSpeaker?
    ) -> [SonosGroupingReadinessIssue] {
        var issues: [SonosGroupingReadinessIssue] = []

        if state.speakers.isEmpty {
            issues.append(.noVisibleSpeakers)
        }

        guard let playback, activeRoomName != nil else {
            issues.append(.noActiveSpotifyPlayback)
            return issues
        }

        if !playback.isPlaying {
            issues.append(.spotifyPlaybackNotPlaying)
        }

        guard activeGroup != nil else {
            issues.append(.activeSpotifyRoomNotVisible)
            return issues
        }

        if standaloneSpeaker == nil {
            issues.append(.noStandaloneCandidate)
        }
        if coordinatorReplacement == nil {
            issues.append(.noCoordinatorReplacement)
        }

        return issues
    }

    private func standaloneSpeaker(
        in state: SonosGroupState,
        outside activeGroup: SonosSpeakerGroup?
    ) -> SonosSpeaker? {
        state.groups
            .filter { $0.members.count == 1 }
            .flatMap(\.members)
            .first { speaker in
                activeGroup?.members.contains(where: { $0.id == speaker.id }) != true
            }
    }

    private func coordinatorReplacement(
        in activeGroup: SonosSpeakerGroup?,
        coordinator: SonosSpeaker?
    ) -> SonosSpeaker? {
        guard let activeGroup, let coordinator else {
            return nil
        }

        return activeGroup.members.first { $0.id != coordinator.id }
    }
}
