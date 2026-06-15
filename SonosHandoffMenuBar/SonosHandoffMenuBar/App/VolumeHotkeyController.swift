@preconcurrency import AppKit
import ApplicationServices
import os
import SonosHandoffCore

@MainActor
final class VolumeHotkeyController {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let volumeActions: ShortcutVolumeActionController
    private let mediaTransportActions: MediaTransportActionController
    private let runtimeReporter: ShortcutRuntimeReporter
    private let runtimeStatus = ShortcutRuntimeStatus.shared
    private var lastCarbonAction: (direction: VolumeDirection, timestamp: CFAbsoluteTime)?
    private var lastTransportKeyDown: (command: MediaRemoteTransportCommand, metadata: MediaTransportInputMetadata)?
    private var activeTransportKeyDown: MediaRemoteTransportCommand?
    private var activeTransportKeyDownResetTimer: DispatchSourceTimer?
    private var repeatTimer: DispatchSourceTimer?
    private var permissionRetryTimer: DispatchSourceTimer?
    private var repeatingDirection: VolumeDirection?
    private let transportKeyDownResetInterval: TimeInterval = 0.45
    private let eventParser = ShortcutEventParser()
    private lazy var commandCenterInterceptor = MediaCommandCenterInterceptor { [weak self] command, metadata in
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
        self.mediaTransportActions = mediaTransportActions
        self.runtimeReporter = runtimeReporter
    }

    deinit {
        MainActor.assumeIsolated {
            activeTransportKeyDownResetTimer?.cancel()
            repeatTimer?.cancel()
            permissionRetryTimer?.cancel()
            commandCenterInterceptor.stop()
            eventTap.stop()
        }
    }

    func start() {
        if carbonRegistrar.installHandlerIfNeeded() {
            let registered = carbonRegistrar.registerPlainFunctionHotKeys(step: step)
            runtimeReporter.plainHotkeysRegistered(registered)
        }
        refreshMediaFallback(promptIfMissing: true)
    }

    @discardableResult
    func refreshMediaFallback(promptIfMissing: Bool) -> Bool {
        let initialAccessibilityGranted = AXIsProcessTrusted()
        let initialListenEventGranted = CGPreflightListenEventAccess()
        if promptIfMissing {
            if !initialAccessibilityGranted {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            if !initialListenEventGranted {
                _ = CGRequestListenEventAccess()
            }
        }

        let accessibilityGranted = AXIsProcessTrusted()
        let listenEventGranted = CGPreflightListenEventAccess()
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
            ensureCommandCenterRoute(reason: "event_tap_running_route_shield")
            logger.info("SonosHandoffHotkeys mediaFallback=enabled state=already_running")
            runtimeReporter.mediaFallbackAlreadyRunning(
                fnHotkeysRegistered: false,
                activeEventTap: eventTap.activeTapKind?.rawValue
            )
            return true
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
        ensureCommandCenterRoute(reason: "event_tap_enabled_route_shield")
        logger.info("SonosHandoffHotkeys mediaFallback=enabled tap=\(self.activeTapName, privacy: .public) events=systemDefined fnCarbon=skipped accessibility=\(accessibilityGranted, privacy: .public) listenEvent=\(listenEventGranted, privacy: .public)")
        runtimeReporter.mediaFallbackEnabled(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            fnHotkeysRegistered: false,
            activeEventTap: eventTap.activeTapKind?.rawValue
        )
        return true
    }

    private func ensureCommandCenterRoute(reason: String) {
        if commandCenterInterceptor.running {
            commandCenterInterceptor.armRouteShield(reason: reason)
            logger.info("SonosHandoffHotkeys commandCenterRoute=already_enabled reason=\(reason, privacy: .public)")
            runtimeReporter.commandCenterRouteRunning(true)
            return
        }
        let running = commandCenterInterceptor.start()
        runtimeReporter.commandCenterRouteRunning(running)
        if running {
            logger.info("SonosHandoffHotkeys commandCenterRoute=enabled reason=\(reason, privacy: .public)")
        } else {
            logger.error("SonosHandoffHotkeys commandCenterRoute=failed reason=\(reason, privacy: .public)")
        }
    }

    private func stopCommandCenterRoute(reason: String) {
        guard commandCenterInterceptor.running else {
            logger.info("SonosHandoffHotkeys commandCenterRoute=already_disabled reason=\(reason, privacy: .public)")
            runtimeReporter.commandCenterRouteRunning(false)
            return
        }
        commandCenterInterceptor.stop()
        runtimeReporter.commandCenterRouteRunning(false)
        logger.info("SonosHandoffHotkeys commandCenterRoute=disabled reason=\(reason, privacy: .public)")
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

            guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
                return
            }

            _ = self.refreshMediaFallback(promptIfMissing: false)
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
            ensureCommandCenterRoute(reason: "media_key_down_route_shield")
            guard acceptTransportKeyDown(command: command, metadata: metadata) else {
                logger.info("SonosHandoffHotkeys transport_duplicate_ignored phase=down action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public) tap=\(self.activeTapName, privacy: .public) eventTimestamp=\(metadata.eventTimestamp, privacy: .public)")
                traceTransportKey("transport_duplicate_ignored", command: command, source: source, metadata: metadata)
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
            finishTransportKeyDown(command: command)
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

    func suspendCommandCenterRouteShieldForSelectedDispatch(reason: String) {
        stopCommandCenterRoute(reason: reason)
        Task { @MainActor [weak self] in
            try! await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.eventTap.isRunning else {
                return
            }
            self.ensureCommandCenterRoute(reason: "selected_row_dispatch_rearmed")
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

    private func acceptTransportKeyDown(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata
    ) -> Bool {
        if let lastTransportKeyDown,
           lastTransportKeyDown.metadata.matchesSameGeneratedMediaKey(as: metadata),
           commandsMatch(lastTransportKeyDown.command, command) {
            return false
        }

        if let activeTransportKeyDown,
           commandsMatch(activeTransportKeyDown, command) {
            return false
        }

        activeTransportKeyDown = command
        armTransportKeyDownReset(command: command)
        lastTransportKeyDown = (command, metadata)
        return true
    }

    private func finishTransportKeyDown(command: MediaRemoteTransportCommand) {
        guard let activeTransportKeyDown,
              commandsMatch(activeTransportKeyDown, command)
        else {
            return
        }

        self.activeTransportKeyDown = nil
        activeTransportKeyDownResetTimer?.cancel()
        activeTransportKeyDownResetTimer = nil
    }

    private func armTransportKeyDownReset(command: MediaRemoteTransportCommand) {
        activeTransportKeyDownResetTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + transportKeyDownResetInterval)
        timer.setEventHandler { [weak self] in
            guard let self,
                  let activeTransportKeyDown = self.activeTransportKeyDown,
                  self.commandsMatch(activeTransportKeyDown, command)
            else {
                return
            }

            self.activeTransportKeyDown = nil
            self.activeTransportKeyDownResetTimer = nil
            self.logger.error("SonosHandoffHotkeys transport_key_down_reset reason=missing_key_up action=transport_\(command.rawValue, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
        }
        activeTransportKeyDownResetTimer = timer
        timer.resume()
    }

    private func resetInputStateAfterTapInterruption(type: CGEventType) {
        activeTransportKeyDown = nil
        activeTransportKeyDownResetTimer?.cancel()
        activeTransportKeyDownResetTimer = nil
        stopVolumeRepeat()
        logger.error("SonosHandoffHotkeys input_state_reset reason=event_tap_interrupted eventType=\(type.rawValue, privacy: .public) tap=\(self.activeTapName, privacy: .public)")
    }

    private func commandsMatch(
        _ expected: MediaRemoteTransportCommand,
        _ actual: MediaRemoteTransportCommand
    ) -> Bool {
        if expected == actual {
            return true
        }

        return isPlayPauseFamily(expected) && isPlayPauseFamily(actual)
    }

    private func isPlayPauseFamily(_ command: MediaRemoteTransportCommand) -> Bool {
        command == .playPause || command == .pause || command == .play
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
