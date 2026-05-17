import Foundation

actor SonosDirectory {
    private struct CacheEntry {
        let target: ConnectSonosTarget
        let expiresAt: Date
    }

    private let zeroconfClient: SonosSpotifyZeroconfClient
    private let zoneGroupTopology: SonosZoneGroupTopology
    private let resolver: SonosDNSSDResolver
    private let speakerDiscovery: SonosSpeakerDiscovery
    private var targetCache: [String: CacheEntry] = [:]
    private let targetCacheTTL: TimeInterval

    init(
        zeroconfClient: SonosSpotifyZeroconfClient,
        zoneGroupTopology: SonosZoneGroupTopology = SonosZoneGroupTopology(soapClient: SonosSOAPClient(urlSession: .shared)),
        resolver: SonosDNSSDResolver = SonosDNSSDResolver(),
        speakerDiscovery: SonosSpeakerDiscovery? = nil,
        targetCacheTTL: TimeInterval = 120
    ) {
        self.zeroconfClient = zeroconfClient
        self.zoneGroupTopology = zoneGroupTopology
        self.resolver = resolver
        self.speakerDiscovery = speakerDiscovery ?? SonosSpeakerDiscovery(resolver: resolver)
        self.targetCacheTTL = targetCacheTTL
    }

    func discoverSpeakers() async throws -> [SonosSpeaker] {
        try await speakerDiscovery.discoverSpeakers()
    }

    func discoverGroupState() async throws -> SonosGroupState {
        let speakers = try await discoverSpeakers()
        guard let topologySpeaker = speakers.first else {
            return .empty
        }
        do {
            let state = try await zoneGroupTopology
                .groupState(host: topologySpeaker.host, visibleSpeakers: speakers)
                .includingStandaloneSpeakers(speakers)
            storeTargets(for: state.speakers)
            return state
        } catch {
            let state = SonosGroupState.standalone(speakers: speakers)
            storeTargets(for: state.speakers)
            return state
        }
    }

    func resolveTarget(named roomName: String, needsSpotifyMetadata: Bool = true) async throws -> ConnectSonosTarget {
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedTarget = cachedTarget(for: roomName)
        if let cachedTarget,
           !needsSpotifyMetadata || cachedTarget.version != nil {
            return cachedTarget
        }

        let device: SonosResolvedDevice
        if let cachedTarget {
            device = SonosResolvedDevice(cachedTarget)
        } else {
            device = try await resolver.resolveDevice(named: roomName)
        }

        guard needsSpotifyMetadata else {
            let target = ConnectSonosTarget(roomName: device.roomName, host: device.host, version: nil, deviceID: device.id)
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

    func resolveGroupingTarget(named roomName: String) async throws -> ConnectSonosTarget {
        let normalizedRoomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedTarget = cachedTarget(for: normalizedRoomName) {
            return cachedTarget
        }

        let state = try await discoverGroupState()
        if let speaker = state.speakers.first(where: { SonosRoomName.matches($0.roomName, normalizedRoomName) }) {
            return storeAndReturnTarget(for: speaker)
        }

        return try await resolveTarget(named: normalizedRoomName, needsSpotifyMetadata: false)
    }

    func resolveGroupingTargets(named roomNames: [String]) async throws -> [ConnectSonosTarget] {
        let normalizedRoomNames = roomNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var targetsByRoomName: [String: ConnectSonosTarget] = [:]
        var missingRoomNames: [String] = []

        for roomName in normalizedRoomNames {
            if let cachedTarget = cachedTarget(for: roomName) {
                targetsByRoomName[Self.cacheKey(roomName)] = cachedTarget
            } else {
                missingRoomNames.append(roomName)
            }
        }

        if !missingRoomNames.isEmpty {
            let state = try await discoverGroupState()
            for roomName in missingRoomNames {
                if let speaker = state.speakers.first(where: { SonosRoomName.matches($0.roomName, roomName) }) {
                    targetsByRoomName[Self.cacheKey(roomName)] = storeAndReturnTarget(for: speaker)
                }
            }
        }

        var targets: [ConnectSonosTarget] = []
        targets.reserveCapacity(normalizedRoomNames.count)
        for roomName in normalizedRoomNames {
            if let target = targetsByRoomName[Self.cacheKey(roomName)] {
                targets.append(target)
            } else {
                targets.append(try await resolveTarget(named: roomName, needsSpotifyMetadata: false))
            }
        }
        return targets
    }

    func target(for speaker: SonosSpeaker) -> ConnectSonosTarget {
        storeAndReturnTarget(for: speaker)
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

    private func storeAndReturnTarget(for speaker: SonosSpeaker) -> ConnectSonosTarget {
        let target = ConnectSonosTarget(
            roomName: speaker.roomName,
            host: speaker.host,
            version: nil,
            deviceID: speaker.id
        )
        store(target, for: speaker.roomName)
        return target
    }

    private func storeTargets(for speakers: [SonosSpeaker]) {
        for speaker in speakers {
            _ = storeAndReturnTarget(for: speaker)
        }
    }

    private static func cacheKey(_ roomName: String) -> String {
        roomName.lowercased()
    }
}

private extension SonosResolvedDevice {
    init(_ target: ConnectSonosTarget) {
        self.init(id: target.deviceID ?? target.roomName, roomName: target.roomName, host: target.host)
    }
}
