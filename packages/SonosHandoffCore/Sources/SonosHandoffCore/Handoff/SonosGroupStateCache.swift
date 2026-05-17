public actor SonosGroupStateCache {
    private let groupingStateReader: any SonosGroupingStateReading
    private var cachedState: SonosGroupState?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var backgroundRefreshFailed = false

    public init(groupingStateReader: any SonosGroupingStateReading) {
        self.groupingStateReader = groupingStateReader
    }

    public func startBackgroundRefresh() {
        guard backgroundRefreshTask == nil else {
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
        } else {
            backgroundRefreshFailed = true
        }
        backgroundRefreshTask = nil
    }
}
