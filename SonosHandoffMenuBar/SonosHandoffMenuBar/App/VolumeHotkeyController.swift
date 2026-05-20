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
    private var lastCarbonAction: (direction: VolumeDirection, timestamp: CFAbsoluteTime)?
    private var repeatTimer: DispatchSourceTimer?
    private var repeatingDirection: VolumeDirection?
    private let eventParser = ShortcutEventParser()

    private let step = SpeakerVolumeControlDefaults.step
    private lazy var carbonRegistrar = ShortcutCarbonHotKeyRegistrar { [weak self] id in
        self?.handleCarbonHotKey(id: id)
    }
    private lazy var eventTap = ShortcutEventTap { [weak self] type, event in
        self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
    }

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        mediaTransportActions: MediaTransportActionController,
        volumeCommands: SpeakerVolumeCommandQueue = .shared,
        runtimeReporter: ShortcutRuntimeReporter = ShortcutRuntimeReporter()
    ) {
        self.volumeActions = ShortcutVolumeActionController(
            volumeService: volumeService,
            outputSelection: outputSelection,
            volumeCommands: volumeCommands
        )
        self.mediaTransportActions = mediaTransportActions
        self.runtimeReporter = runtimeReporter
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
        if eventTap.isRunning {
            logger.info("SonosHandoffHotkeys mediaFallback=enabled state=already_running")
            runtimeReporter.mediaFallbackAlreadyRunning(fnHotkeysRegistered: false)
            return true
        }

        let accessibilityGranted = AXIsProcessTrusted()
        runtimeReporter.mediaFallbackStarting(accessibilityGranted: accessibilityGranted)
        logger.info("SonosHandoffHotkeys mediaFallback=starting accessibility=\(accessibilityGranted, privacy: .public)")
        guard eventTap.start() else {
            if !accessibilityGranted, promptIfMissing {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            logger.error("SonosHandoffHotkeys mediaFallback=disabled fnCarbon=disabled reason=event_tap_create_failed accessibility=\(accessibilityGranted, privacy: .public) appPath=\(Bundle.main.bundlePath, privacy: .public)")
            runtimeReporter.eventTapCreateFailed(accessibilityGranted: accessibilityGranted)
            return false
        }

        logger.info("SonosHandoffHotkeys mediaFallback=enabled events=systemDefined fnCarbon=skipped accessibility=\(accessibilityGranted, privacy: .public)")
        runtimeReporter.mediaFallbackEnabled(accessibilityGranted: accessibilityGranted, fnHotkeysRegistered: false)
        return true
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch eventParser.outcome(type: type, event: event, isRepeating: repeatingDirection != nil) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .transportKeyDown(let command, let source):
            logger.info("SonosHandoffHotkeys action=transport_\(command.rawValue, privacy: .public) source=\(source, privacy: .public)")
            mediaTransportActions.route(command: command)
            return nil
        case .transportKeyUp(let command, let source):
            logger.info("SonosHandoffHotkeys action=transport_\(command.rawValue, privacy: .public)_up source=\(source, privacy: .public)")
            return nil
        case .volumeHoldStart(let direction, let source):
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)_hold_start")
            startVolumeRepeat(direction: direction, source: source)
            return nil
        case .volumeHoldStop(let source):
            logger.info("SonosHandoffHotkeys action=volume_hold_stop source=\(source, privacy: .public)")
            stopVolumeRepeat()
            return nil
        case .muteToggle(let source):
            logger.info("SonosHandoffHotkeys action=mute_toggle source=\(source, privacy: .public)")
            toggleMute()
            return nil
        }
    }

    private func startVolumeRepeat(direction: VolumeDirection, source: String) {
        if repeatingDirection == direction {
            return
        }

        stopVolumeRepeat()
        repeatingDirection = direction
        volumeActions.adjustVolume(direction: direction)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.28)
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
