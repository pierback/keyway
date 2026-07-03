import Foundation

enum MediaRemoteControllerError: LocalizedError {
    case missingBundleResources
    case missingHelperScript(String)
    case missingHelperDylib(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleResources:
            return "Bundle resources are unavailable."
        case .missingHelperScript(let path):
            return "Missing helper script at \(path)"
        case .missingHelperDylib(let path):
            return "Missing helper dylib at \(path)"
        }
    }
}

struct MediaRemoteEnvelope: Decodable {
    let type: String
}

struct MediaRemoteReadyEvent: Decodable {
    let type: String
    let host: String?
    let pid: Int?
}

struct MediaRemoteSnapshotEvent: Decodable {
    let type: String
    let requestID: String?
    let activeTargetID: String?
    let targets: [MediaRemoteTarget]
}

struct MediaRemotePongEvent: Decodable {
    let type: String
    let requestID: String?
    let pid: Int?
}

struct MediaRemoteCommandResultEvent: Decodable {
    let type: String
    let requestID: String?
    let targetID: String
    let command: String
    let ok: Bool
    let message: String
    let backend: String?
    let unsupported: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case requestID
        case targetID
        case command
        case ok
        case message
        case backend
        case unsupported
    }

    init(
        type: String,
        requestID: String?,
        targetID: String,
        command: String,
        ok: Bool,
        message: String,
        backend: String?,
        unsupported: Bool = false
    ) {
        self.type = type
        self.requestID = requestID
        self.targetID = targetID
        self.command = command
        self.ok = ok
        self.message = message
        self.backend = backend
        self.unsupported = unsupported
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        targetID = try container.decode(String.self, forKey: .targetID)
        command = try container.decode(String.self, forKey: .command)
        ok = try container.decode(Bool.self, forKey: .ok)
        message = try container.decode(String.self, forKey: .message)
        backend = try container.decodeIfPresent(String.self, forKey: .backend)
        unsupported = try container.decodeIfPresent(Bool.self, forKey: .unsupported) ?? false
    }
}

struct MediaRemoteClientCacheEvent: Decodable {
    let type: String
    let requestID: String?
    let ok: Bool
    let targetCount: Int
    let message: String
}

struct MediaRemoteErrorEvent: Decodable {
    let type: String
    let requestID: String?
    let message: String
}
