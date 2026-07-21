import Combine
import Foundation
import os
import SonosHandoffCore

enum MediaAudioVolumeDirection: Equatable, Sendable {
    case down
    case up

    var delta: Int {
        switch self {
        case .down:
            return -5
        case .up:
            return 5
        }
    }
}

struct MediaAudioControlPresentation: Equatable, Sendable {
    var title: String
    var detail: String
    var volume: Int?
    var muted: Bool?
    var isEnabled: Bool
    var isPending: Bool = false

    static func disabled(title: String, detail: String) -> MediaAudioControlPresentation {
        MediaAudioControlPresentation(
            title: title,
            detail: detail,
            volume: nil,
            muted: nil,
            isEnabled: false
        )
    }
}

struct MediaAudioControlSnapshot: Equatable, Sendable {
    var sonos: MediaAudioControlPresentation
    var spotify: MediaAudioControlPresentation
    var browser: MediaAudioControlPresentation
}

struct BrowserMuteState: Equatable, Sendable {
    let muted: Bool
    let isPending: Bool
}

@MainActor
final class MediaAudioControlController: ObservableObject {
    nonisolated private static let defaultBrowserMuteConfirmationTimeoutNanoseconds: UInt64 = 2_000_000_000

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaAudio")
    private let volumeService: any SpeakerVolumeAdjusting
    private let outputSelection: PlaybackOutputSelection
    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let mediaSourceStore: MediaSourceStore?
    private let volumeCommands: SpeakerVolumeCommandQueue
    private let browserMuteConfirmationTimeoutNanoseconds: UInt64
    private var mediaSourceRowsSubscription: AnyCancellable?
    @Published private var pendingBrowserMutesByTargetID: [String: PendingBrowserMute] = [:]

    private struct PendingBrowserMute {
        let expectedMuted: Bool
        let appName: String
        let startedAt: Date
        var timeoutTask: Task<Void, Never>?
    }

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        mediaSourceStore: MediaSourceStore? = nil,
        volumeCommands: SpeakerVolumeCommandQueue = .shared,
        browserMuteConfirmationTimeoutNanoseconds: UInt64 = MediaAudioControlController.defaultBrowserMuteConfirmationTimeoutNanoseconds
    ) {
        self.volumeService = volumeService
        self.outputSelection = outputSelection
        self.activePlaybackObserver = activePlaybackObserver
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.mediaSourceStore = mediaSourceStore
        self.volumeCommands = volumeCommands
        self.browserMuteConfirmationTimeoutNanoseconds = browserMuteConfirmationTimeoutNanoseconds
        mediaSourceRowsSubscription = mediaSourceStore?.$rows
            .sink { [weak self] rows in
                MainActor.assumeIsolated {
                    self?.confirmPendingBrowserMutes(rows: rows)
                }
            }
    }

    func snapshot(for target: MediaRemoteTarget?) async -> MediaAudioControlSnapshot {
        async let sonos = sonosPresentation()
        async let spotify = spotifyPresentation()
        return await MediaAudioControlSnapshot(
            sonos: sonos,
            spotify: spotify,
            browser: browserPresentation(for: target)
        )
    }

    func adjustSonosVolume(direction: MediaAudioVolumeDirection) {
        let target = sonosVolumeTarget()

        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, logger] in
            do {
                let nextVolume: Int
                switch (target.scope, direction) {
                case (.member, .down):
                    nextVolume = try await volumeCommands.volumeDown(using: volumeService, roomName: target.roomName, step: 5)
                case (.member, .up):
                    nextVolume = try await volumeCommands.volumeUp(using: volumeService, roomName: target.roomName, step: 5)
                case (.group, .down):
                    nextVolume = try await volumeCommands.groupVolumeDown(using: volumeService, coordinatorRoomName: target.roomName, step: 5)
                case (.group, .up):
                    nextVolume = try await volumeCommands.groupVolumeUp(using: volumeService, coordinatorRoomName: target.roomName, step: 5)
                }
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: target.roomName, volume: nextVolume, muted: false)
                    StatusHUD.shared.showVolume(roomName: target.roomName, volume: nextVolume, dismissAfter: 1.6)
                }
            } catch {
                await MainActor.run {
                    logger.error("MediaAudio sonos_volume_failed room=\(target.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    StatusHUD.shared.finish(title: "\(target.roomName) Volume Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func toggleSonosMute() {
        let target = sonosVolumeTarget()

        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, logger] in
            do {
                let muted: Bool
                switch target.scope {
                case .member:
                    muted = try await volumeCommands.toggleMute(using: volumeService, roomName: target.roomName)
                case .group:
                    muted = try await volumeCommands.toggleGroupMute(using: volumeService, coordinatorRoomName: target.roomName)
                }
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: target.roomName, muted: muted)
                    StatusHUD.shared.showMute(roomName: target.roomName, muted: muted, dismissAfter: 1.6)
                }
            } catch {
                await MainActor.run {
                    logger.error("MediaAudio sonos_mute_failed room=\(target.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    StatusHUD.shared.finish(title: "\(target.roomName) Mute Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func adjustSpotifyVolume(direction: MediaAudioVolumeDirection) {
        Task.detached(priority: .userInitiated) { [activePlaybackObserver] in
            do {
                guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                      let currentVolume = status.volumePercent
                else {
                    await MainActor.run {
                        StatusHUD.shared.finish(title: "Spotify Volume Unavailable", message: "Spotify has no active device volume.", dismissAfter: 2.0)
                    }
                    return
                }

                let requestedVolume = max(0, min(100, currentVolume + direction.delta))
                let confirmedVolume = try await activePlaybackObserver.setActivePlaybackDeviceVolume(requestedVolume)
                await MainActor.run {
                    StatusHUD.shared.showVolume(roomName: status.deviceName, volume: confirmedVolume, dismissAfter: 1.6)
                }
            } catch {
                await MainActor.run {
                    StatusHUD.shared.finish(title: "Spotify Volume Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func adjustBrowserVolume(direction: MediaAudioVolumeDirection, target: MediaRemoteTarget) {
        submitBrowserAudioCommand(
            .volumeDelta(Double(direction.delta) / 100),
            target: target
        )
    }

    func toggleBrowserMute(target: MediaRemoteTarget) {
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            StatusHUD.shared.finish(
                title: "Browser Command Unsupported",
                message: "\(target.appName) is not a Chromium extension target.",
                dismissAfter: 2.2
            )
            return
        }

        // Toggle from the pending-aware state, not raw confirmed state: the UI disables
        // the button while pending, but this is public API -- a second call racing the
        // 2s confirmation window would otherwise re-send "expect muted" while the tab
        // ends up toggled back, then time out into a false failure + suspect mark.
        let expectedMuted = !(browserMuteState(for: target)?.muted ?? confirmedBrowserMuted(target: target))
        beginPendingBrowserMute(target: target, expectedMuted: expectedMuted)

        guard let sent = chromiumBrowserExtensionController.submit(audioCommand: .mute, target: target, onResult: { [weak self, mediaSourceStore] result in
            mediaSourceStore?.recordCommandResult(result)
            if result.ok {
                return
            }
            self?.failPendingBrowserMute(
                targetID: target.id,
                title: result.unsupported ? "Browser Command Unsupported" : "Browser Command Failed",
                message: result.message,
                markCommandFailed: false
            )
        }) else {
            failPendingBrowserMute(
                targetID: target.id,
                title: "Browser Command Unsupported",
                message: "\(target.appName) is not a Chromium extension target.",
                markCommandFailed: false
            )
            return
        }

        if !sent {
            failPendingBrowserMute(
                targetID: target.id,
                title: "Browser Command Failed",
                message: "Keyway could not reach \(target.appName).",
                markCommandFailed: true
            )
        }
    }

    func browserMuteState(for target: MediaRemoteTarget) -> BrowserMuteState? {
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        if let pending = pendingBrowserMutesByTargetID[target.id] {
            return BrowserMuteState(muted: pending.expectedMuted, isPending: true)
        }
        return BrowserMuteState(muted: confirmedBrowserMuted(target: target), isPending: false)
    }

    private func submitBrowserAudioCommand(
        _ command: ChromiumBrowserAudioCommand,
        target: MediaRemoteTarget
    ) {
        guard let sent = chromiumBrowserExtensionController.submit(audioCommand: command, target: target, onResult: { [mediaSourceStore] result in
            mediaSourceStore?.recordCommandResult(result)
            if result.ok {
                StatusHUD.shared.finish(
                    title: "\(target.appName) \(command.displayName)",
                    message: result.message,
                    dismissAfter: 1.6
                )
            } else {
                StatusHUD.shared.finish(
                    title: result.unsupported ? "Browser Command Unsupported" : "Browser Command Failed",
                    message: result.message,
                    dismissAfter: 2.2
                )
            }
        }) else {
            StatusHUD.shared.finish(
                title: "Browser Command Unsupported",
                message: "\(target.appName) is not a Chromium extension target.",
                dismissAfter: 2.2
            )
            return
        }

        if !sent {
            mediaSourceStore?.markCommandFailed(targetID: target.id)
            StatusHUD.shared.finish(
                title: "Browser Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
        }
    }

    private func sonosPresentation() async -> MediaAudioControlPresentation {
        let target = sonosVolumeTarget()

        do {
            let status: SpeakerVolumeStatus
            switch target.scope {
            case .member:
                status = try await volumeCommands.volumeStatus(using: volumeService, roomName: target.roomName)
            case .group:
                status = try await volumeCommands.groupVolumeStatus(using: volumeService, coordinatorRoomName: target.roomName)
            }
            return MediaAudioControlPresentation(
                title: "Sonos",
                detail: "\(status.roomName) \(status.muted ? "muted" : "volume \(status.volume)%")",
                volume: status.volume,
                muted: status.muted,
                isEnabled: true
            )
        } catch {
            return MediaAudioControlPresentation.disabled(title: "Sonos", detail: "\(target.roomName): \(error.localizedDescription)")
        }
    }

    private func spotifyPresentation() async -> MediaAudioControlPresentation {
        do {
            guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus() else {
                return .disabled(title: "Spotify", detail: "No active playback device")
            }
            guard let volume = status.volumePercent else {
                return .disabled(title: "Spotify", detail: "\(status.deviceName): volume unavailable")
            }
            return MediaAudioControlPresentation(
                title: "Spotify",
                detail: "\(status.deviceName) volume \(volume)%",
                volume: volume,
                muted: nil,
                isEnabled: true
            )
        } catch {
            return .disabled(title: "Spotify", detail: error.localizedDescription)
        }
    }

    private func browserPresentation(for target: MediaRemoteTarget?) -> MediaAudioControlPresentation {
        guard let target, target.isBrowserLike else {
            return .disabled(title: "Browser", detail: "Select a browser media target")
        }
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            return .disabled(title: "Browser", detail: "Select a Chromium extension target")
        }
        if let mediaSourceStore {
            guard let row = mediaSourceStore.rows.first(where: { $0.id == target.id }) else {
                return .disabled(title: "Browser", detail: "Target not available")
            }
            guard !row.reachability.isSuspect else {
                return .disabled(title: "Browser", detail: "Browser not responding")
            }
        }
        guard chromiumBrowserExtensionController.connected else {
            return .disabled(title: "Browser", detail: "Extension disconnected")
        }

        return MediaAudioControlPresentation(
            title: "Browser",
            detail: target.detailText,
            volume: nil,
            muted: browserMuteState(for: target)?.muted,
            isEnabled: true,
            isPending: pendingBrowserMutesByTargetID[target.id] != nil
        )
    }

    private func confirmedBrowserMuted(target: MediaRemoteTarget) -> Bool {
        if let row = mediaSourceStore?.rows.first(where: { $0.id == target.id }) {

            return row.target.muted == true
        }

        return target.muted == true
    }

    private func beginPendingBrowserMute(target: MediaRemoteTarget, expectedMuted: Bool) {
        pendingBrowserMutesByTargetID[target.id]?.timeoutTask?.cancel()
        let startedAt = Date()
        pendingBrowserMutesByTargetID[target.id] = PendingBrowserMute(
            expectedMuted: expectedMuted,
            appName: target.appName,
            startedAt: startedAt,
            timeoutTask: nil
        )
        let targetID = target.id
        pendingBrowserMutesByTargetID[targetID]?.timeoutTask = Task { @MainActor [weak self] in
            guard let self,
                  (try? await Task.sleep(nanoseconds: self.browserMuteConfirmationTimeoutNanoseconds)) != nil,
                  let pending = self.pendingBrowserMutesByTargetID[targetID],
                  pending.startedAt == startedAt
            else {
                return
            }
            self.pendingBrowserMutesByTargetID.removeValue(forKey: targetID)
            self.mediaSourceStore?.markCommandFailed(targetID: targetID)
            StatusHUD.shared.finish(
                title: "Browser Command Failed",
                message: "Keyway could not confirm \(pending.appName) mute.",
                dismissAfter: 2.2
            )
        }
    }

    private func confirmPendingBrowserMutes(rows: [SourceRow]) {
        for row in rows {
            guard let pending = pendingBrowserMutesByTargetID[row.id],
                  (row.target.muted == true) == pending.expectedMuted
            else {
                continue
            }
            pending.timeoutTask?.cancel()
            pendingBrowserMutesByTargetID.removeValue(forKey: row.id)
            StatusHUD.shared.finish(
                title: "\(pending.appName) Mute",
                message: pending.expectedMuted ? "Muted" : "Unmuted",
                dismissAfter: 1.6
            )
        }
    }

    private func failPendingBrowserMute(
        targetID: String,
        title: String,
        message: String,
        markCommandFailed: Bool
    ) {
        pendingBrowserMutesByTargetID[targetID]?.timeoutTask?.cancel()
        pendingBrowserMutesByTargetID.removeValue(forKey: targetID)
        if markCommandFailed {
            mediaSourceStore?.markCommandFailed(targetID: targetID)
        }
        StatusHUD.shared.finish(
            title: title,
            message: message,
            dismissAfter: 2.2
        )
    }

    private func sonosVolumeTarget() -> (roomName: String, scope: PlaybackVolumeScope) {
        if let roomName = SonosRoomName.normalized(outputSelection.roomName) {
            return (roomName, volumeScope(roomName: roomName))
        }

        return ("Port", .member)
    }

    private func volumeScope(roomName: String) -> PlaybackVolumeScope {
        guard let selectedGroup = outputSelection.selectedGroup,
              selectedGroup.contains(roomName: roomName),
              selectedGroup.members.count > 1
        else {
            return .member
        }

        return .group
    }
}
