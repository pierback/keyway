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
                service: SpotifyConnectHandoffService(configStore: ConfigStore()),
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
              3. if possible, removes the current coordinator and transfers playback to a
                 replacement using coordinator-migration verification, failing if the operation
                 takes longer than 2 seconds
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

    private let service: SpotifyConnectHandoffService
    private let readinessResolver = SonosGroupingReadinessResolver()
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

        let readiness = try await readinessReport(in: initialState)
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

        try await exerciseStandaloneJoinAndRemoval(scenario: groupingScenario)
        let stateAfterStandaloneCheck = try await service.discoverGroupState()
        let refreshedReadiness = try await readinessReport(in: stateAfterStandaloneCheck)
        guard let refreshedScenario = scenario(from: refreshedReadiness),
              refreshedReadiness.blockingIssues.isEmpty
        else {
            let reason = refreshedReadiness.blockingIssues.map(\.rawValue).joined(separator: ",")
            throw ValidationError("Coordinator validation is not ready after standalone check: \(reason)")
        }
        try await exerciseCoordinatorRemoval(scenario: refreshedScenario)
        print("safe_grouping_check=ok")
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
            let joinedState = try await service.discoverGroupState()
            try requireGroup(
                in: joinedState,
                containing: scenario.coordinator.roomName,
                alsoContaining: standaloneSpeaker.roomName,
                message: "Standalone speaker did not join the active group."
            )
            print("standalone_join=ok room=\(standaloneSpeaker.roomName)")

            try await prepareSafeMutation(label: "standalone_remove")
            try await service.removeFromGroup(roomName: standaloneSpeaker.roomName)
            let removedState = try await service.discoverGroupState()
            guard removedState.groups.contains(where: { group in
                group.members.count == 1 && group.contains(roomName: standaloneSpeaker.roomName)
            }) else {
                throw ValidationError("Standalone speaker did not become standalone after removal.")
            }
        } catch {
            try await rollbackStandaloneJoin(roomName: standaloneSpeaker.roomName, originalError: error)
            throw error
        }
        print("standalone_remove=ok room=\(standaloneSpeaker.roomName)")
    }

    private func exerciseCoordinatorRemoval(scenario: GroupingScenario) async throws {
        guard let replacement = scenario.coordinatorReplacement else {
            print("coordinator_remove=skipped reason=no_replacement_candidate")
            return
        }

        try await prepareSafeMutation(label: "coordinator_remove")
        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try await service.removeCoordinator(
                in: scenario.group,
                coordinatorRoomName: scenario.coordinator.roomName,
                replacementRoomName: replacement.roomName
            )
            try await prepareSafeMutation(label: "coordinator_transfer")
            let transfer = await service.transfer(toRoomName: replacement.roomName, verification: .coordinatorMigration)
            let elapsed = startedAt.duration(to: clock.now)
            guard case .success = transfer else {
                throw ValidationError("Coordinator migration transfer failed: \(transfer)")
            }
            guard elapsed <= Self.coordinatorMigrationTarget else {
                throw ValidationError(
                    "Coordinator migration exceeded target: elapsed=\(elapsed) target=\(Self.coordinatorMigrationTarget)"
                )
            }

            let migratedState = try await service.discoverGroupState()
            try requireCoordinatorRemoved(
                in: migratedState,
                oldCoordinator: scenario.coordinator,
                replacement: replacement
            )
            print("coordinator_remove=ok old=\(scenario.coordinator.roomName) replacement=\(replacement.roomName) elapsed=\(elapsed)")
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

        let restoredState = try await service.discoverGroupState()
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

    private func requireCoordinatorRemoved(
        in state: SonosGroupState,
        oldCoordinator: SonosSpeaker,
        replacement: SonosSpeaker
    ) throws {
        guard let replacementGroup = state.groups.first(where: { $0.contains(roomName: replacement.roomName) }) else {
            throw ValidationError("Replacement coordinator group was not visible after coordinator removal.")
        }
        guard replacementGroup.coordinator?.id == replacement.id else {
            throw ValidationError("\(replacement.roomName) is not the coordinator after coordinator removal.")
        }
        guard !replacementGroup.contains(roomName: oldCoordinator.roomName) else {
            throw ValidationError("\(oldCoordinator.roomName) is still grouped with \(replacement.roomName).")
        }
    }

    private func requireGroup(
        in state: SonosGroupState,
        containing roomName: String,
        alsoContaining otherRoomName: String?,
        message: String
    ) throws {
        guard let group = state.groups.first(where: { $0.contains(roomName: roomName) }) else {
            throw ValidationError(message)
        }
        if let otherRoomName, !group.contains(roomName: otherRoomName) {
            throw ValidationError(message)
        }
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
