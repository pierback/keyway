import Foundation

public struct Logger: Sendable {
    public enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    public init() {}

    public func log(_ level: Level, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(timestamp)] [\(level.rawValue)] \(message)\n".utf8))
    }
}

