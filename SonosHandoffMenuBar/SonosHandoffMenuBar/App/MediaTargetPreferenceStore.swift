import Foundation

@MainActor
final class MediaTargetPreferenceStore {
    private enum Keys {
        static let pinnedTargetIdentity = "keyway.mediaTarget.pinnedIdentity"
        static let recentTargetIdentity = "keyway.mediaTarget.recentIdentity"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pinnedTargetIdentity: String? {
        defaults.string(forKey: Keys.pinnedTargetIdentity)?.nilIfEmpty
    }

    var recentTargetIdentity: String? {
        defaults.string(forKey: Keys.recentTargetIdentity)?.nilIfEmpty
    }

    func setPinnedTarget(_ target: MediaRemoteTarget?) {
        guard let target else {
            defaults.removeObject(forKey: Keys.pinnedTargetIdentity)
            return
        }

        defaults.set(target.routingIdentity, forKey: Keys.pinnedTargetIdentity)
    }

    func togglePinnedTarget(_ target: MediaRemoteTarget) {
        if target.matchesRoutingIdentity(pinnedTargetIdentity) {
            setPinnedTarget(nil)
        } else {
            setPinnedTarget(target)
        }
    }

    func markRecentTarget(_ target: MediaRemoteTarget) {
        defaults.set(target.routingIdentity, forKey: Keys.recentTargetIdentity)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
