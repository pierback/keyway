import Foundation

public enum SonosRoomName {
    public static func normalized(_ roomName: String?) -> String? {
        guard let trimmed = roomName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (normalized(lhs), normalized(rhs)) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return matches(lhs, rhs)
        case (.some, .none), (.none, .some):
            return false
        }
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else {
            return false
        }

        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    public static func matchesSpotifyDeviceName(_ deviceName: String, roomName: String) -> Bool {
        guard let deviceName = normalized(deviceName), let roomName = normalized(roomName) else {
            return false
        }
        if matches(deviceName, roomName) {
            return true
        }

        return deviceName.range(
            of: "\(roomName) + ",
            options: [.anchored, .caseInsensitive]
        ) != nil
    }
}
