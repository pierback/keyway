import Combine
import Foundation

@MainActor
final class MediaPresenceGateSettings: ObservableObject {
    static let playPauseGateEnabledKey = "mediaPresenceGate.playPauseEnabled"

    @Published private(set) var playPauseGateEnabled: Bool

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        playPauseGateEnabled = userDefaults.bool(forKey: Self.playPauseGateEnabledKey)
    }

    func setPlayPauseGateEnabled(_ enabled: Bool) {
        guard playPauseGateEnabled != enabled else {
            return
        }
        playPauseGateEnabled = enabled
        userDefaults.set(enabled, forKey: Self.playPauseGateEnabledKey)
    }
}
