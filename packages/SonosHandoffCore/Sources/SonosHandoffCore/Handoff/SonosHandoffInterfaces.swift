public protocol SpeakerVolumeAdjusting: Sendable {
    func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus
    func setVolume(roomName: String, volume: Int) async throws -> Int
    func volumeDown(roomName: String, step: Int) async throws -> Int
    func volumeUp(roomName: String, step: Int) async throws -> Int
    func toggleMute(roomName: String) async throws -> Bool
}

public protocol SonosSpeakerDiscovering: Sendable {
    func discoverSpeakers() async throws -> [SonosSpeaker]
}

public protocol SonosGroupingStateReading: Sendable {
    func discoverGroupState() async throws -> SonosGroupState
}

public protocol RoomHandoffPerforming: Sendable {
    func transfer(toRoomName roomName: String) async -> TransferResult
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
        guard let roomName else {
            return false
        }

        return members.contains { SonosRoomName.matches($0.roomName, roomName) }
    }
}

public struct SonosGroupState: Equatable, Sendable {
    public let groups: [SonosSpeakerGroup]

    public init(groups: [SonosSpeakerGroup]) {
        self.groups = groups
    }

    public static let empty = SonosGroupState(groups: [])

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
