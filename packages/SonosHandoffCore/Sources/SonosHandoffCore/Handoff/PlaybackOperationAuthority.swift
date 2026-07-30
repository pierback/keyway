public struct PlaybackAuthorityTicket: Equatable, Sendable {
    fileprivate let runtimeGeneration: Int
    fileprivate let operationGeneration: Int
}

public struct PlaybackOperationAuthority: Sendable {
    private var runtimeGeneration = 0
    private var observationGeneration = 0
    private var transactionGeneration = 0
    private var transactionInProgress = false
    public private(set) var isRunning = false

    public init() {}

    public mutating func start() {
        precondition(!isRunning)
        isRunning = true
        runtimeGeneration += 1
        observationGeneration += 1
        transactionGeneration += 1
    }

    public mutating func stop() {
        precondition(isRunning)
        isRunning = false
        runtimeGeneration += 1
        observationGeneration += 1
        transactionGeneration += 1
        transactionInProgress = false
    }

    public mutating func beginObservation() -> PlaybackAuthorityTicket? {
        guard isRunning, !transactionInProgress else {
            return nil
        }

        observationGeneration += 1
        return PlaybackAuthorityTicket(
            runtimeGeneration: runtimeGeneration,
            operationGeneration: observationGeneration
        )
    }

    public func canCommitObservation(_ ticket: PlaybackAuthorityTicket) -> Bool {
        isRunning
            && !transactionInProgress
            && ticket.runtimeGeneration == runtimeGeneration
            && ticket.operationGeneration == observationGeneration
    }

    public mutating func beginTransaction() -> PlaybackAuthorityTicket? {
        guard isRunning, !transactionInProgress else {
            return nil
        }

        transactionInProgress = true
        observationGeneration += 1
        transactionGeneration += 1
        return PlaybackAuthorityTicket(
            runtimeGeneration: runtimeGeneration,
            operationGeneration: transactionGeneration
        )
    }

    public func canCommitTransaction(_ ticket: PlaybackAuthorityTicket) -> Bool {
        isRunning
            && transactionInProgress
            && ticket.runtimeGeneration == runtimeGeneration
            && ticket.operationGeneration == transactionGeneration
    }

    @discardableResult
    public mutating func endTransaction(_ ticket: PlaybackAuthorityTicket) -> Bool {
        guard canCommitTransaction(ticket) else {
            return false
        }

        transactionInProgress = false
        observationGeneration += 1
        return true
    }

    public mutating func cancelTransaction() {
        guard transactionInProgress else {
            return
        }

        transactionInProgress = false
        observationGeneration += 1
        transactionGeneration += 1
    }
}
