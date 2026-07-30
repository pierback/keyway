@preconcurrency import AppKit
import ApplicationServices
import os
import SonosHandoffCore

@MainActor
final class VolumeHotkeyController {
    private static let commandCenterRouteShieldRearmDelayNanoseconds: UInt64 = 600_000_000

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let volumeActions: ShortcutVolumeActionController
    private let mediaSourceStore: MediaSourceStore
    private let mediaRemoteController: MediaRemoteController
    private let mediaTransportActions: MediaTransportActionController
    private let runtimeReporter: ShortcutRuntimeReporter
    private let runtimeStatus = ShortcutRuntimeStatus.shared
    private var lastCarbonAction: (direction: VolumeDirection, timestamp: CFAbsoluteTime)?
    private var repeatTimer: DispatchSourceTimer?
    private var permissionRetryTimer: DispatchSourceTimer?
    private var commandCenterRouteShieldRearmTask: Task<Void, Error>?
    private var lastReportedPermissionState: (accessibilityGranted: Bool, listenEventGranted: Bool)?
    private var repeatingDirection: VolumeDirection?
    private var isStoppingCommandCenterRoute = false
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
            commandCenterRouteShieldRearmTask?.cancel()
            isStoppingCommandCenterRoute = true
            commandCenterInterceptor.stop()
            eventTap.stop()
            carbonRegistrar.stop()
        }
    }

    func start() {
        if carbonRegistrar.installHandlerIfNeeded() {
            let registered = carbonRegistrar.registerPlainFunctionHotKeys(step: step)
            runtimeReporter.plainHotkeysRegistered(registered)
        }
        refreshMediaFallback()
    }

    func stop() {
        stopVolumeRepeat()
        stopPermissionRetry()
        commandCenterRouteShieldRearmTask?.cancel()
        commandCenterRouteShieldRearmTask = nil
        mediaTransportActions.resetMediaKeyState()
        stopCommandCenterRoute(reason: "runtime_stopped")
        eventTap.stop()
        carbonRegistrar.stop()
        lastCarbonAction = nil
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

        if eventTap.isRunning {
            stopPermissionRetry()
            guard ensureCommandCenterRoute(reason: "event_tap_running_route_shield") else {
                failCommandCenterRoute()
                return false
            }
            logger.info("SonosHandoffHotkeys mediaFallback=enabled state=already_running")
            if commandCenterInterceptor.isReady {
                runtimeReporter.mediaFallbackAlreadyRunning(
                    fnHotkeysRegistered: false,
                    activeEventTap: eventTap.activeTapKind?.rawValue
                )
            } else {
                runtimeReporter.mediaFallbackWaitingForCommandCenter(
                    accessibilityGranted: accessibilityGranted,
                    listenEventGranted: listenEventGranted,
                    activeEventTap: eventTap.activeTapKind?.rawValue
                )
            }
            return commandCenterInterceptor.isReady
        }

        runtimeReporter.mediaFallbackStarting(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted
        )
        logger.info("SonosHandoffHotkeys mediaFallback=starting accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public)")
        guard eventTap.start() else {
            stopCommandCenterRoute(reason: "event_tap_create_failed")
            logger.error("SonosHandoffHotkeys mediaFallback=disabled fnCarbon=disabled reason=event_tap_create_failed accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public) appPath=\(Bundle.main.bundlePath, privacy: .public)")
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
            return false
        }

        stopPermissionRetry()
        guard ensureCommandCenterRoute(reason: "event_tap_enabled_route_shield") else {
            failCommandCenterRoute()
            return false
        }
        logger.info("SonosHandoffHotkeys mediaFallback=starting tap=\(self.activeTapName, privacy: .public) events=systemDefined fnCarbon=skipped accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public)")
        runtimeReporter.mediaFallbackWaitingForCommandCenter(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            activeEventTap: eventTap.activeTapKind?.rawValue
        )
        return commandCenterInterceptor.isReady
    }

    private func ensureCommandCenterRoute(reason: String) -> Bool {
        if commandCenterInterceptor.running {
            guard commandCenterInterceptor.armRouteShield(reason: reason) else {
                commandCenterInterceptor.stop()
                return false
            }
            logger.info("SonosHandoffHotkeys commandCenterRoute=already_enabled reason=\(reason, privacy: .public)")
            return true
        }
        let starting = commandCenterInterceptor.start()
        if starting {
            logger.info("SonosHandoffHotkeys commandCenterRoute=enabled reason=\(reason, privacy: .public)")
        } else {
            logger.error("SonosHandoffHotkeys commandCenterRoute=failed reason=\(reason, privacy: .public)")
        }
        return starting
    }

    private func stopCommandCenterRoute(reason: String) {
        commandCenterRouteShieldRearmTask?.cancel()
        commandCenterRouteShieldRearmTask = nil
        guard commandCenterInterceptor.running else {
            logger.info("SonosHandoffHotkeys commandCenterRoute=already_disabled reason=\(reason, privacy: .public)")
            runtimeReporter.commandCenterRouteRunning(false)
            return
        }
        isStoppingCommandCenterRoute = true
        commandCenterInterceptor.stop()
        isStoppingCommandCenterRoute = false
        runtimeReporter.commandCenterRouteRunning(false)
        logger.info("SonosHandoffHotkeys commandCenterRoute=disabled reason=\(reason, privacy: .public)")
    }

    private func commandCenterReadinessChanged(_ ready: Bool) {
        guard !isStoppingCommandCenterRoute else {
            runtimeReporter.commandCenterRouteRunning(false)
            return
        }
        guard ready else {
            failCommandCenterRoute()
            return
        }
        guard eventTap.isRunning else {
            stopCommandCenterRoute(reason: "event_tap_not_running")
            return
        }

        stopPermissionRetry()
        runtimeReporter.mediaFallbackEnabled(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess(),
            fnHotkeysRegistered: false,
            activeEventTap: eventTap.activeTapKind?.rawValue
        )
    }

    private func failCommandCenterRoute() {
        if eventTap.isRunning {
            eventTap.stop()
        }
        stopCommandCenterRoute(reason: "route_unavailable")
        runtimeReporter.commandCenterRouteFailed(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess()
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
            guard let self, !self.eventTap.isRunning else {
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
            guard acceptTransportInput(command: command, source: source, metadata: metadata, phase: "down") else {
                return nil
            }
            if let reason = mediaTransportActions.ignoreReasonForMediaKeyDown(
                command: command,
                metadata: metadata
            ) {
                logger.info("SonosHandoffHotkeys \(reason.rawValue, privacy: .public) phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public) eventTimestamp=\(metadata.eventTimestamp, privacy: .public)")
                traceTransportKey(reason.rawValue, command: command, source: source, metadata: metadata)
                return nil
            }
            guard ensureCommandCenterRoute(reason: "media_key_down_route_shield") else {
                mediaTransportActions.resetMediaKeyState()
                failCommandCenterRoute()
                return nil
            }
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            traceTransportKey("transport_key_down", command: command, source: source, metadata: metadata)
            let mediaTransportActions = mediaTransportActions
            Task { @MainActor in
                mediaTransportActions.routeFromMediaKey(command: command, metadata: metadata)
            }
            return nil
        case .transportKeyUp(let command, let source, let metadata):
            guard acceptTransportInput(command: command, source: source, metadata: metadata, phase: "up") else {
                return nil
            }
            logger.info("SonosHandoffHotkeys decision=swallow phase=up action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            traceTransportKey("transport_key_up", command: command, source: source, metadata: metadata)
            mediaTransportActions.noteMediaKeyUp(command: command)
            return nil
        case .volumeHoldStart(let direction, let source):
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)_hold_start tap=\(self.activeTapName, privacy: .public)")
            startVolumeRepeat(direction: direction, source: source)
            return nil
        case .volumeHoldStop(let source):
            logger.info("SonosHandoffHotkeys decision=swallow phase=up action=volume_hold_stop source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            stopVolumeRepeat()
            return nil
        case .muteToggle(let source):
            logger.info("SonosHandoffHotkeys decision=swallow phase=down action=mute_toggle source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            toggleMute()
            return nil
        }
    }

    func suspendCommandCenterRouteShield(reason: String) {
        stopCommandCenterRoute(reason: reason)
        commandCenterRouteShieldRearmTask = Task { @MainActor [weak self] in
            try await Task.sleep(nanoseconds: Self.commandCenterRouteShieldRearmDelayNanoseconds)
            try Task.checkCancellation()
            guard let self else {
                return
            }
            self.commandCenterRouteShieldRearmTask = nil
            guard self.eventTap.isRunning else {
                return
            }
            guard self.ensureCommandCenterRoute(reason: "route_shield_rearmed") else {
                self.failCommandCenterRoute()
                return
            }
            self.runtimeReporter.mediaFallbackWaitingForCommandCenter(
                accessibilityGranted: AXIsProcessTrusted(),
                listenEventGranted: CGPreflightListenEventAccess(),
                activeEventTap: self.eventTap.activeTapKind?.rawValue
            )
        }
    }

    private func acceptTransportInput(
        command: MediaRemoteTransportCommand,
        source: String,
        metadata: MediaTransportInputMetadata,
        phase: String
    ) -> Bool {
        guard metadata.isPhysicalHIDSystemSource || source == "function_key" else {
            if phase == "down" {
                mediaTransportActions.noteGeneratedMediaKeyIgnored(command: command, metadata: metadata)
            }
            logger.info("SonosHandoffHotkeys transport_generated_input_ignored phase=\(phase, privacy: .public) action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
            traceTransportKey("transport_generated_input_ignored", command: command, source: source, metadata: metadata)
            return false
        }

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

    private func startVolumeRepeat(direction: VolumeDirection, source: String) {
        if repeatingDirection == direction {
            return
        }

        stopVolumeRepeat()
        repeatingDirection = direction
        volumeActions.adjustVolume(direction: direction)

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
            logger.info("SonosHandoffHotkeys action=mute_toggle source=carbon_shift_f10")
            toggleMute()
            return
        default:
            logger.info("SonosHandoffHotkeys carbon=ignored id=\(id, privacy: .public)")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if let lastCarbonAction,
           lastCarbonAction.direction == direction,
           now - lastCarbonAction.timestamp < 0.15 {
            logger.info("SonosHandoffHotkeys duplicate=ignored action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)")
            return
        }

        lastCarbonAction = (direction, now)
        logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)")
        volumeActions.adjustVolume(direction: direction)
    }
}
