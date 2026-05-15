import Foundation

public struct PlaybackState: Codable, Equatable, Sendable {
    public let isPlaying: Bool
    public let deviceID: String?
    public let deviceName: String

    public init(isPlaying: Bool, deviceID: String?, deviceName: String) {
        self.isPlaying = isPlaying
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}
