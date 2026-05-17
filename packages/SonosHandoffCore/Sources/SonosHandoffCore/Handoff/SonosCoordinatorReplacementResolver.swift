public struct SonosCoordinatorReplacementResolver: Sendable {
    public init() {}

    public func replacement(
        in group: SonosSpeakerGroup,
        removingCoordinatorID coordinatorID: String
    ) -> SonosSpeaker? {
        guard group.coordinatorID == coordinatorID,
              group.members.count > 1
        else {
            return nil
        }

        return group.members.first { $0.id != coordinatorID }
    }
}
