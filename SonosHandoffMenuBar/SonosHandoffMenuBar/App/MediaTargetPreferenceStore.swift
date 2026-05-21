import Foundation

struct MediaTargetRoutingReference: Equatable {
    let id: String
    let fallbackIdentity: String
}

@MainActor
final class MediaTargetPreferenceStore {
    private enum Keys {
        static let pinnedTargetID = "keyway.mediaTarget.pinnedTargetID"
        static let pinnedTargetFallbackIdentity = "keyway.mediaTarget.pinnedTargetFallbackIdentity"
        static let recentTargetID = "keyway.mediaTarget.recentTargetID"
        static let recentTargetFallbackIdentity = "keyway.mediaTarget.recentTargetFallbackIdentity"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pinnedTargetReference: MediaTargetRoutingReference? {
        reference(idKey: Keys.pinnedTargetID, fallbackKey: Keys.pinnedTargetFallbackIdentity)
    }

    var recentTargetReference: MediaTargetRoutingReference? {
        reference(idKey: Keys.recentTargetID, fallbackKey: Keys.recentTargetFallbackIdentity)
    }

    var pinnedTargetID: String? {
        pinnedTargetReference?.id
    }

    func setPinnedTarget(_ target: MediaRemoteTarget?) {
        guard let target else {
            defaults.removeObject(forKey: Keys.pinnedTargetID)
            defaults.removeObject(forKey: Keys.pinnedTargetFallbackIdentity)
            return
        }

        defaults.set(target.id, forKey: Keys.pinnedTargetID)
        defaults.set(target.routingIdentity, forKey: Keys.pinnedTargetFallbackIdentity)
    }

    func togglePinnedTarget(_ target: MediaRemoteTarget) {
        if pinnedTargetReference?.id == target.id {
            setPinnedTarget(nil)
        } else {
            setPinnedTarget(target)
        }
    }

    func markRecentTarget(_ target: MediaRemoteTarget) {
        defaults.set(target.id, forKey: Keys.recentTargetID)
        defaults.set(target.routingIdentity, forKey: Keys.recentTargetFallbackIdentity)
    }

    private func reference(idKey: String, fallbackKey: String) -> MediaTargetRoutingReference? {
        guard let id = defaults.string(forKey: idKey)?.nilIfEmpty else {
            return nil
        }

        return MediaTargetRoutingReference(
            id: id,
            fallbackIdentity: defaults.string(forKey: fallbackKey)?.nilIfEmpty ?? id
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
