import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackSyncController: ObservableObject {
    @Published private(set) var speakers: [SonosSpeaker] = []
    @Published private(set) var selectedRoomName: String?
    @Published private(set) var loadingRoomName: String?
    @Published private(set) var volumeState = SpeakerVolumeControlState()
    @Published private(set) var isRefreshingOutputs = false
    @Published private(set) var menuMessage: String?
    @Published private(set) var spotifyAuthRequired = false
    @Published private(set) var spotifyAuthMessage = "Spotify sign-in expired. Sign in again to sync playback."

    private let outputDirectory: PlaybackOutputDirectory
    private let outputSelection: PlaybackOutputSelection
    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let volumeMonitor: SonosVolumeMonitor
    private let volumeActions: PlaybackVolumeActionController
    private let transferActions: PlaybackTransferActionController
    private let shortcutLogger = os.Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Shortcuts")
    private var monitorCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private let sliderCommitter = PlaybackSliderCommitter()
    private let operationGate = PlaybackOperationGate()
    private var activeSpotifyRoomName: String?

    init(
        environment: AppEnvironment,
        outputDirectory: PlaybackOutputDirectory? = nil,
        volumeMonitor: SonosVolumeMonitor = .shared,
        volumeActions: PlaybackVolumeActionController? = nil,
        transferActions: PlaybackTransferActionController? = nil
    ) {
        self.outputDirectory = outputDirectory ?? environment.outputDirectory
        self.outputSelection = environment.outputSelection
        self.activePlaybackObserver = environment.activePlaybackObserver
        self.volumeMonitor = volumeMonitor
        self.volumeActions = volumeActions ?? PlaybackVolumeActionController(
            environment: environment,
            volumeMonitor: volumeMonitor
        )
        self.transferActions = transferActions ?? PlaybackTransferActionController(environment: environment)
        self.monitorCancellable = volumeMonitor.$snapshot.sink { [weak self] snapshot in
            guard let self else {
                return
            }
            self.applyMonitoredVolume(snapshot)
        }
        self.outputSelectionCancellable = outputSelection.$roomName.sink { [weak self] roomName in
            guard let self else {
                return
            }
            self.applyExternalOutputSelection(roomName)
        }
    }

    var canControlVolume: Bool {
        selectedRoomName != nil && volumeState.hasStatus && !volumeState.isBusy && loadingRoomName == nil
    }

    func appear() {
        if selectedRoomName == nil {
            selectRoomName(outputSelection.roomName)
        }
        applyMonitoredVolume(volumeMonitor.snapshot)
        Task {
            let hasCachedOutputs = await applyCachedOutputs()
            await outputDirectory.startBackgroundRefresh()
            await syncActiveSpotifyOutput()
            await refreshOutputs(showLoading: !hasCachedOutputs)
        }
    }

    func setSliderEditing(_ editing: Bool) {
        sliderCommitter.setEditing(editing)
    }

    func setVolumeFromSlider(locationX: CGFloat, width: CGFloat) {
        volumeState.setSliderValue(locationX: Double(locationX), width: Double(width))
    }

    func commitSliderVolumeImmediately() {
        sliderCommitter.cancel()
        commitSliderVolume()
    }

    func commitSliderVolumeDebounced() {
        guard volumeState.hasStatus, let roomName = selectedRoomName else {
            return
        }

        let desiredVolume = volumeState.roundedValue
        volumeActions.noteLocalChange(roomName: roomName, volume: desiredVolume, muted: false)
        sliderCommitter.schedule(
            roomName: roomName,
            desiredVolume: desiredVolume,
            roomStillSelected: { [weak self] roomName in
                guard let self else {
                    return false
                }
                return SonosRoomName.matches(self.selectedRoomName, roomName)
            },
            commit: { [weak self] roomName, desiredVolume in
                self?.commitSliderVolume(
                    roomName: roomName,
                    desiredVolume: desiredVolume,
                    markBusy: false,
                    applyResultWhileEditing: false,
                    source: "slider_drag"
                )
            }
        )
    }

    func refreshOutputs(showLoading: Bool = true) async {
        guard !isRefreshingOutputs else {
            return
        }

        if showLoading {
            isRefreshingOutputs = true
        }
        defer { isRefreshingOutputs = false }
        clearMenuMessageIfAuthenticated()

        do {
            let refresh = try await outputDirectory.refresh(currentRoomName: preferredCurrentRoomName())
            applyOutputRefresh(refresh)
        } catch {
            speakers = []
            selectRoomName(nil)
            operationGate.cancelVolume()
            volumeState.clearStatus()
            menuMessage = "Could not search for Sonos speakers."
            shortcutLogger.error("SonosHandoffDiscovery result=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyCachedOutputs() async -> Bool {
        guard let refresh = await outputDirectory.cachedRefresh(currentRoomName: preferredCurrentRoomName()) else {
            return false
        }

        applyOutputRefresh(refresh)
        return true
    }

    private func syncActiveSpotifyOutput() async {
        do {
            guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                  let roomName = SonosRoomName.normalized(status.deviceName)
            else {
                activeSpotifyRoomName = nil
                selectRoomName(nil)
                clearSpotifyAuthRequired()
                return
            }

            activeSpotifyRoomName = roomName
            clearSpotifyAuthRequired()
            if speakers.contains(where: { SonosRoomName.matches($0.roomName, roomName) }) {
                selectRoomName(roomName)
                refreshVolumeStatus(roomName: roomName)
            }
        } catch {
            if SpotifyAuthRecovery.isAuthRequired(error) {
                requireSpotifyAuth(error)
                return
            }

            activeSpotifyRoomName = nil
            selectRoomName(nil)
            shortcutLogger.info("SonosHandoffSpotifyActiveDevice result=unavailable error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyOutputRefresh(_ refresh: PlaybackOutputRefresh) {
        speakers = refresh.speakers
        selectRoomName(refresh.selectedRoomName)

        if let selectedRoomName = refresh.selectedRoomName {
            clearSpotifyAuthRequired()
            refreshVolumeStatus(roomName: selectedRoomName)
        } else {
            operationGate.cancelVolume()
            volumeState.clearStatus()
            clearMenuMessageIfAuthenticated(refresh.menuMessage)
        }
    }

    private func preferredCurrentRoomName() -> String? {
        activeSpotifyRoomName
    }

    func adjustVolume(_ direction: VolumeDirection) {
        guard let roomName = selectedRoomName else {
            return
        }

        volumeState.setBusy()
        menuMessage = nil
        volumeActions.noteLocalChange(roomName: roomName)

        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let volume = try await volumeActions.adjustVolume(roomName: roomName, direction: direction)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                applyLocalVolume(roomName: roomName, volume: volume, muted: false)
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.clearStatus()
                menuMessage = "Could not change \(roomName) volume."
                refreshVolumeStatus(roomName: roomName)
            }
        }
    }

    func toggleMute() {
        guard let roomName = selectedRoomName else {
            return
        }

        volumeState.setBusy()
        menuMessage = nil
        volumeActions.noteLocalChange(roomName: roomName)

        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let muted = try await volumeActions.toggleMute(roomName: roomName)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.applyMute(muted)
                volumeActions.noteLocalChange(roomName: roomName, muted: muted)
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.clearStatus()
                menuMessage = "Could not toggle \(roomName) mute."
                refreshVolumeStatus(roomName: roomName)
            }
        }
    }

    func transfer(to speaker: SonosSpeaker) {
        let roomName = speaker.roomName
        loadingRoomName = roomName
        menuMessage = nil
        operationGate.cancelVolume()

        operationGate.runTransfer(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            let outcome = await transferActions.transfer(to: speaker)
            guard isCurrentTransferOperation(ticket) else {
                return
            }

            loadingRoomName = nil
            switch outcome.result {
            case .success:
                activeSpotifyRoomName = outcome.roomName
                selectRoomName(outcome.roomName)
                clearSpotifyAuthRequired()
                refreshVolumeStatus(roomName: outcome.roomName)
            case .failure(let code, _):
                if code == .authRequired {
                    requireSpotifyAuth(message: outcome.failureMessage)
                    return
                }

                menuMessage = outcome.failureMessage
                if let selectedRoomName {
                    refreshVolumeStatus(roomName: selectedRoomName)
                } else {
                    volumeState.clearStatus()
                }
            }
        }
    }

    private func refreshVolumeStatus(roomName: String? = nil) {
        guard let roomName = roomName ?? selectedRoomName else {
            return
        }

        volumeState.setBusy()
        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let status = try await volumeActions.volumeStatus(roomName: roomName)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                applyVolumeStatus(status)
                shortcutLogger.info("SonosHandoffVolumeStatus room=\(status.roomName, privacy: .public) host=\(status.host, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public) outputFixed=\(status.outputFixed, privacy: .public)")
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.clearStatus()
                menuMessage = "Could not read \(roomName) volume."
                shortcutLogger.error("SonosHandoffVolumeStatus result=failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyMonitoredVolume(_ snapshot: SpeakerVolumeSnapshot?) {
        guard let snapshot, !volumeState.isBusy, !sliderCommitter.isEditing else {
            return
        }
        guard let selectedRoomName,
              SonosRoomName.matches(selectedRoomName, snapshot.roomName)
        else {
            return
        }

        volumeState.applySnapshot(snapshot)
    }

    private func commitSliderVolume() {
        guard volumeState.hasStatus, let roomName = selectedRoomName else {
            refreshVolumeStatus()
            return
        }

        let desiredVolume = volumeState.roundedValue
        commitSliderVolume(
            roomName: roomName,
            desiredVolume: desiredVolume,
            markBusy: true,
            applyResultWhileEditing: true,
            source: "slider"
        )
    }

    private func commitSliderVolume(
        roomName: String,
        desiredVolume: Int,
        markBusy: Bool,
        applyResultWhileEditing: Bool,
        source: String
    ) {
        volumeActions.noteLocalChange(roomName: roomName, volume: desiredVolume, muted: false)
        if markBusy {
            volumeState.setBusy()
        }
        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let volume = try await volumeActions.setVolume(roomName: roomName, volume: desiredVolume)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                if applyResultWhileEditing || !sliderCommitter.isEditing {
                    applyLocalVolume(roomName: roomName, volume: volume, muted: false)
                } else {
                    volumeActions.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                }
                menuMessage = nil
                shortcutLogger.info("SonosHandoffVolumeSet result=success source=\(source, privacy: .public) room=\(roomName, privacy: .public) volume=\(volume, privacy: .public)")
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                menuMessage = "Could not set \(roomName) volume."
                shortcutLogger.error("SonosHandoffVolumeSet result=failure source=\(source, privacy: .public) room=\(roomName, privacy: .public) volume=\(desiredVolume, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                if !sliderCommitter.isEditing {
                    refreshVolumeStatus(roomName: roomName)
                }
            }
        }
    }

    private func applyLocalVolume(roomName: String, volume: Int, muted: Bool) {
        volumeState.applyLocalVolume(volume, muted: muted)
        volumeActions.noteLocalChange(roomName: roomName, volume: volume, muted: muted)
    }

    private func applyVolumeStatus(_ status: SpeakerVolumeStatus) {
        volumeState.applyStatus(status)
    }

    private func selectRoomName(_ roomName: String?) {
        if !SonosRoomName.matches(selectedRoomName, roomName) {
            sliderCommitter.cancel()
        }
        selectedRoomName = roomName
        outputSelection.setRoomName(roomName)
        volumeMonitor.setRoomName(roomName)
    }

    private func applyExternalOutputSelection(_ roomName: String?) {
        guard !SonosRoomName.matches(selectedRoomName, roomName) else {
            return
        }

        sliderCommitter.cancel()
        selectedRoomName = SonosRoomName.normalized(roomName)
        volumeMonitor.setRoomName(selectedRoomName)
        if let selectedRoomName {
            clearSpotifyAuthRequired()
            refreshVolumeStatus(roomName: selectedRoomName)
        } else {
            operationGate.cancelVolume()
            volumeState.clearStatus()
        }
    }

    private func requireSpotifyAuth(_ error: Error) {
        requireSpotifyAuth(message: SpotifyAuthRecovery.message(for: error))
    }

    private func requireSpotifyAuth(message: String?) {
        activeSpotifyRoomName = nil
        selectRoomName(nil)
        operationGate.cancelVolume()
        volumeState.clearStatus()
        spotifyAuthRequired = true
        spotifyAuthMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Spotify sign-in expired. Sign in again to sync playback."
        menuMessage = spotifyAuthMessage
        shortcutLogger.info("SonosHandoffSpotifyAuth state=required message=\(self.spotifyAuthMessage, privacy: .public)")
    }

    private func clearSpotifyAuthRequired() {
        let previousMessage = spotifyAuthMessage
        spotifyAuthRequired = false
        spotifyAuthMessage = "Spotify sign-in expired. Sign in again to sync playback."
        if menuMessage == previousMessage {
            menuMessage = nil
        }
    }

    private func clearMenuMessageIfAuthenticated(_ nextMessage: String? = nil) {
        guard !spotifyAuthRequired else {
            return
        }

        menuMessage = nextMessage
    }

    private func isCurrentVolumeOperation(_ ticket: PlaybackOperationTicket) -> Bool {
        operationGate.isCurrentVolume(ticket, selectedRoomName: selectedRoomName)
    }

    private func isCurrentTransferOperation(_ ticket: PlaybackOperationTicket) -> Bool {
        operationGate.isCurrentTransfer(ticket, loadingRoomName: loadingRoomName)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
