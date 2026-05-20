import Foundation

public struct SonosOutputPreferenceResolver: Sendable {
    public static let fallbackRoomName = "Port"

    public init() {}

    public func preferredRoomNames() -> [String] {
        [Self.fallbackRoomName]
    }

    public func preferredRoomName(selectedRoomName: String?) -> String {
        if let selectedRoomName = SonosRoomName.normalized(selectedRoomName) {
            return selectedRoomName
        }

        return Self.fallbackRoomName
    }
}
