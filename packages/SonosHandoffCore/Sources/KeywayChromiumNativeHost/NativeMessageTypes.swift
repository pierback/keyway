import Foundation

struct NativeMessageEnvelope: Decodable {
    let type: String
}

struct NativeHelloMessage: Decodable {
    let profileGuid: String
    let epoch: Int
    let resumed: Bool
    let snapshot: [NativeHelloSnapshotTarget]?

    private enum CodingKeys: String, CodingKey {
        case profileGuid
        case epoch
        case resumed
        case snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileGuid = try container.decode(String.self, forKey: .profileGuid)
        epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        resumed = try container.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
        snapshot = try container.decodeIfPresent([NativeHelloSnapshotTarget].self, forKey: .snapshot)
    }
}

struct NativeHelloSnapshotTarget: Decodable {
    let tabId: Int
}

final class HostConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var profileGuid: String?

    func record(profileGuid: String) {
        lock.lock()
        self.profileGuid = profileGuid
        lock.unlock()
    }

    func currentProfileGuid() -> String? {
        lock.lock()
        let value = profileGuid
        lock.unlock()
        return value
    }
}
