import Testing
@testable import SonosHandoffCore

struct SonosGroupingReadinessResolverTests {
    private let resolver = SonosGroupingReadinessResolver()

    @Test
    func reportsReadyScenarioWithStandaloneAndCoordinatorReplacement() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Office"),
            ]),
            playback: SpotifyPlaybackDeviceStatus(deviceName: "Kitchen", isPlaying: true, volumePercent: 0)
        )

        #expect(report.issues.isEmpty)
        #expect(report.activeRoomName == "Kitchen")
        #expect(report.activeGroup?.displayName == "Kitchen + Port")
        #expect(report.coordinator?.roomName == "Kitchen")
        #expect(report.standaloneSpeaker?.roomName == "Office")
        #expect(report.coordinatorReplacement?.roomName == "Port")
        #expect(report.hasActiveVisibleGroup)
        #expect(report.blockingIssues.isEmpty)
        #expect(report.capabilityIssues.isEmpty)
        #expect(report.canValidateStandaloneJoinAndRemoval)
        #expect(report.canValidateCoordinatorRemoval)
        #expect(report.canValidateAnyMutation)
        #expect(report.validationScope == .full)
    }

    @Test
    func reportsMissingPlaybackForSingleVisibleSpeakerWithoutPlayback() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
            ]),
            playback: nil
        )

        #expect(report.issues == [.noActiveSpotifyPlayback])
        #expect(report.blockingIssues == [.noActiveSpotifyPlayback])
        #expect(report.capabilityIssues.isEmpty)
        #expect(!report.hasActiveVisibleGroup)
        #expect(!report.canValidateAnyMutation)
        #expect(report.validationScope == .none)
    }

    @Test
    func reportsNoVisibleSpeakers() {
        let report = resolver.report(
            in: .empty,
            playback: nil
        )

        #expect(report.issues == [.noVisibleSpeakers, .noActiveSpotifyPlayback])
        #expect(!report.hasActiveVisibleGroup)
    }

    @Test
    func reportsSingleSpeakerPlaybackCannotExerciseGroupingMutations() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
            ]),
            playback: SpotifyPlaybackDeviceStatus(deviceName: "Kitchen", isPlaying: true, volumePercent: 0)
        )

        #expect(report.issues == [.noStandaloneCandidate, .noCoordinatorReplacement])
        #expect(report.blockingIssues.isEmpty)
        #expect(report.capabilityIssues == [.noStandaloneCandidate, .noCoordinatorReplacement])
        #expect(report.hasActiveVisibleGroup)
        #expect(!report.canValidateAnyMutation)
        #expect(report.validationScope == .none)
    }

    @Test
    func reportsSingleSpeakerPlaybackCanValidateJoinWhenStandaloneCandidateExists() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            playback: SpotifyPlaybackDeviceStatus(deviceName: "Kitchen", isPlaying: true, volumePercent: 0)
        )

        #expect(report.issues == [.noCoordinatorReplacement])
        #expect(report.blockingIssues.isEmpty)
        #expect(report.capabilityIssues == [.noCoordinatorReplacement])
        #expect(report.standaloneSpeaker?.roomName == "Office")
        #expect(report.canValidateStandaloneJoinAndRemoval)
        #expect(!report.canValidateCoordinatorRemoval)
        #expect(report.canValidateAnyMutation)
        #expect(report.validationScope == .standaloneJoinAndRemoval)
    }

    @Test
    func reportsCoordinatorRemovalOnlyWhenNoStandaloneCandidateExists() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            ]),
            playback: SpotifyPlaybackDeviceStatus(deviceName: "Kitchen", isPlaying: true, volumePercent: 0)
        )

        #expect(report.issues == [.noStandaloneCandidate])
        #expect(report.blockingIssues.isEmpty)
        #expect(report.capabilityIssues == [.noStandaloneCandidate])
        #expect(!report.canValidateStandaloneJoinAndRemoval)
        #expect(report.canValidateCoordinatorRemoval)
        #expect(report.canValidateAnyMutation)
        #expect(report.validationScope == .coordinatorRemoval)
    }

    @Test
    func reportsPausedInvisibleSpotifyRoom() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
            ]),
            playback: SpotifyPlaybackDeviceStatus(deviceName: "Office", isPlaying: false, volumePercent: 0)
        )

        #expect(report.issues == [.spotifyPlaybackNotPlaying, .activeSpotifyRoomNotVisible])
        #expect(report.blockingIssues == [.spotifyPlaybackNotPlaying, .activeSpotifyRoomNotVisible])
        #expect(report.capabilityIssues.isEmpty)
        #expect(!report.hasActiveVisibleGroup)
        #expect(!report.canValidateAnyMutation)
        #expect(report.validationScope == .none)
    }

    @Test
    func matchesSpotifyCountSuffixToActiveGroup() {
        let report = resolver.report(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Bath"]),
                standalone("Office"),
            ]),
            playback: SpotifyPlaybackDeviceStatus(deviceName: "Kitchen + 2", isPlaying: true, volumePercent: 0)
        )

        #expect(report.issues.isEmpty)
        #expect(report.activeGroup?.displayName == "Kitchen + 2")
        #expect(report.coordinator?.roomName == "Kitchen")
        #expect(report.canValidateAnyMutation)
        #expect(report.validationScope == .full)
    }

    private func standalone(_ roomName: String) -> SonosSpeakerGroup {
        let speaker = speaker(roomName)
        return SonosSpeakerGroup(id: speaker.id, coordinatorID: speaker.id, members: [speaker])
    }

    private func group(coordinator: String, members roomNames: [String]) -> SonosSpeakerGroup {
        SonosSpeakerGroup(
            id: "RINCON_\(coordinator.uppercased()):group",
            coordinatorID: "RINCON_\(coordinator.uppercased())",
            members: roomNames.map(speaker)
        )
    }

    private func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }
}
