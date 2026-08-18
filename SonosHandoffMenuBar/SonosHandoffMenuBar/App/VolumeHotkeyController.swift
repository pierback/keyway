@preconcurrency import AppKit
import ApplicationServices
import Combine
import os
import SonosHandoffCore

@MainActor
final class VolumeHotkeyController {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let volumeActions: ShortcutVolumeActionController
    private let mediaSourceStore: MediaSourceStore
    private let mediaRemoteController: MediaRemoteController
    private let mediaTransportActions: MediaTransportActionController
    private let runtimeReporter: ShortcutRuntimeReporter
    private let runtimeStatus = ShortcutRuntimeStatus.shared
    private var lastVolumeInput: (direction: VolumeDirection, timestamp: CFAbsoluteTime)?
    private var lastMuteInputTimestamp: CFAbsoluteTime?
    private var repeatTimer: DispatchSourceTimer?
    private var permissionRetryTimer: DispatchSourceTimer?
    private var mediaRemoteHealthCancellable: AnyCancellable?
    private var lastReportedPermissionState: (accessibilityGranted: Bool, listenEventGranted: Bool)?
    private var activeMediaRemoteGeneration: UInt?
    private var repeatingDirection: VolumeDirection?
    private var isSonosVolumeInputEnabled = false
    private var isTransportInputReady = false
    private var isStoppingCommandCenterRoute = false
    private var isCommandCenterRouteSuspended = false
    private var isStarted = false
    private let eventParser = ShortcutEventParser()
    private lazy var commandCenterInterceptor = MediaCommandCenterInterceptor(
        mediaSourceStore: mediaSourceStore,
        mediaRemoteController: mediaRemoteController,
        readinessChanged: { [weak self] ready in
            self?.commandCenterReadinessChanged(ready)
        }
    ) { [weak self] command, metadata in
        guard let self else { return }
        self.mediaTransportActions.routeFromCommandCenter(command: command, metadata: metadata)
    }

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
        onEvent: { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
    )

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        mediaSourceStore: MediaSourceStore,
        mediaRemoteController: MediaRemoteController,
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
        self.mediaSourceStore = mediaSourceStore
        self.mediaRemoteController = mediaRemoteController
        self.mediaTransportActions = mediaTransportActions
        self.runtimeReporter = runtimeReporter
    }

    deinit {
        MainActor.assumeIsolated {
            repeatTimer?.cancel()
            permissionRetryTimer?.cancel()
            isStoppingCommandCenterRoute = true
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
        activeMediaRemoteGeneration = nil
        isTransportInputReady = false
        stopVolumeRepeat()
        stopPermissionRetry()
        mediaTransportActions.resetMediaKeyState()
        stopCommandCenterRoute(reason: "runtime_stopped")
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
            stopCommandCenterRoute(reason: "permission_denied")
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
            stopCommandCenterRoute(reason: "mediaremote_unavailable")
            guard refreshEventTap() else {
                reportEventTapFailure(
                    accessibilityGranted: accessibilityGranted,
                    listenEventGranted: listenEventGranted
                )
                return false
            }
            runtimeReporter.commandCenterRouteFailed(
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
            stopCommandCenterRoute(reason: "mediaremote_generation_changed")
        }

        runtimeReporter.mediaFallbackStarting(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted
        )
        logger.info("SonosHandoffHotkeys mediaFallback=starting accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public)")
        guard ensureCommandCenterRoute(reason: "mediaremote_generation_ready") else {
            failCommandCenterRoute()
            return false
        }
        guard refreshEventTap() else {
            reportEventTapFailure(
                accessibilityGranted: accessibilityGranted,
                listenEventGranted: listenEventGranted
            )
            return false
        }

        if isTransportInputReady {
            stopPermissionRetry()
            logger.info("SonosHandoffHotkeys mediaFallback=enabled state=acknowledged")
            runtimeReporter.mediaFallbackAlreadyRunning(
                fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered,
                activeEventTap: eventTap.activeTapKind?.rawValue
            )
            return true
        }

        runtimeReporter.mediaFallbackWaitingForCommandCenter(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            eventTapRunning: eventTap.isRunning,
            activeEventTap: eventTap.activeTapKind?.rawValue,
            fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered
        )
        schedulePermissionRetry()
        return false
    }

    private func ensureCommandCenterRoute(reason: String) -> Bool {
        if commandCenterInterceptor.running {
            logger.info("SonosHandoffHotkeys commandCenterRoute=already_enabled reason=\(reason, privacy: .public)")
            return true
        }
        guard let activeMediaRemoteGeneration else {
            return false
        }
        let starting = commandCenterInterceptor.start(
            helperGeneration: activeMediaRemoteGeneration
        )
        if starting {
            logger.info("SonosHandoffHotkeys commandCenterRoute=enabled reason=\(reason, privacy: .public)")
        } else {
            logger.error("SonosHandoffHotkeys commandCenterRoute=failed reason=\(reason, privacy: .public)")
        }
        return starting
    }

    private func stopCommandCenterRoute(reason: String) {
        isCommandCenterRouteSuspended = false
        guard commandCenterInterceptor.running else {
            logger.info("SonosHandoffHotkeys commandCenterRoute=already_disabled reason=\(reason, privacy: .public)")
            runtimeReporter.commandCenterRouteRunning(false)
            return
        }
        isStoppingCommandCenterRoute = true
        commandCenterInterceptor.stop()
        isStoppingCommandCenterRoute = false
        isTransportInputReady = false
        runtimeReporter.commandCenterRouteRunning(false)
        logger.info("SonosHandoffHotkeys commandCenterRoute=disabled reason=\(reason, privacy: .public)")
    }

    private func commandCenterReadinessChanged(_ ready: Bool) {
        guard !isStoppingCommandCenterRoute else {
            isTransportInputReady = false
            runtimeReporter.commandCenterRouteRunning(false)
            refreshEventTap()
            return
        }
        guard !isCommandCenterRouteSuspended else {
            isTransportInputReady = false
            runtimeReporter.commandCenterRouteRunning(false)
            refreshEventTap()
            return
        }
        guard ready else {
            isTransportInputReady = false
            failCommandCenterRoute()
            return
        }
        guard let activeMediaRemoteGeneration,
              mediaRemoteController.helperGeneration == activeMediaRemoteGeneration
        else {
            failCommandCenterRoute()
            return
        }
        isTransportInputReady = true
        guard refreshEventTap() else {
            reportEventTapFailure(
                accessibilityGranted: AXIsProcessTrusted(),
                listenEventGranted: CGPreflightListenEventAccess()
            )
            stopCommandCenterRoute(reason: "event_tap_not_running")
            return
        }

        stopPermissionRetry()
        runtimeReporter.mediaFallbackEnabled(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess(),
            fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered,
            activeEventTap: eventTap.activeTapKind?.rawValue
        )
    }

    private func mediaRemoteHealthChanged(_ health: MediaRemoteHelperHealth, generation: UInt) {
        guard isStarted else {
            return
        }
        guard health.state == .running else {
            guard activeMediaRemoteGeneration != nil
                    || eventTap.isRunning
                    || commandCenterInterceptor.running
            else {
                return
            }
            activeMediaRemoteGeneration = nil
            isTransportInputReady = false
            mediaTransportActions.resetMediaKeyState()
            stopCommandCenterRoute(reason: "mediaremote_generation_ended")
            refreshEventTap()
            schedulePermissionRetry()
            return
        }
        guard activeMediaRemoteGeneration != generation else {
            return
        }
        activeMediaRemoteGeneration = generation
        _ = refreshMediaFallback()
    }

    private func failCommandCenterRoute() {
        isTransportInputReady = false
        stopCommandCenterRoute(reason: "route_unavailable")
        refreshEventTap()
        runtimeReporter.commandCenterRouteFailed(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess(),
            eventTapRunning: eventTap.isRunning,
            activeEventTap: eventTap.activeTapKind?.rawValue,
            fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered
        )
        schedulePermissionRetry()
    }

    @discardableResult
    private func refreshEventTap() -> Bool {
        let shouldRun = isStarted
            && AXIsProcessTrusted()
            && CGPreflightListenEventAccess()
            && (isSonosVolumeInputEnabled || isTransportInputReady)
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
        stopCommandCenterRoute(reason: "event_tap_create_failed")
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

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch eventParser.outcome(type: type, event: event, isRepeating: repeatingDirection != nil) {
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
                logger.info("SonosHandoffHotkeys \(reason.rawValue, privacy: .public) phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public) eventTimestamp=\(metadata.eventTimestamp, privacy: .public)")
                traceTransportKey(reason.rawValue, command: command, source: source, metadata: metadata)
                return nil
            }
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            traceTransportKey("transport_key_down", command: command, source: source, metadata: metadata)
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
            logger.info("SonosHandoffHotkeys decision=swallow phase=up action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            traceTransportKey("transport_key_up", command: command, source: source, metadata: metadata)
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

    func suspendCommandCenterRouteShield(
        reason: String,
        helperGeneration: UInt,
        onResult: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard activeMediaRemoteGeneration == helperGeneration,
              mediaRemoteController.helperGeneration == helperGeneration
        else {
            return false
        }
        isCommandCenterRouteSuspended = true
        let started = commandCenterInterceptor.suspendRouteShield(
            reason: reason,
            helperGeneration: helperGeneration
        ) { [weak self] succeeded in
            guard let self else {
                return
            }
            if !succeeded {
                self.isCommandCenterRouteSuspended = false
                self.failCommandCenterRoute()
            }
            onResult(succeeded)
        }
        if !started {
            isCommandCenterRouteSuspended = false
            failCommandCenterRoute()
        }
        return started
    }

    func rearmCommandCenterRouteShield(
        reason: String,
        helperGeneration: UInt
    ) -> Bool {
        guard isCommandCenterRouteSuspended,
              activeMediaRemoteGeneration == helperGeneration,
              mediaRemoteController.helperGeneration == helperGeneration
        else {
            return false
        }
        isCommandCenterRouteSuspended = false
        guard commandCenterInterceptor.resumeRouteShield(
            reason: reason,
            helperGeneration: helperGeneration
        ) else {
            failCommandCenterRoute()
            return false
        }
        runtimeReporter.mediaFallbackWaitingForCommandCenter(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess(),
            eventTapRunning: eventTap.isRunning,
            activeEventTap: eventTap.activeTapKind?.rawValue,
            fnHotkeysRegistered: carbonRegistrar.plainHotkeysRegistered
        )
        return true
    }

    private func resetInputStateAfterTapInterruption(type: CGEventType) {
        mediaTransportActions.resetMediaKeyState()
        stopVolumeRepeat()
        logger.error("SonosHandoffHotkeys input_state_reset reason=event_tap_interrupted eventType=\(type.rawValue, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
        guard eventTap.isRunning else {
            stopCommandCenterRoute(reason: "event_tap_reenable_failed")
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
        metadata: MediaTransportInputMetadata
    ) {
        runtimeStatus.recordMediaTransportEvent(
            event,
            fields: [
                "command": command.rawValue,
                "source": source,
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
                "commandCenterRouteRunning": commandCenterInterceptor.running,
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
                "commandCenterRouteRunning": commandCenterInterceptor.running,
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
