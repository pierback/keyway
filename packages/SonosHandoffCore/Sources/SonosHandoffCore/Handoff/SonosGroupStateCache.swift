import Foundation

public actor SonosGroupStateCache {
    private let groupingStateReader: any SonosGroupingStateReading
    private let minimumBackgroundRefreshInterval: TimeInterval
    private var cachedState: SonosGroupState?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var backgroundRefreshFailed = false
    private var lastSuccessfulRefreshAt: Date?

    public init(
        groupingStateReader: any SonosGroupingStateReading,
        minimumBackgroundRefreshInterval: TimeInterval = 10
    ) {
        self.groupingStateReader = groupingStateReader
        self.minimumBackgroundRefreshInterval = minimumBackgroundRefreshInterval
    }

    public func startBackgroundRefresh() {
        guard backgroundRefreshTask == nil else {
            return
        }
        guard shouldStartBackgroundRefresh(now: Date()) else {
            return
        }

        let groupingStateReader = groupingStateReader
        backgroundRefreshTask = Task(priority: .utility) { [weak self] in
            do {
                let state = try await groupingStateReader.discoverGroupState()
                await self?.finishBackgroundRefresh(state: state)
            } catch {
                await self?.finishBackgroundRefresh(state: nil)
            }
        }
    }

    public func cachedSnapshot() -> SonosGroupState? {
        guard !backgroundRefreshFailed else {
            return nil
        }

        return cachedState
    }

    public func refresh() async throws -> SonosGroupState {
        if let backgroundRefreshTask {
            await backgroundRefreshTask.value
            if let cachedState, !backgroundRefreshFailed {
                return cachedState
            }
        }

        let state = try await groupingStateReader.discoverGroupState()
        cachedState = state
        backgroundRefreshFailed = false
        lastSuccessfulRefreshAt = Date()
        return state
    }

    public func refresh(visibleSpeakers: [SonosSpeaker]) async throws -> SonosGroupState {
        let state = try await groupingStateReader.discoverGroupState(visibleSpeakers: visibleSpeakers)
        cachedState = state
        backgroundRefreshFailed = false
        lastSuccessfulRefreshAt = Date()
        return state
    }

    public func refreshAfterBackgroundRefresh() async throws -> SonosGroupState {
        if let backgroundRefreshTask {
            await backgroundRefreshTask.value
        }
        if let cachedState, !backgroundRefreshFailed {
            return cachedState
        }

        return try await refresh()
    }

    private func finishBackgroundRefresh(state: SonosGroupState?) {
        if let state {
            cachedState = state
            backgroundRefreshFailed = false
            lastSuccessfulRefreshAt = Date()
        } else {
            backgroundRefreshFailed = true
        }
        backgroundRefreshTask = nil
    }

    private func shouldStartBackgroundRefresh(now: Date) -> Bool {
        guard cachedState != nil,
              let lastSuccessfulRefreshAt
        else {
            return true
        }

        return now.timeIntervalSince(lastSuccessfulRefreshAt) >= minimumBackgroundRefreshInterval
    }
}
