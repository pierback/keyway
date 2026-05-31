@preconcurrency import AppKit
import ApplicationServices

enum ShortcutEventOutcome: Equatable {
    case passThrough
    case transportKeyDown(command: MediaRemoteTransportCommand, source: String, metadata: MediaTransportInputMetadata)
    case transportKeyUp(command: MediaRemoteTransportCommand, source: String, metadata: MediaTransportInputMetadata)
    case volumeHoldStart(direction: VolumeDirection, source: String)
    case volumeHoldStop(source: String)
    case muteToggle(source: String)
}

struct ShortcutEventDiagnostic: Equatable {
    let eventType: UInt32
    let subtype: Int
    let data1: Int
    let keyCode: Int
    let keyState: Int
    let metadata: MediaTransportInputMetadata
}

struct ShortcutEventParser {
    // macOS reports media-key presses through NX_SYSDEFINED instead of typed key events.
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!

    static let eventMask = CGEventMask(1 << systemDefinedEventType.rawValue)
        | CGEventMask(1 << CGEventType.keyDown.rawValue)
        | CGEventMask(1 << CGEventType.keyUp.rawValue)

    private let mediaKeySubtype = 8
    private let keyDownEventType = CGEventType.keyDown
    private let keyUpEventType = CGEventType.keyUp
    private let keyDownState = 0x0A
    private let keyUpState = 0x0B
    private let soundMuteKeyCode = 7
    private let soundUpKeyCode = 0
    private let soundDownKeyCode = 1
    private let observedPlayPauseKeyCode = 2
    private let playPauseKeyCode = 16
    private let nextKeyCode = 17
    private let previousKeyCode = 18
    private let f7KeyCode: Int64 = 98
    private let f8KeyCode: Int64 = 100
    private let f9KeyCode: Int64 = 101
    private let f10KeyCode: Int64 = 109
    private let f11KeyCode: Int64 = 103
    private let f12KeyCode: Int64 = 111

    func outcome(type: CGEventType, event: CGEvent, isRepeating: Bool) -> ShortcutEventOutcome {
        if type == keyDownEventType || type == keyUpEventType {
            return functionKeyOutcome(type: type, event: event, isRepeating: isRepeating)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              type == Self.systemDefinedEventType,
              nsEvent.subtype.rawValue == mediaKeySubtype
        else {
            return .passThrough
        }

        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
        if let command = transportCommand(for: keyCode) {
            let metadata = transportInputMetadata(from: event)
            let source = keyCode == observedPlayPauseKeyCode ? "media_key_observed_play_pause" : "media_key"
            if keyState == keyDownState {
                return .transportKeyDown(command: command, source: source, metadata: metadata)
            }
            if keyState == keyUpState {
                return .transportKeyUp(command: command, source: source, metadata: metadata)
            }
        }

        if keyState == keyUpState,
           keyCode == soundDownKeyCode || keyCode == soundUpKeyCode {
            guard isRepeating || nsEvent.modifierFlags.contains(.shift) else {
                return .passThrough
            }

            return .volumeHoldStop(source: "media_key")
        }

        guard nsEvent.modifierFlags.contains(.shift) else {
            return .passThrough
        }

        if keyState == keyDownState {
            if keyCode == soundDownKeyCode {
                return .volumeHoldStart(direction: .down, source: "media_key")
            }

            if keyCode == soundUpKeyCode {
                return .volumeHoldStart(direction: .up, source: "media_key")
            }

            if keyCode == soundMuteKeyCode {
                return .muteToggle(source: "media_key")
            }
        }

        return .passThrough
    }

    func unhandledSystemDefinedDiagnostic(
        type: CGEventType,
        event: CGEvent
    ) -> ShortcutEventDiagnostic? {
        guard let nsEvent = NSEvent(cgEvent: event),
              type == Self.systemDefinedEventType,
              nsEvent.subtype.rawValue == mediaKeySubtype
        else {
            return nil
        }

        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
        return ShortcutEventDiagnostic(
            eventType: type.rawValue,
            subtype: Int(nsEvent.subtype.rawValue),
            data1: nsEvent.data1,
            keyCode: keyCode,
            keyState: keyState,
            metadata: transportInputMetadata(from: event)
        )
    }

    private func transportInputMetadata(from event: CGEvent) -> MediaTransportInputMetadata {
        MediaTransportInputMetadata(
            sourceUnixProcessID: event.getIntegerValueField(.eventSourceUnixProcessID),
            sourceStateID: event.getIntegerValueField(.eventSourceStateID),
            sourceUserData: event.getIntegerValueField(.eventSourceUserData),
            targetUnixProcessID: event.getIntegerValueField(.eventTargetUnixProcessID),
            sourceUserID: event.getIntegerValueField(.eventSourceUserID),
            sourceGroupID: event.getIntegerValueField(.eventSourceGroupID),
            eventTimestamp: event.timestamp
        )
    }

    private func transportCommand(for keyCode: Int) -> MediaRemoteTransportCommand? {
        switch keyCode {
        case observedPlayPauseKeyCode, playPauseKeyCode:
            return .playPause
        case nextKeyCode:
            return .next
        case previousKeyCode:
            return .previous
        default:
            return nil
        }
    }

    private func functionKeyOutcome(type: CGEventType, event: CGEvent, isRepeating: Bool) -> ShortcutEventOutcome {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if let command = transportFunctionKeyCommand(for: keyCode) {
            let metadata = transportInputMetadata(from: event)
            if type == keyDownEventType {
                return .transportKeyDown(command: command, source: "function_key", metadata: metadata)
            }
            if type == keyUpEventType {
                return .transportKeyUp(command: command, source: "function_key", metadata: metadata)
            }
        }

        if type == keyUpEventType,
           keyCode == f11KeyCode || keyCode == f12KeyCode {
            guard isRepeating || (flags.contains(.maskSecondaryFn) && flags.contains(.maskShift)) else {
                return .passThrough
            }

            return .volumeHoldStop(source: "function_key")
        }

        guard flags.contains(.maskSecondaryFn), flags.contains(.maskShift) else {
            return .passThrough
        }

        guard type == keyDownEventType else {
            return .passThrough
        }

        if keyCode == f11KeyCode {
            return .volumeHoldStart(direction: .down, source: "shift_fn_f11")
        }

        if keyCode == f12KeyCode {
            return .volumeHoldStart(direction: .up, source: "shift_fn_f12")
        }

        if keyCode == f10KeyCode {
            return .muteToggle(source: "shift_fn_f10")
        }

        return .passThrough
    }

    private func transportFunctionKeyCommand(for keyCode: Int64) -> MediaRemoteTransportCommand? {
        switch keyCode {
        case f7KeyCode:
            return .previous
        case f8KeyCode:
            return .playPause
        case f9KeyCode:
            return .next
        default:
            return nil
        }
    }
}
