@preconcurrency import AppKit
import ApplicationServices
import Combine
import os
import SonosHandoffCore

@MainActor
final class VolumeHotkeyController {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let volumeActions: ShortcutVolumeActionController
    private let mediaRemoteController: MediaRemoteController
    private let mediaSourceStore: MediaSourceStore
    private let mediaTransportActions: MediaTransportActionController
    private let runtimeReporter: ShortcutRuntimeReporter
    private let runtimeStatus = ShortcutRuntimeStatus.shared
    private var lastVolumeInput: (direction: VolumeDirection, timestamp: CFAbsoluteTime)?
    private var lastMuteInputTimestamp: CFAbsoluteTime?
    private var repeatTimer: DispatchSourceTimer?
    private var permissionRetryTimer: DispatchSourceTimer?
    private var mediaRemoteHealthCancellable: AnyCancellable?
    private var mediaPlaybackCancellable: AnyCancellable?
    private var lastReportedPermissionState: (accessibilityGranted: Bool, listenEventGranted: Bool)?
    private var activeMediaRemoteGeneration: UInt?
    private var repeatingDirection: VolumeDirection?
    private var isSonosVolumeInputEnabled = false
    private var isTransportInputReady = false
    private var isStarted = false
    private let eventParser = ShortcutEventParser()

    private let step = SpeakerVolumeControlDefaults.step
    private var activeTapName: String {
        eventTap.activeTapKind?.rawValue ?? "none"
    }

    private lazy var carbonRegistrar = ShortcutCarbonHotKeyRegistrar { [weak self] id in
        self?.handleCarbonHotKey(id: id)
    }
    private lazy var eventTap = ShortcutEventTap(
        onInterrupted: { [weak self] type in
            self?.resetInputStateAfterTapInterruption(type: type)
        },
        onEvent: { [weak self] tapKind, type, event in
            self?.handle(tapKind: tapKind, type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
    )
    private lazy var commandCenterInterceptor = MediaCommandCenterInterceptor { [weak self] command, metadata in
        guard let self,
              self.isTransportInputReady,
              let activeMediaRemoteGeneration = self.activeMediaRemoteGeneration,
              self.mediaRemoteController.helperGeneration == activeMediaRemoteGeneration
        else {
            return
        }
        self.mediaTransportActions.routeFromCommandCenter(command: command, metadata: metadata)
    }

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        mediaRemoteController: MediaRemoteController,
        mediaSourceStore: MediaSourceStore,
        mediaTransportActions: MediaTransportActionController,
        volumeCommands: SpeakerVolumeCommandQueue = .shared,
        runtimeReporter: ShortcutRuntimeReporter = ShortcutRuntimeReporter()
    ) {
        self.volumeActions = ShortcutVolumeActionController(
            volumeService: volumeService,
            outputSelection: outputSelection,
            activePlaybackObserver: activePlaybackObserver,
            volumeCommands: volumeCommands
        )
        self.mediaRemoteController = mediaRemoteController
        self.mediaSourceStore = mediaSourceStore
        self.mediaTransportActions = mediaTransportActions
        self.runtimeReporter = runtimeReporter
    }

    deinit {
        MainActor.assumeIsolated {
            repeatTimer?.cancel()
            permissionRetryTimer?.cancel()
            commandCenterInterceptor.stop()
            eventTap.stop()
            carbonRegistrar.stop()
        }
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        mediaPlaybackCancellable = mediaSourceStore.$rows
            .map { rows in rows.contains { $0.target.isCurrentlyPlaying } }
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                self?.commandCenterInterceptor.updatePlaybackState(isPlaying: isPlaying)
            }
        mediaRemoteHealthCancellable = Publishers.CombineLatest(
            mediaRemoteController.$health,
            mediaRemoteController.$helperGeneration
        )
        .sink { [weak self] health, generation in
            self?.mediaRemoteHealthChanged(health, generation: generation)
        }
        refreshMediaFallback()
    }

    func setSonosVolumeInputEnabled(_ enabled: Bool) {
        guard isSonosVolumeInputEnabled != enabled else {
            return
        }
        isSonosVolumeInputEnabled = enabled
        guard enabled else {
            stopVolumeRepeat()
            carbonRegistrar.stop()
            runtimeReporter.plainHotkeysRegistered(false)
            refreshEventTap()
            return
        }
        if isStarted {
            refreshMediaFallback()
        }
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        mediaRemoteHealthCancellable?.cancel()
        mediaRemoteHealthCancellable = nil
        mediaPlaybackCancellable?.cancel()
        mediaPlaybackCancellable = nil
        activeMediaRemoteGeneration = nil
        isTransportInputReady = false
        stopVolumeRepeat()
        stopPermissionRetry()
        mediaTransportActions.resetMediaKeyState()
        commandCenterInterceptor.stop()
        eventTap.stop()
        carbonRegistrar.stop()
        lastVolumeInput = nil
        lastMuteInputTimestamp = nil
        lastReportedPermissionState = nil
    }

    @discardableResult
    func refreshMediaFallback() -> Bool {
        let accessibilityGranted = AXIsProcessTrusted()
        let listenEventGranted = CGPreflightListenEventAccess()
        lastReportedPermissionState = (accessibilityGranted, listenEventGranted)
        guard accessibilityGranted, listenEventGranted else {
            if eventTap.isRunning {
                eventTap.stop()
            }
            carbonRegistrar.stop()
            runtimeReporter.plainHotkeysRegistered(false)
            isTransportInputReady = false
            mediaTransportActions.resetMediaKeyState()
            commandCenterInterceptor.stop()
            logger.error("SonosHandoffHotkeys mediaFallback=disabled reason=permission_denied accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public) appPath=\(Bundle.main.bundlePath, privacy: .public)")
            runtimeReporter.mediaFallbackPermissionDenied(
                accessibilityGranted: accessibilityGranted,
                listenEventGranted: listenEventGranted
            )
            StatusHUD.shared.finish(
                title: "Media Keys Blocked",
                message: permissionMessage(
                    accessibilityGranted: accessibilityGranted,
                    listenEventGranted: listenEventGranted
                ),
                dismissAfter: 4
            )
            schedulePermissionRetry()
            return false
        }

        if isSonosVolumeInputEnabled {
            let registered = carbonRegistrar.installHandlerIfNeeded()
                && carbonRegistrar.registerPlainFunctionHotKeys(step: step)
            runtimeReporter.plainHotkeysRegistered(registered)
        } else {
            carbonRegistrar.stop()
            runtimeReporter.plainHotkeysRegistered(false)
        }

        guard mediaRemoteController.isHelperPairReady else {
            activeMediaRemoteGeneration = nil
            isTransportInputReady = false
            commandCenterInterceptor.stop()
            guard refreshEventTap() else {
                reportEventTapFailure(
                    accessibilityGranted: accessibilityGranted,
                    listenEventGranted: listenEventGranted
                )
                return false
            }
            runtimeReporter.mediaFallbackWaitingForHelper(
                accessibilityGranted: accessibilityGranted,
                listenEventGranted: listenEventGranted,
                eventTapRunning: eventTap.isRunning,
                activeEventTap: eventTap.activeTapKind?.rawValue,
                fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered
            )
            schedulePermissionRetry()
            return false
        }

        let helperGeneration = mediaRemoteController.helperGeneration
        if activeMediaRemoteGeneration != helperGeneration {
            activeMediaRemoteGeneration = helperGeneration
            isTransportInputReady = false
            mediaTransportActions.resetMediaKeyState()
            commandCenterInterceptor.stop()
        }

        runtimeReporter.mediaFallbackStarting(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted
        )
        logger.info("SonosHandoffHotkeys mediaFallback=starting accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public)")
        guard refreshEventTap() else {
            reportEventTapFailure(
                accessibilityGranted: accessibilityGranted,
                listenEventGranted: listenEventGranted
            )
            return false
        }
        commandCenterInterceptor.start()
        isTransportInputReady = true

        stopPermissionRetry()
        logger.info("SonosHandoffHotkeys mediaFallback=enabled input=event_tap_and_hidden_command_center")
        runtimeReporter.mediaFallbackEnabled(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered,
            activeEventTap: eventTap.activeTapKind?.rawValue
        )
        return true
    }

    private func mediaRemoteHealthChanged(_ health: MediaRemoteHelperHealth, generation: UInt) {
        guard isStarted else {
            return
        }
        guard health.state == .running else {
            guard activeMediaRemoteGeneration != nil
                    || isTransportInputReady
            else {
                return
            }
            activeMediaRemoteGeneration = nil
            isTransportInputReady = false
            mediaTransportActions.resetMediaKeyState()
            commandCenterInterceptor.stop()
            refreshEventTap()
            runtimeReporter.mediaFallbackWaitingForHelper(
                accessibilityGranted: AXIsProcessTrusted(),
                listenEventGranted: CGPreflightListenEventAccess(),
                eventTapRunning: eventTap.isRunning,
                activeEventTap: eventTap.activeTapKind?.rawValue,
                fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered
            )
            schedulePermissionRetry()
            return
        }
        guard activeMediaRemoteGeneration != generation else {
            return
        }
        activeMediaRemoteGeneration = generation
        _ = refreshMediaFallback()
    }

    @discardableResult
    private func refreshEventTap() -> Bool {
        let shouldRun = isStarted
            && AXIsProcessTrusted()
            && CGPreflightListenEventAccess()
            && (isSonosVolumeInputEnabled || activeMediaRemoteGeneration != nil)
        guard shouldRun else {
            eventTap.stop()
            return true
        }
        return eventTap.isRunning || eventTap.start()
    }

    private func reportEventTapFailure(
        accessibilityGranted: Bool,
        listenEventGranted: Bool
    ) {
        isTransportInputReady = false
        mediaTransportActions.resetMediaKeyState()
        commandCenterInterceptor.stop()
        logger.error("SonosHandoffHotkeys input=disabled reason=event_tap_create_failed accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public) appPath=\(Bundle.main.bundlePath, privacy: .public)")
        runtimeReporter.eventTapCreateFailed(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted
        )
        StatusHUD.shared.finish(
            title: "Media Keys Blocked",
            message: "Enable Keyway in Accessibility and Input Monitoring.",
            dismissAfter: 4
        )
        schedulePermissionRetry()
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isTransportInputReady else {
                self?.stopPermissionRetry()
                return
            }

            let accessibilityGranted = AXIsProcessTrusted()
            let listenEventGranted = CGPreflightListenEventAccess()
            guard accessibilityGranted, listenEventGranted else {
                if self.lastReportedPermissionState?.accessibilityGranted != accessibilityGranted
                    || self.lastReportedPermissionState?.listenEventGranted != listenEventGranted {
                    self.lastReportedPermissionState = (accessibilityGranted, listenEventGranted)
                    self.runtimeReporter.mediaFallbackPermissionDenied(
                        accessibilityGranted: accessibilityGranted,
                        listenEventGranted: listenEventGranted
                    )
                }
                return
            }

            _ = self.refreshMediaFallback()
        }
        permissionRetryTimer = timer
        timer.resume()
    }

    private func stopPermissionRetry() {
        permissionRetryTimer?.cancel()
        permissionRetryTimer = nil
    }

    private func permissionMessage(accessibilityGranted: Bool, listenEventGranted: Bool) -> String {
        if !accessibilityGranted, !listenEventGranted {
            return "Enable Keyway in Accessibility and Input Monitoring."
        }
        if !accessibilityGranted {
            return "Enable Keyway in Accessibility."
        }
        if !listenEventGranted {
            return "Enable Keyway in Input Monitoring."
        }
        return "Refresh media-key permissions."
    }

    func handle(tapKind: ShortcutEventTap.TapKind, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let outcome = eventParser.outcome(type: type, event: event, isRepeating: repeatingDirection != nil)
        if tapKind == .session {
            switch outcome {
            case .transportKeyDown, .transportKeyUp:
                break
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        switch outcome {
        case .passThrough:
            if let diagnostic = eventParser.unhandledSystemDefinedDiagnostic(type: type, event: event) {
                traceUnhandledSystemDefined(diagnostic)
            }
            logger.debug("SonosHandoffHotkeys decision=pass eventType=\(type.rawValue, privacy: .public)")
            return Unmanaged.passUnretained(event)
        case .transportKeyDown(let command, let source, let metadata):
            guard isTransportInputReady,
                  let helperGeneration = activeMediaRemoteGeneration
            else {
                return Unmanaged.passUnretained(event)
            }
            if let reason = mediaTransportActions.ignoreReasonForMediaKeyDown(
                command: command,
                metadata: metadata
            ) {
                logger.info("SonosHandoffHotkeys \(reason.rawValue, privacy: .public) phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(tapKind.rawValue, privacy: .public) eventTimestamp=\(metadata.eventTimestamp, privacy: .public)")
                traceTransportKey(reason.rawValue, command: command, source: source, metadata: metadata, tapKind: tapKind)
                return nil
            }
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(tapKind.rawValue, privacy: .public)")
            traceTransportKey("transport_key_down", command: command, source: source, metadata: metadata, tapKind: tapKind)
            Task { @MainActor [weak self] in
                guard let self,
                      self.isTransportInputReady,
                      self.activeMediaRemoteGeneration == helperGeneration,
                      self.mediaRemoteController.helperGeneration == helperGeneration
                else {
                    return
                }
                self.mediaTransportActions.routeFromMediaKey(command: command, metadata: metadata)
            }
            return nil
        case .transportKeyUp(let command, let source, let metadata):
            guard isTransportInputReady,
                  activeMediaRemoteGeneration == mediaRemoteController.helperGeneration
            else {
                return Unmanaged.passUnretained(event)
            }
            logger.info("SonosHandoffHotkeys decision=swallow phase=up action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(tapKind.rawValue, privacy: .public)")
            traceTransportKey("transport_key_up", command: command, source: source, metadata: metadata, tapKind: tapKind)
            mediaTransportActions.noteMediaKeyUp(command: command)
            return nil
        case .volumeHoldStart(let direction, let source):
            guard isSonosVolumeInputEnabled else {
                return Unmanaged.passUnretained(event)
            }
            let now = CFAbsoluteTimeGetCurrent()
            let dispatchInitial = lastVolumeInput.map {
                $0.direction != direction || now - $0.timestamp >= 0.15
            } ?? true
            lastVolumeInput = (direction, now)
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)_hold_start tap=\(self.activeTapName, privacy: .public)")
            if !dispatchInitial {
                logger.info("SonosHandoffHotkeys duplicate=ignored action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)")
            }
            startVolumeRepeat(direction: direction, source: source, dispatchInitial: dispatchInitial)
            return nil
        case .volumeHoldStop(let source):
            guard isSonosVolumeInputEnabled else {
                return Unmanaged.passUnretained(event)
            }
            logger.info("SonosHandoffHotkeys decision=swallow phase=up action=volume_hold_stop source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            stopVolumeRepeat()
            return nil
        case .muteToggle(let source):
            guard isSonosVolumeInputEnabled else {
                return Unmanaged.passUnretained(event)
            }
            let now = CFAbsoluteTimeGetCurrent()
            if let lastMuteInputTimestamp, now - lastMuteInputTimestamp < 0.15 {
                logger.info("SonosHandoffHotkeys duplicate=ignored action=mute_toggle source=\(source, privacy: .public)")
                return nil
            }
            lastMuteInputTimestamp = now
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=mute_toggle source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            toggleMute()
            return nil
        }
    }

    private func resetInputStateAfterTapInterruption(type: CGEventType) {
        mediaTransportActions.resetMediaKeyState()
        stopVolumeRepeat()
        logger.error("SonosHandoffHotkeys input_state_reset reason=event_tap_interrupted eventType=\(type.rawValue, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
        guard eventTap.isRunning else {
            isTransportInputReady = false
            commandCenterInterceptor.stop()
            runtimeReporter.eventTapUnavailable(
                accessibilityGranted: AXIsProcessTrusted(),
                listenEventGranted: CGPreflightListenEventAccess()
            )
            schedulePermissionRetry()
            return
        }
    }

    private func traceTransportKey(
        _ event: String,
        command: MediaRemoteTransportCommand,
        source: String,
        metadata: MediaTransportInputMetadata,
        tapKind: ShortcutEventTap.TapKind
    ) {
        runtimeStatus.recordMediaTransportEvent(
            event,
            fields: [
                "command": command.rawValue,
                "source": source,
                "tap": tapKind.rawValue,
                "eventSourceUnixProcessID": metadata.sourceUnixProcessID,
                "eventSourceStateID": metadata.sourceStateID,
                "eventSourceUserData": metadata.sourceUserData,
                "eventTargetUnixProcessID": metadata.targetUnixProcessID,
                "eventSourceUserID": metadata.sourceUserID,
                "eventSourceGroupID": metadata.sourceGroupID,
                "eventTimestamp": metadata.eventTimestamp,
                "eventSourceIsPhysicalHIDSystem": metadata.isPhysicalHIDSystemSource,
                "eventSourceIsUntargetedPhysicalHIDSystem": metadata.isUntargetedPhysicalHIDSystemSource,
                "eventTapRunning": eventTap.isRunning,
            ]
        )
    }

    private func traceUnhandledSystemDefined(_ diagnostic: ShortcutEventDiagnostic) {
        let metadata = diagnostic.metadata
        runtimeStatus.recordMediaTransportEvent(
            "event_tap_unhandled_system_defined",
            fields: [
                "eventType": diagnostic.eventType,
                "eventSubtype": diagnostic.subtype,
                "eventData1": diagnostic.data1,
                "mediaKeyCode": diagnostic.keyCode,
                "mediaKeyState": diagnostic.keyState,
                "tap": activeTapName,
                "eventSourceUnixProcessID": metadata.sourceUnixProcessID,
                "eventSourceStateID": metadata.sourceStateID,
                "eventSourceUserData": metadata.sourceUserData,
                "eventTargetUnixProcessID": metadata.targetUnixProcessID,
                "eventSourceUserID": metadata.sourceUserID,
                "eventSourceGroupID": metadata.sourceGroupID,
                "eventTimestamp": metadata.eventTimestamp,
                "eventSourceIsPhysicalHIDSystem": metadata.isPhysicalHIDSystemSource,
                "eventSourceIsUntargetedPhysicalHIDSystem": metadata.isUntargetedPhysicalHIDSystemSource,
                "eventTapRunning": eventTap.isRunning,
            ]
        )
    }

    private func startVolumeRepeat(direction: VolumeDirection, source: String, dispatchInitial: Bool) {
        if repeatingDirection == direction {
            return
        }

        stopVolumeRepeat()
        repeatingDirection = direction
        if dispatchInitial {
            volumeActions.adjustVolume(direction: direction)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.22, repeating: 0.09)
        timer.setEventHandler { [weak self] in
            guard let self, self.repeatingDirection == direction else {
                return
            }
            self.logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)_hold_repeat")
            self.volumeActions.adjustVolume(direction: direction)
        }
        repeatTimer = timer
        timer.resume()
    }

    private func stopVolumeRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
        repeatingDirection = nil
        volumeActions.clearQueuedVolumeAdjustment()
    }

    private func toggleMute() {
        stopVolumeRepeat()
        volumeActions.toggleMute()
    }

    func handleCarbonHotKey(id: UInt32) {
        guard isStarted, isSonosVolumeInputEnabled else {
            return
        }
        let direction: VolumeDirection
        let source: String
        switch id {
        case 1:
            direction = .down
            source = "carbon_shift_f11"
        case 2:
            direction = .up
            source = "carbon_shift_f12"
        case 5:
            let now = CFAbsoluteTimeGetCurrent()
            if let lastMuteInputTimestamp, now - lastMuteInputTimestamp < 0.15 {
                logger.info("SonosHandoffHotkeys duplicate=ignored action=mute_toggle source=carbon_shift_f10")
                return
            }
            lastMuteInputTimestamp = now
            logger.info("SonosHandoffHotkeys action=mute_toggle source=carbon_shift_f10")
            toggleMute()
            return
        default:
            logger.info("SonosHandoffHotkeys carbon=ignored id=\(id, privacy: .public)")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if let lastVolumeInput,
           lastVolumeInput.direction == direction,
           now - lastVolumeInput.timestamp < 0.15 {
            logger.info("SonosHandoffHotkeys duplicate=ignored action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)")
            return
        }

        lastVolumeInput = (direction, now)
        logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)")
        volumeActions.adjustVolume(direction: direction)
    }
}
