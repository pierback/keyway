import Foundation
import SonosHandoffCore

struct PlaybackOutputRefresh: Sendable {
    let speakers: [SonosSpeaker]
    let selectedRoomName: String?
    let menuMessage: String?
}

@MainActor
final class PlaybackOutputDirectory {
    private let discoveryCache: PlaybackDiscoveryCache
    private let outputSelectionResolver = SonosOutputSelectionResolver()

    init(environment: AppEnvironment) {
        self.discoveryCache = PlaybackDiscoveryCache(speakerDiscovery: environment.speakerDiscovery)
    }

    init(speakerDiscovery: any SonosSpeakerDiscovering, configStore: any ConfigStoring) {
        self.discoveryCache = PlaybackDiscoveryCache(speakerDiscovery: speakerDiscovery)
    }

    func startBackgroundRefresh() async {
        await discoveryCache.startBackgroundRefresh()
    }

    func cachedRefresh(currentRoomName: String?) async -> PlaybackOutputRefresh? {
        guard let cachedSpeakers = await discoveryCache.cachedSnapshot() else {
            return nil
        }

        return refresh(from: cachedSpeakers, currentRoomName: currentRoomName)
    }

    func refresh(currentRoomName: String?) async throws -> PlaybackOutputRefresh {
        let speakers = try await discoveryCache.refresh()
        return refresh(from: speakers, currentRoomName: currentRoomName)
    }

    private func refresh(from speakers: [SonosSpeaker], currentRoomName: String?) -> PlaybackOutputRefresh {
        let selectedRoomName = selectedRoomName(currentRoomName: currentRoomName, in: speakers)
        return PlaybackOutputRefresh(
            speakers: speakers,
            selectedRoomName: selectedRoomName,
            menuMessage: speakers.isEmpty ? "No Sonos speakers found on this network." : nil
        )
    }

    private func selectedRoomName(currentRoomName: String?, in speakers: [SonosSpeaker]) -> String? {
        outputSelectionResolver.selectedRoomName(
            currentRoomName: currentRoomName,
            speakers: speakers
        )
    }
}

actor PlaybackDiscoveryCache {
    private let speakerDiscovery: any SonosSpeakerDiscovering
    private var cachedSpeakers: [SonosSpeaker]?
    private var backgroundRefreshTask: Task<Void, Never>?

    init(speakerDiscovery: any SonosSpeakerDiscovering) {
        self.speakerDiscovery = speakerDiscovery
    }

    func startBackgroundRefresh() {
        guard backgroundRefreshTask == nil else {
            return
        }

        let speakerDiscovery = speakerDiscovery
        backgroundRefreshTask = Task(priority: .utility) { [weak self] in
            do {
                let discovered = try await speakerDiscovery.discoverSpeakers()
                await self?.finishBackgroundRefresh(speakers: discovered)
            } catch {
                await self?.finishBackgroundRefresh(speakers: nil)
            }
        }
    }

    func cachedSnapshot() -> [SonosSpeaker]? {
        cachedSpeakers
    }

    func refresh() async throws -> [SonosSpeaker] {
        if let backgroundRefreshTask {
            await backgroundRefreshTask.value
            if let cachedSpeakers {
                return cachedSpeakers
            }
        }

        let discovered = try await speakerDiscovery.discoverSpeakers()
        cachedSpeakers = discovered
        return discovered
    }

    private func finishBackgroundRefresh(speakers: [SonosSpeaker]?) {
        if let speakers {
            cachedSpeakers = speakers
        }
        backgroundRefreshTask = nil
    }
}
