import Foundation

final class SonosGroupingService: @unchecked Sendable {
    private let directory: SonosDirectory
    private let avTransport: SonosAVTransport

    init(directory: SonosDirectory, avTransport: SonosAVTransport) {
        self.directory = directory
        self.avTransport = avTransport
    }

    func join(roomName: String, toCoordinatorRoomName coordinatorRoomName: String) async throws {
        try await join(roomNames: [roomName], toCoordinatorRoomName: coordinatorRoomName)
    }

    func join(roomNames: [String], toCoordinatorRoomName coordinatorRoomName: String) async throws {
        guard !roomNames.isEmpty else {
            return
        }

        let targets = try await directory.resolveGroupingTargets(named: roomNames + [coordinatorRoomName])
        guard let coordinator = targets.last else {
            return
        }
        guard coordinator.deviceID != nil else {
            throw ConnectHandoffError(.targetNotVisible, "Missing Sonos coordinator ID for \(coordinator.roomName)")
        }

        let members = targets.dropLast().filter { member in
            member.deviceID != coordinator.deviceID || !SonosRoomName.matches(member.roomName, coordinator.roomName)
        }
        try await rejoinTargets(members, to: coordinator)
    }

    func removeFromGroup(roomName: String) async throws {
        let member = try await directory.resolveGroupingTarget(named: roomName)
        try await avTransport.becomeStandalone(target: member)
    }

    func migrateCoordinator(groupID: String, toRoomName roomName: String) async throws {
        let state = try await directory.discoverGroupState()
        guard let group = state.groups.first(where: { $0.id == groupID }) else {
            throw ConnectHandoffError(.targetNotVisible, "Sonos group not found: \(groupID)")
        }

        guard let newCoordinator = group.members.first(where: { SonosRoomName.matches($0.roomName, roomName) }) else {
            throw ConnectHandoffError(.targetNotVisible, "\(roomName) is not in \(group.displayName)")
        }

        guard group.coordinatorID != newCoordinator.id else {
            return
        }

        let newCoordinatorTarget = await directory.target(for: newCoordinator)
        try await avTransport.becomeStandalone(target: newCoordinatorTarget)
        try await rejoinMembers(
            group.members.filter { $0.id != newCoordinator.id },
            to: newCoordinatorTarget
        )
    }

    func prepareCoordinatorRemoval(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws {
        let migration = try coordinatorMigration(
            in: group,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacementRoomName
        )

        let newCoordinatorTarget = await directory.target(for: migration.newCoordinator)
        try await avTransport.becomeStandalone(target: newCoordinatorTarget)
    }

    func finishCoordinatorRemoval(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws {
        let migration = try coordinatorMigration(
            in: group,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacementRoomName
        )

        let newCoordinatorTarget = await directory.target(for: migration.newCoordinator)
        try await rejoinMembers(
            group.members.filter { $0.id != migration.newCoordinator.id && $0.id != migration.oldCoordinator.id },
            to: newCoordinatorTarget
        )
    }

    private func coordinatorMigration(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) throws -> (oldCoordinator: SonosSpeaker, newCoordinator: SonosSpeaker) {
        guard let oldCoordinator = group.coordinator,
              SonosRoomName.matches(oldCoordinator.roomName, coordinatorRoomName)
        else {
            throw ConnectHandoffError(.targetNotVisible, "\(coordinatorRoomName) is not the coordinator for \(group.displayName)")
        }

        guard let newCoordinator = group.members.first(where: { SonosRoomName.matches($0.roomName, replacementRoomName) }),
              newCoordinator.id != oldCoordinator.id
        else {
            throw ConnectHandoffError(.targetNotVisible, "\(replacementRoomName) is not a replacement member in \(group.displayName)")
        }

        return (oldCoordinator, newCoordinator)
    }

    private func rejoinMembers(_ members: [SonosSpeaker], to coordinator: ConnectSonosTarget) async throws {
        var memberTargets: [ConnectSonosTarget] = []
        memberTargets.reserveCapacity(members.count)
        for member in members {
            memberTargets.append(await directory.target(for: member))
        }
        try await rejoinTargets(memberTargets, to: coordinator)
    }

    private func rejoinTargets(_ members: [ConnectSonosTarget], to coordinator: ConnectSonosTarget) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for member in members {
                let avTransport = avTransport
                group.addTask {
                    try await avTransport.join(target: member, coordinator: coordinator)
                }
            }

            try await group.waitForAll()
        }
    }
}
