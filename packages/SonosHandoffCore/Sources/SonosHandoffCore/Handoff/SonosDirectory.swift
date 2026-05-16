import Foundation

actor SonosDirectory {
    private struct CacheEntry {
        let target: ConnectSonosTarget
        let expiresAt: Date
    }

    private let zeroconfClient: SonosSpotifyZeroconfClient
    private let resolver: SonosDNSSDResolver
    private let speakerDiscovery: SonosSpeakerDiscovery
    private var targetCache: [String: CacheEntry] = [:]
    private let targetCacheTTL: TimeInterval

    init(
        zeroconfClient: SonosSpotifyZeroconfClient,
        resolver: SonosDNSSDResolver = SonosDNSSDResolver(),
        speakerDiscovery: SonosSpeakerDiscovery? = nil,
        targetCacheTTL: TimeInterval = 120
    ) {
        self.zeroconfClient = zeroconfClient
        self.resolver = resolver
        self.speakerDiscovery = speakerDiscovery ?? SonosSpeakerDiscovery(resolver: resolver)
        self.targetCacheTTL = targetCacheTTL
    }

    func discoverSpeakers() async throws -> [SonosSpeaker] {
        try await speakerDiscovery.discoverSpeakers()
    }

    func resolveTarget(named roomName: String, needsSpotifyMetadata: Bool = true) async throws -> ConnectSonosTarget {
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedTarget = cachedTarget(for: roomName),
           !needsSpotifyMetadata || cachedTarget.version != nil {
            return cachedTarget
        }

        let device = try await resolver.resolveDevice(named: roomName)

        guard needsSpotifyMetadata else {
            let target = ConnectSonosTarget(roomName: device.roomName, host: device.host, version: nil, deviceID: nil)
            store(target, for: roomName)
            return target
        }

        let metadata = try await zeroconfClient.info(host: device.host)
        let target = ConnectSonosTarget(
            roomName: device.roomName,
            host: device.host,
            version: metadata.version,
            deviceID: metadata.deviceID
        )
        store(target, for: roomName)
        return target
    }

    private func cachedTarget(for roomName: String) -> ConnectSonosTarget? {
        let key = Self.cacheKey(roomName)
        guard let entry = targetCache[key] else {
            return nil
        }

        guard entry.expiresAt > Date() else {
            targetCache.removeValue(forKey: key)
            return nil
        }

        return entry.target
    }

    private func store(_ target: ConnectSonosTarget, for roomName: String) {
        targetCache[Self.cacheKey(roomName)] = CacheEntry(
            target: target,
            expiresAt: Date().addingTimeInterval(targetCacheTTL)
        )
    }

    private static func cacheKey(_ roomName: String) -> String {
        roomName.lowercased()
    }
}
