import Testing
@testable import SonosHandoffCore

struct SpeakerVolumeControlStateTests {
    @Test
    func initialStateHasNoStatusAndIsNotBusy() {
        let state = SpeakerVolumeControlState()

        #expect(state.value == 0)
        #expect(state.roundedValue == 0)
        #expect(!state.muted)
        #expect(!state.outputFixed)
        #expect(!state.hasStatus)
        #expect(!state.isBusy)
    }

    @Test
    func busyAndClearStatusResetState() {
        var state = SpeakerVolumeControlState()
        state.applyStatus(volumeStatus(volume: 42, outputFixed: true, muted: true))

        state.setBusy()
        #expect(state.isBusy)

        state.clearStatus()
        #expect(state == SpeakerVolumeControlState())
    }

    @Test
    func sliderValueIsBoundedAndConvertedToPercent() {
        var state = SpeakerVolumeControlState()

        state.setSliderValue(locationX: -20, width: 200)
        #expect(state.value == 0)

        state.setSliderValue(locationX: 50, width: 200)
        #expect(state.value == 25)

        state.setSliderValue(locationX: 250, width: 200)
        #expect(state.value == 100)
    }

    @Test
    func sliderValueTreatsNonPositiveWidthAsOnePoint() {
        var state = SpeakerVolumeControlState()

        state.setSliderValue(locationX: 0.5, width: 0)

        #expect(state.value == 50)
    }

    @Test
    func applyLocalVolumeClampsVolumeAndClearsBusy() {
        var state = SpeakerVolumeControlState()
        state.setBusy()

        state.applyLocalVolume(125, muted: false)

        #expect(state.value == 100)
        #expect(state.roundedValue == 100)
        #expect(!state.muted)
        #expect(state.hasStatus)
        #expect(!state.isBusy)
    }

    @Test
    func applyMuteKeepsVolumeAndClearsBusy() {
        var state = SpeakerVolumeControlState()
        state.applyLocalVolume(35, muted: false)
        state.setBusy()

        state.applyMute(true)

        #expect(state.value == 35)
        #expect(state.muted)
        #expect(state.hasStatus)
        #expect(!state.isBusy)
    }

    @Test
    func applyStatusUpdatesReportedSonosStateAndClearsBusy() {
        var state = SpeakerVolumeControlState()
        state.setBusy()

        state.applyStatus(volumeStatus(volume: -10, outputFixed: true, muted: true))

        #expect(state.value == 0)
        #expect(state.outputFixed)
        #expect(state.muted)
        #expect(state.hasStatus)
        #expect(!state.isBusy)
    }

    @Test
    func applySnapshotDoesNotClearBusy() {
        var state = SpeakerVolumeControlState()
        state.setBusy()

        state.applySnapshot(SpeakerVolumeSnapshot(
            roomName: "Port",
            host: "port.local",
            volume: 44,
            outputFixed: false,
            muted: true
        ))

        #expect(state.value == 44)
        #expect(state.muted)
        #expect(state.hasStatus)
        #expect(state.isBusy)
    }
}

private func volumeStatus(volume: Int, outputFixed: Bool, muted: Bool) -> SpeakerVolumeStatus {
    SpeakerVolumeStatus(roomName: "Port", host: "port.local", volume: volume, outputFixed: outputFixed, muted: muted)
}
