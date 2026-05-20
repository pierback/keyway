import Foundation
import SonosHandoffCore

private let acknowledgement = "--i-understand-this-mutates-sonos-groups"
private let mutateFlag = "--mutate"
private let prepareSilentFlag = "--prepare-silent"
private let restoreFlag = "--restore-original-coordinator"

@main
struct SafeGroupingCheck {
    static func main() async {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        do {
            let validator = LiveGroupingValidator(
                service: SpotifyConnectHandoffService(),
                mutate: arguments.contains(mutateFlag),
                prepareSilent: arguments.contains(prepareSilentFlag),
                restoreOriginalCoordinator: arguments.contains(restoreFlag),
                acknowledgedMutation: arguments.contains(acknowledgement)
            )
            try await validator.run()
        } catch let error as ValidationError {
            fputs("sonos-handoff-safe-grouping-check: \(error.message)\n", stderr)
            exit(1)
        } catch {
            fputs("sonos-handoff-safe-grouping-check: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            Usage:
              sonos-handoff-safe-grouping-check
              sonos-handoff-safe-grouping-check \(prepareSilentFlag)
              sonos-handoff-safe-grouping-check --mutate \(acknowledgement)

            Default mode only discovers Sonos groups and prints the grouping scenario that would be
            tested, including any missing readiness prerequisite. It does not change speaker volume,
            mute state, or groups.

            \(prepareSilentFlag) mode discovers Sonos groups, mutes every discovered speaker, sets
            every discovered speaker to volume 0, verifies that safety state, and prints the
            grouping scenario that would be tested.

            Mutation mode always performs the same volume-0/muted safety preparation first,
            repeats that safety preparation immediately before every grouping/transfer mutation, then:
              1. adds one standalone speaker to the current Spotify-on-Sonos group
              2. removes that speaker again
              3. if possible, makes a replacement member standalone, transfers playback to that
                 replacement using coordinator-migration verification, then rejoins remaining
                 members, failing if prepare+transfer takes longer than 2 seconds, excluding
                 checker-only safety preparation and post-transfer regrouping
            Dry-run and prepared modes print grouping_validation_scope=full when both mutation
            paths are available, or a narrower scope when only part of the validation can run.

            Use \(restoreFlag) with mutation mode to add the old coordinator back and migrate the
            coordinator role back after the coordinator-removal check.
            """
        )
    }
}

private struct LiveGroupingValidator {
    private static let coordinatorMigrationTarget = Duration.seconds(2)
    private static let mutationObservationAttemptsMax = 8
    private static let mutationObservationRetryNanoseconds: UInt64 = 500_000_000

    private let service: SpotifyConnectHandoffService
    private let readinessResolver = SonosGroupingReadinessResolver()
    private let inspectionResolver = SonosGroupingInspectionResolver()
    private let mutate: Bool
    private let prepareSilent: Bool
    private let restoreOriginalCoordinator: Bool
    private let acknowledgedMutation: Bool

    init(
        service: SpotifyConnectHandoffService,
        mutate: Bool,
        prepareSilent: Bool,
        restoreOriginalCoordinator: Bool,
        acknowledgedMutation: Bool
    ) {
        self.service = service
        self.mutate = mutate
        self.prepareSilent = prepareSilent
        self.restoreOriginalCoordinator = restoreOriginalCoordinator
        self.acknowledgedMutation = acknowledgedMutation
    }

    func run() async throws {
        guard !mutate || acknowledgedMutation else {
            throw ValidationError("Mutation mode requires \(acknowledgement).")
        }

        let initialState = try await service.discoverGroupState()
        guard !initialState.speakers.isEmpty else {
            throw ValidationError("No Sonos speakers discovered.")
        }

        print("discovered_speakers=\(initialState.speakers.map(\.roomName).joined(separator: ","))")
        printGroups(initialState, prefix: "initial")
        if mutate || prepareSilent {
            try await forceSafeVolumeState(for: initialState.speakers)
            try await verifySafeVolumeState(for: initialState.speakers)
        } else {
            print("volume_safety=skipped")
        }

        let playback = try await service.activePlaybackDeviceStatus()
        printInspection(in: initialState, playback: playback)
        let readiness = readinessResolver.report(in: initialState, playback: playback)
        printReadinessIssues(readiness)
        guard let groupingScenario = scenario(from: readiness) else {
            let reason = readiness.blockingIssues.map(\.rawValue).joined(separator: ",")
            if !mutate {
                print("grouping_scenario=not_ready reason=\(reason)")
                print(prepareSilent ? "safe_grouping_check=prepared_not_ready" : "safe_grouping_check=dry_run_not_ready")
                return
            }
            throw ValidationError("Grouping validation is not ready: \(reason)")
        }

        if !readiness.blockingIssues.isEmpty {
            let reason = readiness.blockingIssues.map(\.rawValue).joined(separator: ",")
            printScenario(groupingScenario)
            if !mutate {
                print("grouping_scenario=not_ready reason=\(reason)")
                print(prepareSilent ? "safe_grouping_check=prepared_not_ready" : "safe_grouping_check=dry_run_not_ready")
                return
            }
            throw ValidationError("Grouping validation is not ready: \(reason)")
        }

        printScenario(groupingScenario)
        print("grouping_validation_scope=\(readiness.validationScope.rawValue)")

        if !readiness.canValidateAnyMutation {
            let reason = readiness.capabilityIssues.map(\.rawValue).joined(separator: ",")
            if !mutate {
                print("grouping_scenario=not_ready reason=\(reason)")
                print(prepareSilent ? "safe_grouping_check=prepared_not_ready" : "safe_grouping_check=dry_run_not_ready")
                return
            }
            throw ValidationError("No grouping mutation can be validated: \(reason)")
        }

        guard mutate else {
            print("grouping_mutation=skipped")
            print(safeGroupingStatus(prepareSilent: prepareSilent, scope: readiness.validationScope))
            return
        }

        var exercisedMutation = false
        if readiness.canValidateStandaloneJoinAndRemoval {
            try await exerciseStandaloneJoinAndRemoval(scenario: groupingScenario)
            exercisedMutation = true
        } else {
            print("standalone_join_remove=skipped reason=no_standalone_candidate")
        }

        let stateAfterStandaloneCheck = try await service.discoverGroupState()
        let refreshedReadiness = try await readinessReport(in: stateAfterStandaloneCheck)
        if refreshedReadiness.canValidateCoordinatorRemoval {
            guard let refreshedScenario = scenario(from: refreshedReadiness) else {
                throw ValidationError("Coordinator validation is ready, but no scenario could be built.")
            }
            try await exerciseCoordinatorRemoval(scenario: refreshedScenario)
            exercisedMutation = true
        } else {
            print("coordinator_remove=skipped reason=\(skipReason(from: refreshedReadiness))")
        }

        guard exercisedMutation else {
            throw ValidationError("No grouping mutation was exercised.")
        }
        print("safe_grouping_check=ok scope=\(readiness.validationScope.rawValue)")
    }

    private func safeGroupingStatus(
        prepareSilent: Bool,
        scope: SonosGroupingValidationScope
    ) -> String {
        switch (prepareSilent, scope) {
        case (_, .none):
            return prepareSilent ? "safe_grouping_check=prepared_not_ready" : "safe_grouping_check=dry_run_not_ready"
        case (true, .full):
            return "safe_grouping_check=ready"
        case (false, .full):
            return "safe_grouping_check=dry_run"
        case (true, _):
            return "safe_grouping_check=prepared_ready_partial"
        case (false, _):
            return "safe_grouping_check=dry_run_ready_partial"
        }
    }

    private func readinessReport(in state: SonosGroupState) async throws -> SonosGroupingReadinessReport {
        let playback = try await service.activePlaybackDeviceStatus()
        return readinessResolver.report(in: state, playback: playback)
    }

    private func printInspection(in state: SonosGroupState, playback: SpotifyPlaybackDeviceStatus?) {
        let activeRoomName = playback.flatMap { SonosRoomName.normalized($0.deviceName) }
        let report = inspectionResolver.report(
            in: state,
            activeRoomName: activeRoomName,
            spotifyPlaying: playback?.isPlaying == true,
            previousSpeakerIDs: nil
        )

        if let selectedRoomName = report.selectedRoomName {
            print("selected_output=\(selectedRoomName)")
        } else {
            print("selected_output=none")
        }

        for row in report.outputRows {
            print("output_row=\(row.displayName) coordinator=\(row.coordinator.roomName) grouped=\(row.isGroup)")
        }

        if report.groupEditRows.isEmpty {
            print("group_edit_rows=none")
        } else {
            for row in report.groupEditRows {
                print("group_edit_row=\(row.displayName) membership=\(row.membership.rawValueForInspection) can_toggle=\(row.canToggle) grouped=\(row.isGroup)")
            }
        }

        if let suggestion = report.suggestionCandidate {
            print("group_suggestion_candidate=\(suggestion.speaker.roomName) coordinator=\(suggestion.coordinatorRoomName) group=\(suggestion.groupDisplayName)")
        } else {
            print("group_suggestion_candidate=none")
        }
    }

    private func scenario(from readiness: SonosGroupingReadinessReport) -> GroupingScenario? {
        guard let activeRoomName = readiness.activeRoomName,
              let activeGroup = readiness.activeGroup,
              let coordinator = readiness.coordinator
        else {
            return nil
        }

        return GroupingScenario(
            activeRoomName: activeRoomName,
            group: activeGroup,
            coordinator: coordinator,
            standaloneSpeaker: readiness.standaloneSpeaker,
            coordinatorReplacement: readiness.coordinatorReplacement
        )
    }

    private func printReadinessIssues(_ readiness: SonosGroupingReadinessReport) {
        for issue in readiness.issues {
            print("readiness_issue=\(issue.rawValue)")
        }
    }

    private func printScenario(_ groupingScenario: GroupingScenario) {
        print("active_spotify_room=\(groupingScenario.activeRoomName)")
        print("active_group=\(groupingScenario.group.displayName)")
        if let standalone = groupingScenario.standaloneSpeaker {
            print("standalone_candidate=\(standalone.roomName)")
        } else {
            print("standalone_candidate=none")
        }
        if let replacement = groupingScenario.coordinatorReplacement {
            print("coordinator_replacement_candidate=\(replacement.roomName)")
        } else {
            print("coordinator_replacement_candidate=none")
        }
    }

    private func skipReason(from readiness: SonosGroupingReadinessReport) -> String {
        let issues = readiness.blockingIssues.isEmpty ? readiness.capabilityIssues : readiness.blockingIssues
        let reason = issues.map(\.rawValue).joined(separator: ",")
        return reason.isEmpty ? "not_available" : reason
    }

    private func forceSafeVolumeState(for speakers: [SonosSpeaker]) async throws {
        print("volume_safety=forcing_zero_muted")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for speaker in speakers {
                let service = service
                group.addTask {
                    _ = try await service.setVolume(roomName: speaker.roomName, volume: 0)
                    _ = try await service.setMute(roomName: speaker.roomName, muted: true)
                }
            }
            try await group.waitForAll()
        }
    }

    private func verifySafeVolumeState(for speakers: [SonosSpeaker]) async throws {
        for speaker in speakers {
            let status = try await service.volumeStatus(roomName: speaker.roomName)
            guard status.volume == 0, status.muted else {
                throw ValidationError(
                    "\(speaker.roomName) is not safe for live grouping tests: volume=\(status.volume) muted=\(status.muted)"
                )
            }
            print("volume_safety_room=\(speaker.roomName) volume=0 muted=true")
        }
        print("volume_safety=ok")
    }

    private func exerciseStandaloneJoinAndRemoval(scenario: GroupingScenario) async throws {
        guard let standaloneSpeaker = scenario.standaloneSpeaker else {
            print("standalone_join_remove=skipped reason=no_standalone_candidate")
            return
        }

        try await prepareSafeMutation(label: "standalone_join")
        try await service.join(
            roomName: standaloneSpeaker.roomName,
            toCoordinatorRoomName: scenario.coordinator.roomName
        )
        do {
            _ = try await waitForGroupState(
                label: "standalone_join",
                visibleSpeakers: groupingSpeakers(for: scenario),
                message: "Standalone speaker did not join the active group."
            ) { state in
                SonosGroupMutationObservation.groupContains(
                    in: state,
                    coordinatorRoomName: scenario.coordinator.roomName,
                    memberRoomNames: [standaloneSpeaker.roomName]
                )
            }
            print("standalone_join=ok room=\(standaloneSpeaker.roomName)")

            try await prepareSafeMutation(label: "standalone_remove")
            try await service.removeFromGroup(roomName: standaloneSpeaker.roomName)
            _ = try await waitForGroupState(
                label: "standalone_remove",
                visibleSpeakers: groupingSpeakers(for: scenario),
                message: "Standalone speaker did not become standalone after removal."
            ) { state in
                SonosGroupMutationObservation.speakerIsStandalone(
                    in: state,
                    roomName: standaloneSpeaker.roomName
                )
            }
        } catch {
            try await rollbackStandaloneJoin(roomName: standaloneSpeaker.roomName, originalError: error)
            throw error
        }
        print("standalone_remove=ok room=\(standaloneSpeaker.roomName)")
    }

    private func rollbackCoordinatorPreparation(
        scenario: GroupingScenario,
        replacement: SonosSpeaker,
        originalError: Error
    ) async throws {
        do {
            try await prepareSafeMutation(label: "coordinator_rollback")
            try await service.join(
                roomName: replacement.roomName,
                toCoordinatorRoomName: scenario.coordinator.roomName
            )
            _ = try await waitForGroupState(
                label: "coordinator_rollback",
                visibleSpeakers: scenario.group.members,
                message: "Coordinator preparation rollback did not rejoin \(replacement.roomName) to \(scenario.coordinator.roomName)."
            ) { state in
                SonosGroupMutationObservation.groupContains(
                    in: state,
                    coordinatorRoomName: scenario.coordinator.roomName,
                    memberRoomNames: [replacement.roomName]
                )
            }
            print("coordinator_rollback=ok room=\(replacement.roomName) coordinator=\(scenario.coordinator.roomName)")
        } catch {
            throw ValidationError(
                "Coordinator migration failed: \(describe(originalError)); rollback failed for \(replacement.roomName): \(describe(error))"
            )
        }
    }

    private func exerciseCoordinatorRemoval(scenario: GroupingScenario) async throws {
        guard let replacement = scenario.coordinatorReplacement else {
            print("coordinator_remove=skipped reason=no_replacement_candidate")
            return
        }

        let clock = ContinuousClock()
        let safetyInclusiveStartedAt = clock.now
        do {
            try await prepareSafeMutation(label: "coordinator_prepare")
            let prepareStartedAt = clock.now
            try await service.prepareCoordinatorRemoval(
                in: scenario.group,
                coordinatorRoomName: scenario.coordinator.roomName,
                replacementRoomName: replacement.roomName
            )
            let prepareElapsed = prepareStartedAt.duration(to: clock.now)

            try await prepareSafeMutation(label: "coordinator_transfer")
            let transferStartedAt = clock.now
            let transfer = await service.transfer(toRoomName: replacement.roomName, verification: .coordinatorMigration)
            let transferElapsed = transferStartedAt.duration(to: clock.now)
            guard case .success = transfer else {
                let transferError = ValidationError("Coordinator migration transfer failed: \(transfer)")
                try await rollbackCoordinatorPreparation(
                    scenario: scenario,
                    replacement: replacement,
                    originalError: transferError
                )
                throw transferError
            }

            try await prepareSafeMutation(label: "coordinator_finish")
            try await service.finishCoordinatorRemoval(
                in: scenario.group,
                coordinatorRoomName: scenario.coordinator.roomName,
                replacementRoomName: replacement.roomName
            )

            let operationElapsed = prepareElapsed + transferElapsed
            let safetyInclusiveElapsed = safetyInclusiveStartedAt.duration(to: clock.now)
            guard operationElapsed <= Self.coordinatorMigrationTarget else {
                throw ValidationError(
                    "Coordinator migration exceeded target: elapsed=\(operationElapsed) target=\(Self.coordinatorMigrationTarget)"
                )
            }

            _ = try await waitForGroupState(
                label: "coordinator_remove",
                visibleSpeakers: scenario.group.members,
                message: "\(scenario.coordinator.roomName) is still grouped with \(replacement.roomName)."
            ) { state in
                SonosGroupMutationObservation.coordinatorWasRemoved(
                    in: state,
                    oldCoordinatorRoomName: scenario.coordinator.roomName,
                    replacement: replacement
                )
            }
            print("coordinator_remove=ok old=\(scenario.coordinator.roomName) replacement=\(replacement.roomName) prepare_elapsed=\(prepareElapsed) transfer_elapsed=\(transferElapsed) elapsed=\(operationElapsed) safety_inclusive_elapsed=\(safetyInclusiveElapsed)")
        } catch {
            if restoreOriginalCoordinator {
                try await restoreOriginalCoordinatorRoleAfterFailureIfNeeded(
                    originalGroup: scenario.group,
                    replacement: replacement,
                    originalError: error
                )
            }
            throw error
        }

        guard restoreOriginalCoordinator else {
            print("coordinator_restore=skipped")
            return
        }

        try await restoreOriginalCoordinatorRole(
            originalGroup: scenario.group
        )
    }

    private func rollbackStandaloneJoin(roomName: String, originalError: Error) async throws {
        do {
            try await prepareSafeMutation(label: "standalone_rollback")
            try await service.removeFromGroup(roomName: roomName)
            print("standalone_rollback=ok room=\(roomName)")
        } catch {
            throw ValidationError(
                "Standalone check failed: \(describe(originalError)); rollback failed for \(roomName): \(describe(error))"
            )
        }
    }

    private func restoreOriginalCoordinatorRole(originalGroup: SonosSpeakerGroup) async throws {
        guard let oldCoordinator = originalGroup.coordinator else {
            throw ValidationError("Original coordinator is missing from \(originalGroup.displayName).")
        }

        try await prepareSafeMutation(label: "coordinator_restore_remove_old")
        try await service.removeFromGroup(roomName: oldCoordinator.roomName)
        for member in originalGroup.members where member.id != oldCoordinator.id {
            try await prepareSafeMutation(label: "coordinator_restore_join")
            try await service.join(roomName: member.roomName, toCoordinatorRoomName: oldCoordinator.roomName)
        }

        let restoredState = try await waitForGroupState(
            label: "coordinator_restore",
            visibleSpeakers: originalGroup.members,
            message: "Original group members did not rejoin \(oldCoordinator.roomName)."
        ) { state in
            SonosGroupMutationObservation.groupContains(
                in: state,
                coordinatorRoomName: oldCoordinator.roomName,
                memberRoomNames: originalGroup.members.map(\.roomName)
            )
        }
        guard let restoredGroup = restoredState.groups.first(where: { $0.contains(roomName: oldCoordinator.roomName) }),
              originalGroup.members.allSatisfy({ restoredGroup.contains(roomName: $0.roomName) })
        else {
            throw ValidationError("Original group members did not rejoin \(oldCoordinator.roomName).")
        }

        if restoredGroup.coordinator?.id != oldCoordinator.id {
            try await prepareSafeMutation(label: "coordinator_restore_migrate")
            try await service.migrateCoordinator(groupID: restoredGroup.id, toRoomName: oldCoordinator.roomName)
        }
        try await prepareSafeMutation(label: "coordinator_restore_transfer")
        let restoredTransfer = await service.transfer(toRoomName: oldCoordinator.roomName, verification: .coordinatorMigration)
        guard case .success = restoredTransfer else {
            throw ValidationError("Original coordinator transfer failed during restore: \(restoredTransfer)")
        }
        print("coordinator_restore=ok room=\(oldCoordinator.roomName)")
    }

    private func restoreOriginalCoordinatorRoleAfterFailureIfNeeded(
        originalGroup: SonosSpeakerGroup,
        replacement: SonosSpeaker,
        originalError: Error
    ) async throws {
        guard let oldCoordinator = originalGroup.coordinator else {
            throw ValidationError("Coordinator migration failed: \(describe(originalError)); original coordinator is missing.")
        }

        let latestState = try? await service.discoverGroupState()
        if latestState?.groups.contains(where: { group in
            group.contains(roomName: oldCoordinator.roomName)
                && originalGroup.members.allSatisfy { group.contains(roomName: $0.roomName) }
        }) == true {
            print("coordinator_restore=skipped reason=group_still_intact_after_failure")
            return
        }

        do {
            try await restoreOriginalCoordinatorRole(originalGroup: originalGroup)
        } catch {
            throw ValidationError(
                "Coordinator migration failed: \(describe(originalError)); restore failed: \(describe(error))"
            )
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? ValidationError {
            return error.message
        }
        return error.localizedDescription
    }

    private func prepareSafeMutation(label: String) async throws {
        let state = try await service.discoverGroupState()
        guard !state.speakers.isEmpty else {
            throw ValidationError("No Sonos speakers discovered before \(label).")
        }

        print("volume_safety_step=\(label)")
        try await forceSafeVolumeState(for: state.speakers)
        try await verifySafeVolumeState(for: state.speakers)
    }

    private func waitForGroupState(
        label: String,
        visibleSpeakers: [SonosSpeaker],
        message: String,
        matching predicate: (SonosGroupState) -> Bool
    ) async throws -> SonosGroupState {
        for attempt in 1 ... Self.mutationObservationAttemptsMax {
            let state = try await service.discoverGroupState(visibleSpeakers: visibleSpeakers)
            if predicate(state) {
                if attempt > 1 {
                    print("group_observation=\(label) attempts=\(attempt)")
                }
                return state
            }

            guard attempt < Self.mutationObservationAttemptsMax else {
                break
            }
            try await Task.sleep(nanoseconds: Self.mutationObservationRetryNanoseconds)
        }

        throw ValidationError(message)
    }

    private func groupingSpeakers(for scenario: GroupingScenario) -> [SonosSpeaker] {
        var speakers = scenario.group.members
        if let standaloneSpeaker = scenario.standaloneSpeaker,
           !speakers.contains(where: { $0.id == standaloneSpeaker.id }) {
            speakers.append(standaloneSpeaker)
        }
        return speakers
    }

    private func printGroups(_ state: SonosGroupState, prefix: String) {
        for group in state.groups {
            let coordinatorName = group.coordinator?.roomName ?? "unknown"
            print("\(prefix)_group=\(group.displayName) coordinator=\(coordinatorName) members=\(group.roomNames.joined(separator: ","))")
        }
    }
}

private struct GroupingScenario {
    let activeRoomName: String
    let group: SonosSpeakerGroup
    let coordinator: SonosSpeaker
    let standaloneSpeaker: SonosSpeaker?
    let coordinatorReplacement: SonosSpeaker?
}

private struct ValidationError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private extension SonosGroupMembership {
    var rawValueForInspection: String {
        switch self {
        case .coordinator:
            return "coordinator"
        case .member:
            return "member"
        case .available:
            return "available"
        case .availableGroup:
            return "available_group"
        }
    }
}
