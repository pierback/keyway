@preconcurrency import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import os
import SonosHandoffCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let volumeHotkeys = VolumeHotkeyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: .sonosHandoffRefreshHotkeys,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.volumeHotkeys.refreshMediaFallback(promptIfMissing: false)
            }
        }
        volumeHotkeys.start()
    }
}

@MainActor
private final class VolumeHotkeyController {
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Hotkeys")
    private let configStore: ConfigStoring
    private let handoffService: SpotifyConnectHandoffService
    private var carbonEventHandler: EventHandlerRef?
    private var volumeDownHotKey: EventHotKeyRef?
    private var volumeUpHotKey: EventHotKeyRef?
    private var muteHotKey: EventHotKeyRef?
    private var volumeDownFnHotKey: EventHotKeyRef?
    private var volumeUpFnHotKey: EventHotKeyRef?
    private var muteFnHotKey: EventHotKeyRef?
    private var lastCarbonAction: (direction: VolumeDirection, timestamp: CFAbsoluteTime)?
    private var repeatTimer: DispatchSourceTimer?
    private var repeatingDirection: VolumeDirection?
    private var volumeAdjustmentInFlight = false
    private var queuedVolumeDirection: VolumeDirection?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didInstallCarbonHandler = false
    private var didRegisterPlainHotKeys = false
    private var didRegisterFnHotKeys = false

    private let mediaKeySubtype = 8
    private let systemDefinedEventType = CGEventType(rawValue: 14)!
    private let keyDownEventType = CGEventType.keyDown
    private let keyUpEventType = CGEventType.keyUp
    private let keyDownState = 0x0A
    private let keyUpState = 0x0B
    private let soundMuteKeyCode = 7
    private let soundUpKeyCode = 0
    private let soundDownKeyCode = 1
    private let f10KeyCode: Int64 = 109
    private let f11KeyCode: Int64 = 103
    private let f12KeyCode: Int64 = 111
    private let step = VolumeControlDefaults.step

    init(configStore: ConfigStoring = ConfigStore()) {
        self.configStore = configStore
        self.handoffService = SpotifyConnectHandoffService(configStore: configStore)
    }

    func start() {
        installCarbonHandlerIfNeeded()
        registerPlainFunctionHotKeys()
        refreshMediaFallback(promptIfMissing: false)
    }

    @discardableResult
    func refreshMediaFallback(promptIfMissing: Bool) -> Bool {
        if eventTap != nil {
            logger.info("SonosHandoffHotkeys mediaFallback=enabled state=already_running")
            let fnHotkeysRegistered = didRegisterFnHotKeys
            Task { @MainActor in
                ShortcutRuntimeStatus.shared.update(
                    accessibilityGranted: AXIsProcessTrusted(),
                    mediaFallback: .enabled,
                    fnHotkeysRegistered: fnHotkeysRegistered,
                    clearFailureReason: true
                )
            }
            return true
        }

        let accessibilityGranted = AXIsProcessTrusted()
        Task { @MainActor in
            ShortcutRuntimeStatus.shared.update(
                accessibilityGranted: accessibilityGranted,
                mediaFallback: .starting,
                clearFailureReason: true
            )
        }
        logger.info("SonosHandoffHotkeys mediaFallback=starting accessibility=\(accessibilityGranted, privacy: .public)")
        let eventMask = CGEventMask(1 << systemDefinedEventType.rawValue)
            | CGEventMask(1 << keyDownEventType.rawValue)
            | CGEventMask(1 << keyUpEventType.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: volumeHotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !accessibilityGranted, promptIfMissing {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            logger.error("SonosHandoffHotkeys mediaFallback=disabled fnCarbon=disabled reason=event_tap_create_failed accessibility=\(accessibilityGranted, privacy: .public) appPath=\(Bundle.main.bundlePath, privacy: .public)")
            Task { @MainActor in
                ShortcutRuntimeStatus.shared.update(
                    accessibilityGranted: accessibilityGranted,
                    mediaFallback: .eventTapCreateFailed,
                    fnHotkeysRegistered: false,
                    lastFailureReason: "event_tap_create_failed"
                )
            }
            if !accessibilityGranted {
                Task { @MainActor in
                    StatusHUD.shared.finish(
                        title: "Shortcut Permission Needed",
                        message: "Grant Accessibility to Sonos Handoff for fn+F10/F11/F12",
                        dismissAfter: 7.0
                    )
                }
            }
            return false
        }

        self.eventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        registerFnFunctionHotKeys()
        logger.info("SonosHandoffHotkeys mediaFallback=enabled events=systemDefined accessibility=\(accessibilityGranted, privacy: .public)")
        let fnHotkeysRegistered = didRegisterFnHotKeys
        Task { @MainActor in
            ShortcutRuntimeStatus.shared.update(
                accessibilityGranted: accessibilityGranted,
                mediaFallback: .enabled,
                fnHotkeysRegistered: fnHotkeysRegistered,
                clearFailureReason: true
            )
        }
        return true
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == keyDownEventType || type == keyUpEventType {
            return handleFunctionKey(type: type, event: event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        guard type == systemDefinedEventType, nsEvent.subtype.rawValue == mediaKeySubtype else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
        let modifiers = nsEvent.modifierFlags
        guard modifiers.contains(.shift) else {
            return Unmanaged.passUnretained(event)
        }

        logger.info("SonosHandoffHotkeys mediaKey keyCode=\(keyCode, privacy: .public) keyState=\(keyState, privacy: .public) shift=true")
        if keyState == keyDownState {
            if keyCode == soundDownKeyCode {
                logger.info("SonosHandoffHotkeys action=volume_down source=media_key_hold_start")
                startVolumeRepeat(direction: .down, source: "media_key")
                return nil
            }

            if keyCode == soundUpKeyCode {
                logger.info("SonosHandoffHotkeys action=volume_up source=media_key_hold_start")
                startVolumeRepeat(direction: .up, source: "media_key")
                return nil
            }

            if keyCode == soundMuteKeyCode {
                logger.info("SonosHandoffHotkeys action=mute_toggle source=media_key")
                toggleMute()
                return nil
            }
        }

        if keyState == keyUpState,
           keyCode == soundDownKeyCode || keyCode == soundUpKeyCode {
            logger.info("SonosHandoffHotkeys action=volume_hold_stop source=media_key")
            stopVolumeRepeat()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleFunctionKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if type == keyUpEventType,
           (keyCode == f11KeyCode || keyCode == f12KeyCode) {
            guard repeatingDirection != nil || (flags.contains(.maskSecondaryFn) && flags.contains(.maskShift)) else {
                return Unmanaged.passUnretained(event)
            }

            logger.info("SonosHandoffHotkeys action=volume_hold_stop source=function_key")
            stopVolumeRepeat()
            return nil
        }

        guard flags.contains(.maskSecondaryFn), flags.contains(.maskShift) else {
            return Unmanaged.passUnretained(event)
        }

        if type == keyDownEventType {
            if keyCode == f11KeyCode {
                logger.info("SonosHandoffHotkeys action=volume_down source=shift_fn_f11_hold_start")
                startVolumeRepeat(direction: .down, source: "shift_fn_f11")
                return nil
            }

            if keyCode == f12KeyCode {
                logger.info("SonosHandoffHotkeys action=volume_up source=shift_fn_f12_hold_start")
                startVolumeRepeat(direction: .up, source: "shift_fn_f12")
                return nil
            }

            if keyCode == f10KeyCode {
                logger.info("SonosHandoffHotkeys action=mute_toggle source=shift_fn_f10")
                toggleMute()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func startVolumeRepeat(direction: VolumeDirection, source: String) {
        if repeatingDirection == direction {
            return
        }

        stopVolumeRepeat()
        repeatingDirection = direction
        adjustVolume(direction: direction)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.28)
        timer.setEventHandler { [weak self] in
            guard let self, self.repeatingDirection == direction else {
                return
            }
            self.logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) source=\(source, privacy: .public)_hold_repeat")
            self.adjustVolume(direction: direction)
        }
        repeatTimer = timer
        timer.resume()
    }

    private func stopVolumeRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
        repeatingDirection = nil
        queuedVolumeDirection = nil
    }

    private func adjustVolume(direction: VolumeDirection) {
        let roomName = preferredRoomName()
        if volumeAdjustmentInFlight {
            queuedVolumeDirection = direction
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=queued room=\(roomName, privacy: .public)")
            return
        }

        volumeAdjustmentInFlight = true
        StatusHUD.shared.showVolumePending(roomName: roomName, direction: direction)
        let logger = logger
        Task.detached(priority: .userInitiated) { [handoffService, step, logger] in
            do {
                let volume: Int
                switch direction {
                case .down:
                    volume = try await handoffService.volumeDown(roomName: roomName, step: step)
                case .up:
                    volume = try await handoffService.volumeUp(roomName: roomName, step: step)
                }
                logger.info("SonosHandoffHotkeys result=success action=volume_\(direction.logName, privacy: .public) room=\(roomName, privacy: .public) step=\(step, privacy: .public) volume=\(volume, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                    StatusHUD.shared.showVolume(roomName: roomName, volume: volume, direction: direction)
                    self.finishVolumeAdjustment(shouldRunQueued: true)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=volume_\(direction.logName, privacy: .public) room=\(roomName, privacy: .public) step=\(step, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(roomName) Volume Failed",
                        message: error.localizedDescription
                    )
                    self.finishVolumeAdjustment(shouldRunQueued: false)
                }
            }
        }
    }

    private func finishVolumeAdjustment(shouldRunQueued: Bool) {
        volumeAdjustmentInFlight = false
        guard shouldRunQueued, let direction = queuedVolumeDirection else {
            queuedVolumeDirection = nil
            return
        }

        queuedVolumeDirection = nil
        adjustVolume(direction: direction)
    }

    private func toggleMute() {
        stopVolumeRepeat()
        let roomName = preferredRoomName()
        Task { @MainActor in
            StatusHUD.shared.showMutePending(roomName: roomName)
        }
        let logger = logger
        Task.detached(priority: .userInitiated) { [handoffService, logger] in
            do {
                let muted = try await handoffService.toggleMute(roomName: roomName)
                logger.info("SonosHandoffHotkeys result=success action=mute_toggle room=\(roomName, privacy: .public) muted=\(muted, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: roomName, muted: muted)
                    StatusHUD.shared.showMute(roomName: roomName, muted: muted)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=mute_toggle room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(roomName) Mute Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }


    private func preferredRoomName() -> String {
        guard let config = try? configStore.load() else {
            return "Port"
        }

        if let port = config.targets.first(where: { $0.alias.caseInsensitiveCompare("port") == .orderedSame }) {
            return port.spotifyDeviceName
        }

        return config.targets.first?.spotifyDeviceName ?? "Port"
    }

    private func installCarbonHandlerIfNeeded() {
        guard !didInstallCarbonHandler else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonEventHandler
        )
        guard installStatus == noErr else {
            logger.error("SonosHandoffHotkeys carbon=disabled reason=install_handler_failed status=\(installStatus, privacy: .public)")
            return
        }

        didInstallCarbonHandler = true
    }

    private func registerPlainFunctionHotKeys() {
        guard didInstallCarbonHandler, !didRegisterPlainHotKeys else {
            return
        }

        registerCarbonHotKey(
            keyCode: UInt32(kVK_F10),
            id: 5,
            modifiers: UInt32(shiftKey),
            storage: &muteHotKey,
            name: "shift_f10_mute_toggle"
        )
        registerCarbonHotKey(
            keyCode: UInt32(kVK_F11),
            id: 1,
            modifiers: UInt32(shiftKey),
            storage: &volumeDownHotKey,
            name: "shift_f11_volume_down"
        )
        registerCarbonHotKey(
            keyCode: UInt32(kVK_F12),
            id: 2,
            modifiers: UInt32(shiftKey),
            storage: &volumeUpHotKey,
            name: "shift_f12_volume_up"
        )
        didRegisterPlainHotKeys = muteHotKey != nil && volumeDownHotKey != nil && volumeUpHotKey != nil
        let plainHotkeysRegistered = didRegisterPlainHotKeys
        Task { @MainActor in
            ShortcutRuntimeStatus.shared.update(plainHotkeysRegistered: plainHotkeysRegistered)
        }
    }

    private func registerFnFunctionHotKeys() {
        guard didInstallCarbonHandler, !didRegisterFnHotKeys else {
            return
        }

        registerCarbonHotKey(
            keyCode: UInt32(kVK_F10),
            id: 6,
            modifiers: UInt32(shiftKey | kEventKeyModifierFnMask),
            storage: &muteFnHotKey,
            name: "shift_fn_f10_mute_toggle"
        )
        registerCarbonHotKey(
            keyCode: UInt32(kVK_F11),
            id: 3,
            modifiers: UInt32(shiftKey | kEventKeyModifierFnMask),
            storage: &volumeDownFnHotKey,
            name: "shift_fn_f11_volume_down"
        )
        registerCarbonHotKey(
            keyCode: UInt32(kVK_F12),
            id: 4,
            modifiers: UInt32(shiftKey | kEventKeyModifierFnMask),
            storage: &volumeUpFnHotKey,
            name: "shift_fn_f12_volume_up"
        )
        didRegisterFnHotKeys = muteFnHotKey != nil && volumeDownFnHotKey != nil && volumeUpFnHotKey != nil
        let fnHotkeysRegistered = didRegisterFnHotKeys
        Task { @MainActor in
            ShortcutRuntimeStatus.shared.update(fnHotkeysRegistered: fnHotkeysRegistered)
        }
    }

    private func registerCarbonHotKey(
        keyCode: UInt32,
        id: UInt32,
        modifiers: UInt32,
        storage: inout EventHotKeyRef?,
        name: String
    ) {
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &storage
        )
        if status == noErr {
            logger.info("SonosHandoffHotkeys carbon=enabled hotkey=\(name, privacy: .public) step=\(self.step, privacy: .public)")
        } else {
            logger.error("SonosHandoffHotkeys carbon=disabled hotkey=\(name, privacy: .public) status=\(status, privacy: .public)")
        }
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
        case 3:
            direction = .down
            source = "carbon_shift_fn_f11"
        case 4:
            direction = .up
            source = "carbon_shift_fn_f12"
        case 6:
            logger.info("SonosHandoffHotkeys action=mute_toggle source=carbon_shift_fn_f10")
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
        adjustVolume(direction: direction)
    }

    private static let hotKeySignature = OSType(
        UInt32(Character("S").asciiValue!) << 24 |
            UInt32(Character("O").asciiValue!) << 16 |
            UInt32(Character("N").asciiValue!) << 8 |
            UInt32(Character("O").asciiValue!)
    )
}

private func carbonHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else {
        return status
    }

    let controller = Unmanaged<VolumeHotkeyController>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.handleCarbonHotKey(id: hotKeyID.id)
        return noErr
    }
}

enum VolumeControlDefaults {
    static let step = 5
}

enum ShortcutMediaFallbackState: String {
    case unknown
    case starting
    case enabled
    case eventTapCreateFailed = "event_tap_create_failed"
}

struct ShortcutRuntimeSnapshot {
    let accessibilityGranted: Bool
    let mediaFallback: ShortcutMediaFallbackState
    let plainHotkeysRegistered: Bool
    let fnHotkeysRegistered: Bool
    let lastFailureReason: String?
    let appPath: String
    let step: Int

    var title: String {
        if mediaFallback == .enabled {
            return "Shortcuts Ready"
        }

        if plainHotkeysRegistered {
            return "fn Shortcuts Blocked"
        }

        return "Shortcuts Need Attention"
    }

    var message: String {
        if mediaFallback == .enabled {
            return "Shift+fn+F10/F11/F12 enabled; step \(step)%"
        }

        if mediaFallback == .eventTapCreateFailed {
            return "Enable Accessibility for Shift+fn+F10/F11/F12; Shift+F10/F11/F12 works"
        }

        if plainHotkeysRegistered {
            return "Shift+F10/F11/F12 works; fn path not ready"
        }

        return "Shortcut registration has not completed"
    }
}

@MainActor
final class ShortcutRuntimeStatus {
    static let shared = ShortcutRuntimeStatus()

    private var accessibilityGranted = AXIsProcessTrusted()
    private var mediaFallback: ShortcutMediaFallbackState = .unknown
    private var plainHotkeysRegistered = false
    private var fnHotkeysRegistered = false
    private var lastFailureReason: String?

    private init() {}

    func update(
        accessibilityGranted: Bool? = nil,
        mediaFallback: ShortcutMediaFallbackState? = nil,
        plainHotkeysRegistered: Bool? = nil,
        fnHotkeysRegistered: Bool? = nil,
        lastFailureReason: String? = nil,
        clearFailureReason: Bool = false
    ) {
        if let accessibilityGranted {
            self.accessibilityGranted = accessibilityGranted
        }
        if let mediaFallback {
            self.mediaFallback = mediaFallback
        }
        if let plainHotkeysRegistered {
            self.plainHotkeysRegistered = plainHotkeysRegistered
        }
        if let fnHotkeysRegistered {
            self.fnHotkeysRegistered = fnHotkeysRegistered
        }
        if let lastFailureReason {
            self.lastFailureReason = lastFailureReason
        } else if clearFailureReason {
            self.lastFailureReason = nil
        }
    }

    func snapshot() -> ShortcutRuntimeSnapshot {
        ShortcutRuntimeSnapshot(
            accessibilityGranted: accessibilityGranted,
            mediaFallback: mediaFallback,
            plainHotkeysRegistered: plainHotkeysRegistered,
            fnHotkeysRegistered: fnHotkeysRegistered,
            lastFailureReason: lastFailureReason,
            appPath: Bundle.main.bundlePath,
            step: VolumeControlDefaults.step
        )
    }
}

struct VolumeMonitorSnapshot: Equatable {
    let roomName: String
    let host: String
    let volume: Int
    let outputFixed: Bool
    let muted: Bool

    init(status: SpeakerVolumeStatus) {
        self.roomName = status.roomName
        self.host = status.host
        self.volume = status.volume
        self.outputFixed = status.outputFixed
        self.muted = status.muted
    }

    init(roomName: String, host: String, volume: Int, outputFixed: Bool, muted: Bool) {
        self.roomName = roomName
        self.host = host
        self.volume = volume
        self.outputFixed = outputFixed
        self.muted = muted
    }
}

@MainActor
final class SonosVolumeMonitor: ObservableObject {
    static let shared = SonosVolumeMonitor()

    @Published private(set) var snapshot: VolumeMonitorSnapshot?

    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "VolumeMonitor")
    private var configStore: (any ConfigStoring)?
    private var volumeService: (any SpeakerVolumeAdjusting)?
    private var pollTask: Task<Void, Never>?
    private var selectedRoomName: String?
    private var pollInFlight = false
    private var suppressUntil = Date.distantPast
    private var suppressedRoomName: String?
    private static let pollIntervalNanoseconds: UInt64 = 450_000_000
    private static let localChangeSuppressionSeconds: TimeInterval = 1.25

    private init() {}

    func start(configStore: any ConfigStoring, volumeService: any SpeakerVolumeAdjusting) {
        self.configStore = configStore
        self.volumeService = volumeService

        guard pollTask == nil else {
            return
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func setRoomName(_ roomName: String?) {
        selectedRoomName = roomName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func noteLocalChange(roomName: String, volume: Int? = nil, muted: Bool? = nil) {
        suppressUntil = Date().addingTimeInterval(Self.localChangeSuppressionSeconds)
        suppressedRoomName = roomName

        guard let current = snapshot,
              current.roomName.caseInsensitiveCompare(roomName) == .orderedSame
        else {
            return
        }

        snapshot = VolumeMonitorSnapshot(
            roomName: current.roomName,
            host: current.host,
            volume: volume ?? current.volume,
            outputFixed: current.outputFixed,
            muted: muted ?? current.muted
        )
    }

    private func pollOnce() async {
        guard !pollInFlight,
              let volumeService,
              let roomName = activeRoomName()
        else {
            return
        }

        pollInFlight = true
        let result = await Task.detached(priority: .utility) { () -> Result<SpeakerVolumeStatus, Error> in
            do {
                return .success(try await volumeService.volumeStatus(roomName: roomName))
            } catch {
                return .failure(error)
            }
        }.value
        pollInFlight = false

        switch result {
        case .success(let status):
            apply(status: status)
        case .failure(let error):
            logger.error("SonosHandoffVolumeMonitor result=failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func activeRoomName() -> String? {
        if let selectedRoomName {
            return selectedRoomName
        }

        guard let configStore, let config = try? configStore.load() else {
            return "Port"
        }

        if let port = config.targets.first(where: { $0.alias.caseInsensitiveCompare("port") == .orderedSame }) {
            return port.spotifyDeviceName
        }

        return config.targets.first?.spotifyDeviceName ?? "Port"
    }

    private func apply(status: SpeakerVolumeStatus) {
        let nextSnapshot = VolumeMonitorSnapshot(status: status)
        let previousSnapshot = snapshot

        guard let previousSnapshot,
              previousSnapshot.roomName.caseInsensitiveCompare(status.roomName) == .orderedSame
        else {
            snapshot = nextSnapshot
            logger.info("SonosHandoffVolumeMonitor state=primed room=\(status.roomName, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public)")
            return
        }

        let volumeChanged = previousSnapshot.volume != status.volume
        let muteChanged = previousSnapshot.muted != status.muted
        guard volumeChanged || muteChanged else {
            snapshot = nextSnapshot
            return
        }

        logger.info("SonosHandoffVolumeMonitor state=changed room=\(status.roomName, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public)")
        guard !isSuppressed(status: status) else {
            return
        }

        snapshot = nextSnapshot
        if volumeChanged {
            let direction: VolumeDirection = status.volume < previousSnapshot.volume ? .down : .up
            StatusHUD.shared.showVolume(roomName: status.roomName, volume: status.volume, direction: direction, dismissAfter: 1.6)
        } else {
            StatusHUD.shared.showMute(roomName: status.roomName, muted: status.muted, dismissAfter: 1.6)
        }
    }

    private func isSuppressed(status: SpeakerVolumeStatus) -> Bool {
        guard Date() < suppressUntil,
              let suppressedRoomName,
              suppressedRoomName.caseInsensitiveCompare(status.roomName) == .orderedSame
        else {
            return false
        }

        return true
    }
}

enum VolumeDirection: Equatable {
    case down
    case up

    var logName: String {
        switch self {
        case .down:
            return "down"
        case .up:
            return "up"
        }
    }
}

private func volumeHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<VolumeHotkeyController>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.handle(type: type, event: event)
    }
}

extension Notification.Name {
    static let sonosHandoffRefreshHotkeys = Notification.Name("com.fpieringer.SonosHandoffMenuBar.refreshHotkeys")
}

@MainActor
final class StatusHUD {
    static let shared = StatusHUD()

    private var panel: NSPanel?
    private var containerView: HUDContainerView?
    private var backgroundView: HUDBackgroundView?
    private var spinner: NSProgressIndicator?
    private var titleField: NSTextField?
    private var messageField: NSTextField?
    private var statusDot: NSView?
    private var trackView: NSView?
    private var fillView: NSView?
    private var knobView: NSView?
    private var leftIconView: NSImageView?
    private var rightIconView: NSImageView?
    private var dividerView: NSView?
    private var outputLabelField: NSTextField?
    private var outputBadgeView: NSView?
    private var outputIconView: NSImageView?
    private var outputNameField: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    private let messagePanelSize = NSSize(width: 306, height: 176)
    private let volumePanelSize = NSSize(width: 296, height: 64)
    private let edgeInset: CGFloat = 18
    private let messageTrackFrame = NSRect(x: 56, y: 111, width: 198, height: 5)
    private let compactTrackFrame = NSRect(x: 28, y: 22, width: 233, height: 4)
    private var activeTrackFrame = NSRect(x: 56, y: 111, width: 198, height: 5)
    private let knobSize: CGFloat = 17

    private init() {}

    func show(title: String, message: String) {
        hideWorkItem?.cancel()
        ensurePanel()

        configureMessageLayout()
        spinner?.startAnimation(nil)
        spinner?.isHidden = false
        statusDot?.isHidden = true
        titleField?.stringValue = title
        messageField?.stringValue = message

        positionPanel()
        panel?.orderFrontRegardless()
    }

    func update(title: String? = nil, message: String) {
        if let title {
            titleField?.stringValue = title
        }
        messageField?.stringValue = message
        positionPanel()
    }

    func finish(title: String, message: String, dismissAfter seconds: TimeInterval = 3.5) {
        hideWorkItem?.cancel()
        ensurePanel()

        configureMessageLayout()
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        statusDot?.isHidden = false
        titleField?.stringValue = title
        messageField?.stringValue = message
        positionPanel()
        panel?.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    func showVolumePending(roomName: String, direction: VolumeDirection) {
        hideWorkItem?.cancel()
        ensurePanel()
        configureVolumeLayout()

        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        statusDot?.isHidden = true
        titleField?.stringValue = "Sound"
        messageField?.stringValue = ""
        messageField?.isHidden = true
        outputNameField?.stringValue = roomName
        leftIconView?.isHidden = false
        rightIconView?.isHidden = false
        setVolumeFill(0)

        positionPanel()
        panel?.orderFrontRegardless()
    }

    func showVolume(roomName: String, volume: Int, direction: VolumeDirection, dismissAfter seconds: TimeInterval = 3.0) {
        hideWorkItem?.cancel()
        ensurePanel()
        configureVolumeLayout()

        let clampedVolume = max(0, min(100, volume))
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        statusDot?.isHidden = true
        titleField?.stringValue = "Sound"
        messageField?.stringValue = direction == .down ? "Volume \(clampedVolume) - down" : "Volume \(clampedVolume) - up"
        messageField?.isHidden = true
        outputNameField?.stringValue = roomName
        setVolumeFill(clampedVolume)

        positionPanel()
        panel?.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    func showMutePending(roomName: String) {
        hideWorkItem?.cancel()
        ensurePanel()
        configureVolumeLayout()

        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        statusDot?.isHidden = true
        titleField?.stringValue = "Sound"
        messageField?.stringValue = ""
        messageField?.isHidden = true
        outputNameField?.stringValue = roomName
        leftIconView?.isHidden = false
        leftIconView?.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        rightIconView?.isHidden = false
        rightIconView?.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Mute")
        setVolumeFill(0)

        positionPanel()
        panel?.orderFrontRegardless()
    }

    func showMute(roomName: String, muted: Bool, dismissAfter seconds: TimeInterval = 3.0) {
        hideWorkItem?.cancel()
        ensurePanel()
        configureVolumeLayout()

        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        statusDot?.isHidden = true
        titleField?.stringValue = "Sound"
        messageField?.stringValue = ""
        messageField?.isHidden = true
        outputNameField?.stringValue = roomName
        leftIconView?.isHidden = false
        leftIconView?.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        rightIconView?.isHidden = false
        rightIconView?.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Volume")
        setVolumeFill(muted ? 0 : 100)

        positionPanel()
        panel?.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func ensurePanel() {
        guard panel == nil else {
            return
        }

        let size = messagePanelSize
        let bodyFrame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false

        let containerView = HUDContainerView(frame: NSRect(origin: .zero, size: size))
        containerView.onClick = { [weak self] in
            self?.hideWorkItem?.cancel()
            self?.panel?.orderOut(nil)
        }
        containerView.wantsLayer = true

        let backgroundView = HUDBackgroundView(frame: bodyFrame)
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 22
        backgroundView.layer?.masksToBounds = true

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 128, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        let statusDot = NSView(frame: NSRect(x: 23, y: 132, width: 10, height: 10))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.isHidden = true

        let titleField = NSTextField(labelWithString: "")
        titleField.frame = NSRect(x: edgeInset, y: 132, width: 270, height: 24)
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail

        let messageField = NSTextField(labelWithString: "")
        messageField.frame = NSRect(x: 46, y: 111, width: 240, height: 15)
        messageField.font = .systemFont(ofSize: 11, weight: .medium)
        messageField.textColor = NSColor.white.withAlphaComponent(0.78)
        messageField.lineBreakMode = .byTruncatingTail

        let leftIconView = NSImageView(frame: NSRect(x: 21, y: 101, width: 23, height: 23))
        leftIconView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        leftIconView.imageScaling = .scaleProportionallyDown
        leftIconView.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        leftIconView.isHidden = true

        let rightIconView = NSImageView(frame: NSRect(x: 267, y: 98, width: 25, height: 25))
        rightIconView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        rightIconView.imageScaling = .scaleProportionallyDown
        rightIconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        rightIconView.isHidden = true

        let trackView = NSView(frame: messageTrackFrame)
        trackView.wantsLayer = true
        trackView.layer?.cornerRadius = messageTrackFrame.height / 2
        trackView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        trackView.isHidden = true

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: messageTrackFrame.height))
        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = messageTrackFrame.height / 2
        fillView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        trackView.addSubview(fillView)

        let knobView = NSView(frame: NSRect(x: messageTrackFrame.minX - knobSize / 2, y: messageTrackFrame.midY - knobSize / 2, width: knobSize, height: knobSize))
        knobView.wantsLayer = true
        knobView.layer?.cornerRadius = knobSize / 2
        knobView.layer?.backgroundColor = NSColor.white.cgColor
        knobView.layer?.shadowColor = NSColor.black.cgColor
        knobView.layer?.shadowOpacity = 0.22
        knobView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        knobView.layer?.shadowRadius = 2
        knobView.isHidden = true

        let dividerView = NSView(frame: NSRect(x: edgeInset, y: 84, width: messagePanelSize.width - (edgeInset * 2), height: 1))
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        dividerView.isHidden = true

        let outputLabelField = NSTextField(labelWithString: "Output")
        outputLabelField.frame = NSRect(x: edgeInset, y: 58, width: 120, height: 20)
        outputLabelField.font = .systemFont(ofSize: 14, weight: .semibold)
        outputLabelField.textColor = NSColor.white.withAlphaComponent(0.58)
        outputLabelField.lineBreakMode = .byTruncatingTail
        outputLabelField.isHidden = true

        let outputBadgeView = NSView(frame: NSRect(x: edgeInset, y: 20, width: 34, height: 34))
        outputBadgeView.wantsLayer = true
        outputBadgeView.layer?.cornerRadius = 17
        outputBadgeView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        outputBadgeView.isHidden = true

        let outputIconView = NSImageView(frame: NSRect(x: 7, y: 7, width: 20, height: 20))
        outputIconView.contentTintColor = .white
        outputIconView.imageScaling = .scaleProportionallyDown
        outputIconView.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Sonos")
        outputBadgeView.addSubview(outputIconView)

        let outputNameField = NSTextField(labelWithString: "Port")
        outputNameField.frame = NSRect(x: 64, y: 26, width: 210, height: 23)
        outputNameField.font = .systemFont(ofSize: 16, weight: .semibold)
        outputNameField.textColor = .white
        outputNameField.lineBreakMode = .byTruncatingTail
        outputNameField.isHidden = true

        containerView.addSubview(backgroundView)
        backgroundView.addSubview(spinner)
        backgroundView.addSubview(statusDot)
        backgroundView.addSubview(titleField)
        backgroundView.addSubview(messageField)
        backgroundView.addSubview(leftIconView)
        backgroundView.addSubview(trackView)
        backgroundView.addSubview(knobView)
        backgroundView.addSubview(rightIconView)
        backgroundView.addSubview(dividerView)
        backgroundView.addSubview(outputLabelField)
        backgroundView.addSubview(outputBadgeView)
        backgroundView.addSubview(outputNameField)
        panel.contentView = containerView

        self.panel = panel
        self.containerView = containerView
        self.backgroundView = backgroundView
        self.spinner = spinner
        self.titleField = titleField
        self.messageField = messageField
        self.statusDot = statusDot
        self.trackView = trackView
        self.fillView = fillView
        self.knobView = knobView
        self.leftIconView = leftIconView
        self.rightIconView = rightIconView
        self.dividerView = dividerView
        self.outputLabelField = outputLabelField
        self.outputBadgeView = outputBadgeView
        self.outputIconView = outputIconView
        self.outputNameField = outputNameField
    }

    private func configureMessageLayout() {
        resizePanel(to: messagePanelSize)
        activeTrackFrame = messageTrackFrame
        backgroundView?.layer?.cornerRadius = 22
        titleField?.alignment = .left
        titleField?.frame = NSRect(x: 46, y: 132, width: 240, height: 22)
        titleField?.font = .systemFont(ofSize: 17, weight: .semibold)
        messageField?.frame = NSRect(x: 46, y: 111, width: 240, height: 15)
        messageField?.isHidden = false
        leftIconView?.isHidden = true
        rightIconView?.isHidden = true
        trackView?.isHidden = true
        knobView?.isHidden = true
        dividerView?.isHidden = true
        outputLabelField?.isHidden = true
        outputBadgeView?.isHidden = true
        outputNameField?.isHidden = true
    }

    private func configureVolumeLayout() {
        resizePanel(to: volumePanelSize)
        activeTrackFrame = compactTrackFrame
        backgroundView?.layer?.cornerRadius = 18
        titleField?.alignment = .left
        titleField?.frame = NSRect(x: 9, y: 41, width: volumePanelSize.width - 18, height: 16)
        titleField?.font = .systemFont(ofSize: 13, weight: .semibold)
        messageField?.frame = NSRect(x: 28, y: 8, width: 233, height: 14)
        messageField?.isHidden = true
        leftIconView?.isHidden = false
        leftIconView?.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        leftIconView?.frame = NSRect(x: 9, y: 15, width: 14, height: 18)
        rightIconView?.isHidden = false
        rightIconView?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        rightIconView?.frame = NSRect(x: 266, y: 15, width: 21, height: 18)
        trackView?.isHidden = false
        trackView?.frame = compactTrackFrame
        trackView?.layer?.cornerRadius = compactTrackFrame.height / 2
        fillView?.layer?.cornerRadius = compactTrackFrame.height / 2
        fillView?.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        knobView?.isHidden = false
        dividerView?.isHidden = true
        outputLabelField?.isHidden = true
        outputBadgeView?.isHidden = true
        outputNameField?.isHidden = true
    }

    private func setVolumeFill(_ volume: Int) {
        let percent = CGFloat(volume) / 100
        let fillWidth = max(0, min(activeTrackFrame.width, activeTrackFrame.width * percent))
        fillView?.frame = NSRect(x: 0, y: 0, width: fillWidth, height: activeTrackFrame.height)
        let knobX = min(
            max(activeTrackFrame.minX + fillWidth - (knobSize / 2), activeTrackFrame.minX),
            activeTrackFrame.maxX - knobSize
        )
        knobView?.frame = NSRect(
            x: knobX,
            y: activeTrackFrame.midY - (knobSize / 2),
            width: knobSize,
            height: knobSize
        )
    }

    private func resizePanel(to size: NSSize) {
        guard let panel else {
            return
        }

        panel.setContentSize(size)
        containerView?.frame = NSRect(origin: .zero, size: size)
        backgroundView?.frame = NSRect(origin: .zero, size: size)
    }

    private func positionPanel() {
        guard let panel else {
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }

        let anchorCenterX = statusItemFrame()?.midX ?? fallbackStatusAreaCenterX(in: visibleFrame)
        let x = max(
            visibleFrame.minX + 8,
            min(anchorCenterX - (panel.frame.width / 2), visibleFrame.maxX - panel.frame.width - 8)
        )
        let y = visibleFrame.maxY - panel.frame.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func fallbackStatusAreaCenterX(in visibleFrame: NSRect) -> CGFloat {
        let statusAreaWidth = min(visibleFrame.width, 680)
        return visibleFrame.maxX - (statusAreaWidth / 2)
    }

    private func statusItemFrame() -> NSRect? {
        let appElement = AXUIElementCreateApplication(getpid())
        let menuBarAttributes = [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute]

        for attribute in menuBarAttributes {
            if let frame = statusItemFrame(for: attribute, in: appElement) {
                return frame
            }
        }

        return nil
    }

    private func statusItemFrame(for attribute: String, in appElement: AXUIElement) -> NSRect? {
        var menuBarsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &menuBarsValue) == .success else {
            return nil
        }

        let menuBars: [AXUIElement]
        if CFGetTypeID(menuBarsValue) == AXUIElementGetTypeID() {
            menuBars = [menuBarsValue as! AXUIElement]
        } else if CFGetTypeID(menuBarsValue) == CFArrayGetTypeID() {
            menuBars = menuBarsValue as? [AXUIElement] ?? []
        } else {
            return nil
        }

        for menuBar in menuBars {
            if let frame = statusItemFrame(in: menuBar) {
                return frame
            }
        }

        return nil
    }

    private func statusItemFrame(in menuBar: AXUIElement) -> NSRect? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if statusItemMatches(child), let frame = frame(of: child) {
                return frame
            }
        }

        return nil
    }

    private func statusItemMatches(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXTitleAttribute, from: element) == "hifispeaker" else {
            return false
        }

        return stringAttribute(kAXRoleAttribute, from: element) == kAXMenuBarItemRole
    }

    private func frame(of element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let position = positionValue,
              let size = sizeValue
        else {
            return nil
        }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        else {
            return nil
        }

        return NSRect(origin: point, size: dimensions)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }
}

private final class HUDBackgroundView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class HUDContainerView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
