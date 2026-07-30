import Testing
@testable import SonosHandoffCore

struct PlaybackOperationAuthorityTests {
    @Test
    func transactionInvalidatesOlderObservation() {
        var authority = PlaybackOperationAuthority()
        authority.start()
        let roomAObservation = authority.beginObservation()!
        let roomBTransfer = authority.beginTransaction()!

        #expect(!authority.canCommitObservation(roomAObservation))
        #expect(authority.canCommitTransaction(roomBTransfer))
        let didEndTransaction = authority.endTransaction(roomBTransfer)
        #expect(didEndTransaction)

        let postTransferObservation = authority.beginObservation()!
        #expect(authority.canCommitObservation(postTransferObservation))
    }

    @Test
    func concurrentTransactionsAreRejected() {
        var authority = PlaybackOperationAuthority()
        authority.start()
        let firstTransaction = authority.beginTransaction()!

        #expect(authority.beginTransaction() == nil)
        #expect(authority.canCommitTransaction(firstTransaction))
    }

    @Test
    func stopAndRestartInvalidatesOldCompletions() {
        var authority = PlaybackOperationAuthority()
        authority.start()
        let oldObservation = authority.beginObservation()!
        let oldTransaction = authority.beginTransaction()!

        authority.stop()
        authority.start()

        #expect(!authority.canCommitObservation(oldObservation))
        #expect(!authority.canCommitTransaction(oldTransaction))
        let currentObservation = authority.beginObservation()!
        #expect(authority.canCommitObservation(currentObservation))
    }
}
