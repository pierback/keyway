import Testing
@testable import SonosHandoffCore

struct SonosGroupStateCacheTests {
    @Test
    func refreshUsesCompletedBackgroundSnapshotWithoutDuplicateDiscovery() async throws {
        let reader = StubGroupingStateReader(states: [
            Self.state(["Kitchen", "Port"]),
        ])
        let cache = SonosGroupStateCache(groupingStateReader: reader)

        await cache.startBackgroundRefresh()
        let refreshed = try await cache.refresh()

        #expect(Self.roomNames(refreshed) == ["Kitchen", "Port"])
        #expect(await reader.callCount() == 1)
        #expect(await cache.cachedSnapshot().map(Self.roomNames) == ["Kitchen", "Port"])
    }

    @Test
    func refreshAfterBackgroundRefreshReturnsCachedSnapshot() async throws {
        let reader = StubGroupingStateReader(states: [
            Self.state(["Kitchen"]),
            Self.state(["Port"]),
        ])
        let cache = SonosGroupStateCache(groupingStateReader: reader)

        await cache.startBackgroundRefresh()
        let first = try await cache.refreshAfterBackgroundRefresh()
        let second = try await cache.refreshAfterBackgroundRefresh()

        #expect(Self.roomNames(first) == ["Kitchen"])
        #expect(Self.roomNames(second) == ["Kitchen"])
        #expect(await reader.callCount() == 1)
    }

    @Test
    func failedBackgroundRefreshDoesNotExposeCachedSnapshot() async throws {
        let reader = StubGroupingStateReader(results: [
            .failure(CacheTestError.discoveryFailed),
            .success(Self.state(["Kitchen"])),
        ])
        let cache = SonosGroupStateCache(groupingStateReader: reader)

        await cache.startBackgroundRefresh()
        let refreshed = try await cache.refresh()

        #expect(Self.roomNames(refreshed) == ["Kitchen"])
        #expect(await reader.callCount() == 2)
        #expect(await cache.cachedSnapshot().map(Self.roomNames) == ["Kitchen"])
    }

    @Test
    func startBackgroundRefreshCoalescesInFlightRefresh() async throws {
        let reader = StubGroupingStateReader(states: [
            Self.state(["Kitchen"]),
        ])
        let cache = SonosGroupStateCache(groupingStateReader: reader)

        await cache.startBackgroundRefresh()
        await cache.startBackgroundRefresh()
        await cache.startBackgroundRefresh()
        _ = try await cache.refreshAfterBackgroundRefresh()

        #expect(await reader.callCount() == 1)
    }

    private static func state(_ roomNames: [String]) -> SonosGroupState {
        SonosGroupState.standalone(speakers: roomNames.map(speaker))
    }

    private static func roomNames(_ state: SonosGroupState) -> [String] {
        state.speakers.map { $0.roomName }
    }

    private static func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }
}

private enum CacheTestError: Error {
    case discoveryFailed
}

private actor StubGroupingStateReader: SonosGroupingStateReading {
    private var results: [Result<SonosGroupState, Error>]
    private var calls = 0

    init(states: [SonosGroupState]) {
        self.results = states.map(Result.success)
    }

    init(results: [Result<SonosGroupState, Error>]) {
        self.results = results
    }

    func discoverGroupState() async throws -> SonosGroupState {
        calls += 1
        guard !results.isEmpty else {
            throw CacheTestError.discoveryFailed
        }

        let result = results.removeFirst()
        switch result {
        case .success(let state):
            return state
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        calls
    }
}
