public protocol SpeakerVolumeAdjusting: Sendable {
    func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus
    func setVolume(roomName: String, volume: Int) async throws -> Int
    func volumeDown(roomName: String, step: Int) async throws -> Int
    func volumeUp(roomName: String, step: Int) async throws -> Int
    func toggleMute(roomName: String) async throws -> Bool
    func setMute(roomName: String, muted: Bool) async throws -> Bool
    func memberVolumeStatus(roomName: String) async throws -> SpeakerVolumeStatus
    func setMemberVolume(roomName: String, volume: Int) async throws -> Int
    func groupVolumeStatus(coordinatorRoomName: String) async throws -> SpeakerVolumeStatus
    func setGroupVolume(coordinatorRoomName: String, volume: Int) async throws -> Int
    func groupVolumeDown(coordinatorRoomName: String, step: Int) async throws -> Int
    func groupVolumeUp(coordinatorRoomName: String, step: Int) async throws -> Int
    func toggleGroupMute(coordinatorRoomName: String) async throws -> Bool
    func setGroupMute(coordinatorRoomName: String, muted: Bool) async throws -> Bool
}

public protocol SonosSpeakerDiscovering: Sendable {
    func discoverSpeakers() async throws -> [SonosSpeaker]
}

public protocol SonosGroupingStateReading: Sendable {
    func discoverGroupState() async throws -> SonosGroupState
    func discoverGroupState(visibleSpeakers: [SonosSpeaker]) async throws -> SonosGroupState
}

public protocol SonosGroupingEditing: Sendable {
    func join(roomName: String, toCoordinatorRoomName coordinatorRoomName: String) async throws
    func join(roomNames: [String], toCoordinatorRoomName coordinatorRoomName: String) async throws
    func removeFromGroup(roomName: String) async throws
    func migrateCoordinator(groupID: String, toRoomName roomName: String) async throws
    func prepareCoordinatorRemoval(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws
    func finishCoordinatorRemoval(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws
    func removeCoordinator(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws
}

public protocol RoomHandoffPerforming: Sendable {
    func transfer(toRoomName roomName: String, verification: RoomHandoffVerificationMode) async -> TransferResult
}

public enum RoomHandoffVerificationMode: Equatable, Sendable {
    case full
    case coordinatorMigration
}

public protocol SpotifyActivePlaybackObserving: Sendable {
    func activePlaybackDeviceStatus() async throws -> SpotifyPlaybackDeviceStatus?
}

public struct SonosSpeaker: Identifiable, Equatable, Sendable {
    public let id: String
    public let roomName: String
    public let host: String

    public init(id: String, roomName: String, host: String) {
        self.id = id
        self.roomName = roomName
        self.host = host
    }
}

public struct SonosSpeakerGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let coordinatorID: String
    public let members: [SonosSpeaker]

    public init(id: String, coordinatorID: String, members: [SonosSpeaker]) {
        self.id = id
        self.coordinatorID = coordinatorID
        self.members = members
    }

    public var coordinator: SonosSpeaker? {
        members.first { $0.id == coordinatorID } ?? members.first
    }

    public var roomNames: [String] {
        members.map(\.roomName)
    }

    public var displayName: String {
        guard let coordinator else {
            return "Sonos"
        }

        if members.count <= 1 {
            return coordinator.roomName
        }

        if members.count == 2,
           let second = members.first(where: { $0.id != coordinator.id }) {
            return "\(coordinator.roomName) + \(second.roomName)"
        }

        return "\(coordinator.roomName) + \(members.count - 1)"
    }

    public func contains(roomName: String?) -> Bool {
        guard let roomName = SonosRoomName.normalized(roomName) else {
            return false
        }

        if members.contains(where: { SonosRoomName.matches($0.roomName, roomName) }) {
            return true
        }

        guard let coordinator else {
            return false
        }

        return SonosRoomName.matches(displayName, roomName)
            || SonosRoomName.matchesSpotifyDeviceName(roomName, roomName: coordinator.roomName)
    }
}

public struct SonosGroupState: Equatable, Sendable {
    public let groups: [SonosSpeakerGroup]

    public init(groups: [SonosSpeakerGroup]) {
        self.groups = groups.filter { !$0.members.isEmpty }
    }

    public static let empty = SonosGroupState(groups: [])

    public static func standalone(speakers: [SonosSpeaker]) -> SonosGroupState {
        SonosGroupState(
            groups: speakers
                .sorted {
                    $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
                }
                .map { speaker in
                    SonosSpeakerGroup(
                        id: speaker.id,
                        coordinatorID: speaker.id,
                        members: [speaker]
                    )
                }
        )
    }

    public func includingStandaloneSpeakers(_ speakers: [SonosSpeaker]) -> SonosGroupState {
        let groupedSpeakerIDs = Set(self.speakers.map(\.id))
        let missingSpeakers = speakers.filter { !groupedSpeakerIDs.contains($0.id) }
        guard !missingSpeakers.isEmpty else {
            return self
        }

        return SonosGroupState(
            groups: (groups + Self.standalone(speakers: missingSpeakers).groups)
                .sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
        )
    }

    public var speakers: [SonosSpeaker] {
        groups.flatMap(\.members)
    }
}

public struct SpotifyPlaybackDeviceStatus: Equatable, Sendable {
    public let deviceName: String
    public let isPlaying: Bool
    public let volumePercent: Int?

    public init(deviceName: String, isPlaying: Bool, volumePercent: Int?) {
        self.deviceName = deviceName
        self.isPlaying = isPlaying
        self.volumePercent = volumePercent
    }
}

public struct SpeakerVolumeStatus: Equatable, Sendable {
    public let roomName: String
    public let host: String
    public let volume: Int
    public let outputFixed: Bool
    public let muted: Bool

    public init(roomName: String, host: String, volume: Int, outputFixed: Bool, muted: Bool) {
        self.roomName = roomName
        self.host = host
        self.volume = volume
        self.outputFixed = outputFixed
        self.muted = muted
    }
}
