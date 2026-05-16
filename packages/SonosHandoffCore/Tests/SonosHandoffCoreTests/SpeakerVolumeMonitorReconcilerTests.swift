import Testing
@testable import SonosHandoffCore

struct SpeakerVolumeMonitorReconcilerTests {
    private let reconciler = SpeakerVolumeMonitorReconciler()

    @Test
    func firstStatusPrimesSnapshotWithoutFeedback() {
        let status = volumeStatus(roomName: "Port", volume: 34, muted: false)

        let decision = reconciler.reconcile(
            previousSnapshot: nil,
            status: status,
            suppressFeedback: false
        )

        #expect(decision.snapshot == SpeakerVolumeSnapshot(status: status))
        #expect(decision.logEvent == .primed)
        #expect(decision.feedback == nil)
    }

    @Test
    func unchangedStatusKeepsSnapshotWithoutFeedback() {
        let status = volumeStatus(roomName: "Port", volume: 34, muted: false)

        let decision = reconciler.reconcile(
            previousSnapshot: SpeakerVolumeSnapshot(status: status),
            status: status,
            suppressFeedback: false
        )

        #expect(decision.snapshot == SpeakerVolumeSnapshot(status: status))
        #expect(decision.logEvent == nil)
        #expect(decision.feedback == nil)
    }

    @Test
    func externalVolumeIncreaseReportsUpFeedback() {
        let decision = reconciler.reconcile(
            previousSnapshot: snapshot(roomName: "Port", volume: 30, muted: false),
            status: volumeStatus(roomName: "Port", volume: 35, muted: false),
            suppressFeedback: false
        )

        #expect(decision.logEvent == .changed)
        #expect(decision.feedback == .volume(direction: .up))
    }

    @Test
    func externalVolumeDecreaseReportsDownFeedback() {
        let decision = reconciler.reconcile(
            previousSnapshot: snapshot(roomName: "Port", volume: 30, muted: false),
            status: volumeStatus(roomName: "Port", volume: 25, muted: false),
            suppressFeedback: false
        )

        #expect(decision.logEvent == .changed)
        #expect(decision.feedback == .volume(direction: .down))
    }

    @Test
    func muteOnlyChangeReportsMuteFeedback() {
        let decision = reconciler.reconcile(
            previousSnapshot: snapshot(roomName: "Port", volume: 30, muted: false),
            status: volumeStatus(roomName: "Port", volume: 30, muted: true),
            suppressFeedback: false
        )

        #expect(decision.logEvent == .changed)
        #expect(decision.feedback == .mute)
    }

    @Test
    func suppressedChangeUpdatesSnapshotWithoutFeedback() {
        let status = volumeStatus(roomName: "Port", volume: 25, muted: false)

        let decision = reconciler.reconcile(
            previousSnapshot: snapshot(roomName: "Port", volume: 30, muted: false),
            status: status,
            suppressFeedback: true
        )

        #expect(decision.snapshot == SpeakerVolumeSnapshot(status: status))
        #expect(decision.logEvent == .changed)
        #expect(decision.feedback == nil)
    }

    @Test
    func roomChangePrimesNewSnapshot() {
        let decision = reconciler.reconcile(
            previousSnapshot: snapshot(roomName: "Kitchen", volume: 30, muted: false),
            status: volumeStatus(roomName: "Port", volume: 25, muted: false),
            suppressFeedback: false
        )

        #expect(decision.logEvent == .primed)
        #expect(decision.feedback == nil)
    }

    @Test
    func roomMatchIgnoresCaseAndOuterWhitespace() {
        let decision = reconciler.reconcile(
            previousSnapshot: snapshot(roomName: " port ", volume: 30, muted: false),
            status: volumeStatus(roomName: "PORT", volume: 35, muted: false),
            suppressFeedback: false
        )

        #expect(decision.logEvent == .changed)
        #expect(decision.feedback == .volume(direction: .up))
    }

    @Test
    func localChangeOverlaysMatchingSnapshot() {
        let nextSnapshot = reconciler.snapshotAfterLocalChange(
            previousSnapshot: snapshot(roomName: "Port", volume: 30, muted: false),
            roomName: "port",
            volume: 45,
            muted: true
        )

        #expect(nextSnapshot == snapshot(roomName: "Port", volume: 45, muted: true))
    }

    @Test
    func localChangeDoesNotOverlayDifferentRoom() {
        let nextSnapshot = reconciler.snapshotAfterLocalChange(
            previousSnapshot: snapshot(roomName: "Kitchen", volume: 30, muted: false),
            roomName: "Port",
            volume: 45,
            muted: true
        )

        #expect(nextSnapshot == nil)
    }
}

private func volumeStatus(roomName: String, volume: Int, muted: Bool) -> SpeakerVolumeStatus {
    SpeakerVolumeStatus(roomName: roomName, host: "\(roomName).local", volume: volume, outputFixed: false, muted: muted)
}

private func snapshot(roomName: String, volume: Int, muted: Bool) -> SpeakerVolumeSnapshot {
    SpeakerVolumeSnapshot(roomName: roomName, host: "\(roomName).local", volume: volume, outputFixed: false, muted: muted)
}
