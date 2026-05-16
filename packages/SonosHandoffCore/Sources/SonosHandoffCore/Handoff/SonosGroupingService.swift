import Foundation

final class SonosGroupingService: @unchecked Sendable {
    private let directory: SonosDirectory
    private let avTransport: SonosAVTransport

    init(directory: SonosDirectory, avTransport: SonosAVTransport) {
        self.directory = directory
        self.avTransport = avTransport
    }

    func join(roomName: String, toCoordinatorRoomName coordinatorRoomName: String) async throws {
        let member = try await directory.resolveGroupingTarget(named: roomName)
        let coordinator = try await directory.resolveGroupingTarget(named: coordinatorRoomName)
        guard member.deviceID != coordinator.deviceID || !SonosRoomName.matches(member.roomName, coordinator.roomName) else {
            return
        }

        guard coordinator.deviceID != nil else {
            throw ConnectHandoffError(.targetNotVisible, "Missing Sonos coordinator ID for \(coordinator.roomName)")
        }
        try await avTransport.join(target: member, coordinator: coordinator)
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
        for member in group.members where member.id != newCoordinator.id {
            let memberTarget = await directory.target(for: member)
            try await avTransport.join(target: memberTarget, coordinator: newCoordinatorTarget)
        }
    }

    func removeCoordinator(groupID: String, coordinatorRoomName: String, replacementRoomName: String) async throws {
        let state = try await directory.discoverGroupState()
        guard let group = state.groups.first(where: { $0.id == groupID }) else {
            throw ConnectHandoffError(.targetNotVisible, "Sonos group not found: \(groupID)")
        }

        guard let oldCoordinator = group.coordinator,
              oldCoordinator.id == group.coordinatorID,
              SonosRoomName.matches(oldCoordinator.roomName, coordinatorRoomName)
        else {
            throw ConnectHandoffError(.targetNotVisible, "\(coordinatorRoomName) is not the coordinator for \(group.displayName)")
        }

        guard let newCoordinator = group.members.first(where: { SonosRoomName.matches($0.roomName, replacementRoomName) }),
              newCoordinator.id != oldCoordinator.id
        else {
            throw ConnectHandoffError(.targetNotVisible, "\(replacementRoomName) is not a replacement member in \(group.displayName)")
        }

        let newCoordinatorTarget = await directory.target(for: newCoordinator)
        try await avTransport.becomeStandalone(target: newCoordinatorTarget)
        for member in group.members where member.id != newCoordinator.id && member.id != oldCoordinator.id {
            let memberTarget = await directory.target(for: member)
            try await avTransport.join(target: memberTarget, coordinator: newCoordinatorTarget)
        }
    }
}
