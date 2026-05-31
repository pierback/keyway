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

struct MediaRemoteCommandResultEvent: Decodable {
    let type: String
    let requestID: String?
    let targetID: String
    let command: String
    let ok: Bool
    let message: String
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
