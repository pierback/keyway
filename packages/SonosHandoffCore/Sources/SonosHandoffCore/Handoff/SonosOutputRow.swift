public struct SonosOutputRow: Identifiable, Equatable, Sendable {
    public let group: SonosSpeakerGroup
    public let coordinator: SonosSpeaker

    public init?(group: SonosSpeakerGroup) {
        guard let coordinator = group.coordinator else {
            return nil
        }

        self.group = group
        self.coordinator = coordinator
    }

    public var id: String {
        group.id
    }

    public var displayName: String {
        group.displayName
    }

    public var isGroup: Bool {
        group.members.count > 1
    }

    public func contains(roomName: String?) -> Bool {
        group.contains(roomName: roomName)
    }
}
