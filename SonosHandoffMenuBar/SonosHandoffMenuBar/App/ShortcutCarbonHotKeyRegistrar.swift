@preconcurrency import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class ShortcutCarbonHotKeyRegistrar {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let onHotKey: @MainActor (UInt32) -> Void
    private var eventHandler: EventHandlerRef?
    private var volumeDownHotKey: EventHotKeyRef?
    private var volumeUpHotKey: EventHotKeyRef?
    private var muteHotKey: EventHotKeyRef?
    private var didInstallHandler = false

    private(set) var plainHotkeysRegistered = false

    init(onHotKey: @escaping @MainActor (UInt32) -> Void) {
        self.onHotKey = onHotKey
    }

    func installHandlerIfNeeded() -> Bool {
        if didInstallHandler {
            return true
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            shortcutCarbonHotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            logger.error("SonosHandoffHotkeys carbon=disabled reason=install_handler_failed status=\(installStatus, privacy: .public)")
            return false
        }

        didInstallHandler = true
        return true
    }

    func registerPlainFunctionHotKeys(step: Int) -> Bool {
        guard didInstallHandler, !plainHotkeysRegistered else {
            return plainHotkeysRegistered
        }

        registerCarbonHotKey(
            keyCode: UInt32(kVK_F10),
            id: 5,
            modifiers: UInt32(shiftKey),
            storage: &muteHotKey,
            name: "shift_f10_mute_toggle",
            step: step
        )
        registerCarbonHotKey(
            keyCode: UInt32(kVK_F11),
            id: 1,
            modifiers: UInt32(shiftKey),
            storage: &volumeDownHotKey,
            name: "shift_f11_volume_down",
            step: step
        )
        registerCarbonHotKey(
            keyCode: UInt32(kVK_F12),
            id: 2,
            modifiers: UInt32(shiftKey),
            storage: &volumeUpHotKey,
            name: "shift_f12_volume_up",
            step: step
        )
        plainHotkeysRegistered = muteHotKey != nil && volumeDownHotKey != nil && volumeUpHotKey != nil
        return plainHotkeysRegistered
    }

    func handleHotKey(id: UInt32) {
        onHotKey(id)
    }

    func stop() {
        for (name, hotKey) in [
            ("shift_f10_mute_toggle", muteHotKey),
            ("shift_f11_volume_down", volumeDownHotKey),
            ("shift_f12_volume_up", volumeUpHotKey),
        ] {
            guard let hotKey else {
                continue
            }
            let status = UnregisterEventHotKey(hotKey)
            if status != noErr {
                logger.error("SonosHandoffHotkeys carbon=stop_failed hotkey=\(name, privacy: .public) status=\(status, privacy: .public)")
            }
        }
        muteHotKey = nil
        volumeDownHotKey = nil
        volumeUpHotKey = nil
        plainHotkeysRegistered = false

        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            if status != noErr {
                logger.error("SonosHandoffHotkeys carbon=stop_failed resource=event_handler status=\(status, privacy: .public)")
            }
        }
        eventHandler = nil
        didInstallHandler = false
    }

    private func registerCarbonHotKey(
        keyCode: UInt32,
        id: UInt32,
        modifiers: UInt32,
        storage: inout EventHotKeyRef?,
        name: String,
        step: Int
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
            logger.info("SonosHandoffHotkeys carbon=enabled hotkey=\(name, privacy: .public) step=\(step, privacy: .public)")
        } else {
            logger.error("SonosHandoffHotkeys carbon=disabled hotkey=\(name, privacy: .public) status=\(status, privacy: .public)")
        }
    }

    private static let hotKeySignature = OSType(
        UInt32(Character("S").asciiValue!) << 24 |
            UInt32(Character("O").asciiValue!) << 16 |
            UInt32(Character("N").asciiValue!) << 8 |
            UInt32(Character("O").asciiValue!)
    )
}

private func shortcutCarbonHotKeyCallback(
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

    let registrar = Unmanaged<ShortcutCarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        registrar.handleHotKey(id: hotKeyID.id)
        return noErr
    }
}
