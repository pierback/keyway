public struct SonosOutputGroupOrderingResolver: Sendable {
    public init() {}

    public func orderedGroups(
        _ groups: [SonosSpeakerGroup],
        currentRoomName: String?
    ) -> [SonosSpeakerGroup] {
        let selectedGroupID = selectedGroupID(in: groups, currentRoomName: currentRoomName)

        return groups.sorted { left, right in
            if let selectedGroupID {
                if left.id == selectedGroupID, right.id != selectedGroupID {
                    return true
                }
                if right.id == selectedGroupID, left.id != selectedGroupID {
                    return false
                }
            }

            let nameComparison = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            return left.id.localizedCaseInsensitiveCompare(right.id) == .orderedAscending
        }
    }

    private func selectedGroupID(
        in groups: [SonosSpeakerGroup],
        currentRoomName: String?
    ) -> String? {
        groups.first { $0.contains(roomName: currentRoomName) }?.id
    }
}
