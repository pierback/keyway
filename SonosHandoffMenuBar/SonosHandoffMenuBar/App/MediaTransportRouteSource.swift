import Foundation

enum MediaTransportRouteSource: String {
    case eventTap = "event_tap"
    case commandCenter = "command_center"
    case userInterface = "user_interface"
}

struct MediaTransportInputMetadata: Equatable {
    let sourceUnixProcessID: Int64
    let sourceStateID: Int64
    let sourceUserData: Int64
    let targetUnixProcessID: Int64
    let sourceUserID: Int64
    let sourceGroupID: Int64
    let eventTimestamp: UInt64

    init(
        sourceUnixProcessID: Int64,
        sourceStateID: Int64,
        sourceUserData: Int64,
        targetUnixProcessID: Int64 = 0,
        sourceUserID: Int64 = 0,
        sourceGroupID: Int64 = 0,
        eventTimestamp: UInt64 = 0
    ) {
        self.sourceUnixProcessID = sourceUnixProcessID
        self.sourceStateID = sourceStateID
        self.sourceUserData = sourceUserData
        self.targetUnixProcessID = targetUnixProcessID
        self.sourceUserID = sourceUserID
        self.sourceGroupID = sourceGroupID
        self.eventTimestamp = eventTimestamp
    }

    var isPhysicalHIDSystemSource: Bool {
        sourceStateID == 1
            && sourceUserData == 0
    }

    var isUntargetedPhysicalHIDSystemSource: Bool {
        isPhysicalHIDSystemSource && targetUnixProcessID == 0
    }

    func matchesSameGeneratedMediaKey(as other: MediaTransportInputMetadata) -> Bool {
        guard eventTimestamp != 0,
              other.eventTimestamp != 0,
              eventTimestampsMatch(eventTimestamp, other.eventTimestamp)
        else {
            return false
        }

        return sourceUnixProcessID == other.sourceUnixProcessID
            && sourceStateID == other.sourceStateID
            && sourceUserData == other.sourceUserData
            && sourceUserID == other.sourceUserID
            && sourceGroupID == other.sourceGroupID
    }

    func matchesSameHIDSystemSource(as other: MediaTransportInputMetadata) -> Bool {
        isPhysicalHIDSystemSource
            && other.isPhysicalHIDSystemSource
            && sourceUnixProcessID == other.sourceUnixProcessID
            && sourceUserID == other.sourceUserID
            && sourceGroupID == other.sourceGroupID
    }

    private func eventTimestampsMatch(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        let delta = lhs > rhs ? lhs - rhs : rhs - lhs
        return delta <= 1_000_000
    }
}

struct MediaCommandCenterInputMetadata: Equatable {
    let eventTimestamp: TimeInterval

    func matchesSameCommandCenterEvent(as other: MediaCommandCenterInputMetadata) -> Bool {
        guard eventTimestamp > 0, other.eventTimestamp > 0 else {
            return false
        }
        return abs(eventTimestamp - other.eventTimestamp) <= 0.001
    }
}
