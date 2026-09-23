@preconcurrency import AppKit
import Carbon.HIToolbox
import os

/// Actions the user can bind to a global shortcut in Settings → Shortcuts. Unset by default.
enum GlobalShortcutAction: String, CaseIterable, Identifiable {
    case openPlayingSource
    case showSourceChooser
    case sendSpotifyToHeadphones
    case openKeywayMenu

    var id: String { rawValue }

    var defaultsKey: String { "shortcuts.\(rawValue)" }

    var title: String {
        switch self {
        case .openPlayingSource: return "Open playing source"
        case .showSourceChooser: return "Show source chooser"
        case .sendSpotifyToHeadphones: return "Send Spotify to headphones"
        case .openKeywayMenu: return "Open Keyway menu"
        }
    }

    var detail: String {
        switch self {
        case .openPlayingSource: return "Brings Spotify, the browser tab, or QuickTime that is playing to the front."
        case .showSourceChooser: return "Opens the centered chooser to pick where media keys go."
        case .sendSpotifyToHeadphones: return "Moves Spotify playback to this Mac's connected headphones."
        case .openKeywayMenu: return "Toggles the Keyway menu bar panel."
        }
    }
}

/// A key combination stored in UserDefaults as "keyCode:carbonModifiers:label".
struct GlobalShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let label: String

    init?(storage: String?) {
        let parts = storage?.split(separator: ":", maxSplits: 2).map(String.init) ?? []
        guard parts.count == 3, let keyCode = UInt32(parts[0]), let carbonModifiers = UInt32(parts[1]) else {
            return nil
        }
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = parts[2]
    }

    /// A recorder key press; nil unless it holds Command, Option, or Control, or is a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)
        let functionKeyLabels = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        let specialKeyLabels = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        guard !flags.isDisjoint(with: [.command, .option, .control]) || functionKeyLabels[keyCode] != nil,
              let key = functionKeyLabels[keyCode]
                ?? specialKeyLabels[keyCode]
                ?? event.charactersIgnoringModifiers.flatMap({ $0.isEmpty ? nil : $0.uppercased() })
        else {
            return nil
        }

        var carbonModifiers: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey); symbols += "⌘" }
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = carbonModifiers
        self.label = symbols + key
    }

    var storage: String { "\(keyCode):\(carbonModifiers):\(label)" }
}

extension Notification.Name {
    /// Posted by the Settings recorder with a Bool object: true while it captures a key press.
    static let keywayShortcutRecordingChanged = Notification.Name("com.fpieringer.Keyway.shortcutRecordingChanged")
}

/// Registers the Settings → Shortcuts bindings as Carbon global hotkeys and performs their actions.
@MainActor
final class GlobalShortcutController {
    fileprivate nonisolated static let hotKeySignature: OSType = 0x4B57_5343 // "KWSC"

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let perform: @MainActor (GlobalShortcutAction) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var registeredStorage: [String?] = []
    private var isRecording = false
    private var observers: [NSObjectProtocol] = []

    init(perform: @escaping @MainActor (GlobalShortcutAction) -> Void) {
        self.perform = perform
    }

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalShortcutHotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        precondition(status == noErr, "Installing the global shortcut handler failed: \(status)")

        observers = [
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.registerIfChanged() }
            },
            NotificationCenter.default.addObserver(
                forName: .keywayShortcutRecordingChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let recording = notification.object as! Bool
                MainActor.assumeIsolated {
                    self?.isRecording = recording
                    self?.registerIfChanged()
                }
            },
        ]
        registerIfChanged()
    }

    fileprivate func handleHotKey(id: UInt32) {
        let action = GlobalShortcutAction.allCases[Int(id)]
        logger.info("KeywayShortcut action=\(action.rawValue, privacy: .public)")
        perform(action)
    }

    /// Re-registers only when a binding or the recording state changed; UserDefaults posts for every write.
    private func registerIfChanged() {
        // While Settings records a shortcut, release every hotkey so an existing combination can be re-recorded.
        let storage = isRecording
            ? GlobalShortcutAction.allCases.map { _ in nil }
            : GlobalShortcutAction.allCases.map { UserDefaults.standard.string(forKey: $0.defaultsKey) }
        guard storage != registeredStorage else {
            return
        }
        registeredStorage = storage

        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys = []
        for (index, action) in GlobalShortcutAction.allCases.enumerated() {
            guard let shortcut = GlobalShortcut(storage: storage[index]) else {
                continue
            }
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                EventHotKeyID(signature: Self.hotKeySignature, id: UInt32(index)),
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            guard status == noErr, let hotKey else {
                logger.error("KeywayShortcut register=failed action=\(action.rawValue, privacy: .public) shortcut=\(shortcut.label, privacy: .public) status=\(status, privacy: .public)")
                continue
            }
            hotKeys.append(hotKey)
            logger.info("KeywayShortcut register=ok action=\(action.rawValue, privacy: .public) shortcut=\(shortcut.label, privacy: .public)")
        }
    }
}

private func globalShortcutHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
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
    guard status == noErr, hotKeyID.signature == GlobalShortcutController.hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<GlobalShortcutController>.fromOpaque(userData!).takeUnretainedValue()
    MainActor.assumeIsolated {
        controller.handleHotKey(id: hotKeyID.id)
    }
    return noErr
}
