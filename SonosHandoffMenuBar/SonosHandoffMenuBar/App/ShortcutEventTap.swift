@preconcurrency import ApplicationServices
import os

@MainActor
final class ShortcutEventTap {
    enum TapKind: String {
        case hid = "cghid"
        case session = "session"

        var tapLocation: CGEventTapLocation {
            switch self {
            case .hid:
                .cghidEventTap
            case .session:
                .cgSessionEventTap
            }
        }
    }

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "ShortcutEventTap")
    private let onInterrupted: @MainActor (CGEventType) -> Void
    private let onEvent: @MainActor (TapKind, CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private var hidEventTap: CFMachPort?
    private var sessionEventTap: CFMachPort?
    private var hidRunLoopSource: CFRunLoopSource?
    private var sessionRunLoopSource: CFRunLoopSource?
    private(set) var activeTapKind: TapKind?

    var isRunning: Bool {
        guard let hidEventTap, let sessionEventTap else {
            return false
        }
        return CGEvent.tapIsEnabled(tap: hidEventTap)
            && CGEvent.tapIsEnabled(tap: sessionEventTap)
    }

    init(
        onInterrupted: @escaping @MainActor (CGEventType) -> Void,
        onEvent: @escaping @MainActor (TapKind, CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    ) {
        self.onInterrupted = onInterrupted
        self.onEvent = onEvent
    }

    func start() -> Bool {
        if isRunning {
            return true
        }
        if hidEventTap != nil || sessionEventTap != nil {
            stop()
        }

        guard let hidEventTap = CGEvent.tapCreate(
            tap: TapKind.hid.tapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: ShortcutEventParser.eventMask,
            callback: shortcutHIDEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("ShortcutEventTap start_failed tap=\(TapKind.hid.rawValue, privacy: .public)")
            return false
        }
        guard let sessionEventTap = CGEvent.tapCreate(
            tap: TapKind.session.tapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: ShortcutEventParser.systemDefinedEventMask,
            callback: shortcutSessionEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("ShortcutEventTap start_failed tap=\(TapKind.session.rawValue, privacy: .public)")
            return false
        }

        self.hidEventTap = hidEventTap
        self.sessionEventTap = sessionEventTap
        hidRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, hidEventTap, 0)
        sessionRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, sessionEventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), hidRunLoopSource, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), sessionRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: hidEventTap, enable: true)
        CGEvent.tapEnable(tap: sessionEventTap, enable: true)
        activeTapKind = .hid
        guard isRunning else {
            stop()
            logger.error("ShortcutEventTap start_failed tap=pair reason=not_enabled")
            return false
        }
        logger.info("ShortcutEventTap started taps=cghid,session place=headInsert options=default events=media_and_function_keys,transport_media_keys")
        return true
    }

    func stop() {
        if let hidEventTap {
            CGEvent.tapEnable(tap: hidEventTap, enable: false)
        }
        if let sessionEventTap {
            CGEvent.tapEnable(tap: sessionEventTap, enable: false)
        }
        if let hidRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), hidRunLoopSource, .commonModes)
        }
        if let sessionRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), sessionRunLoopSource, .commonModes)
        }
        hidRunLoopSource = nil
        sessionRunLoopSource = nil
        hidEventTap = nil
        sessionEventTap = nil
        activeTapKind = nil
    }

    func handle(tapKind: TapKind, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let interruptedTap = switch tapKind {
            case .hid:
                hidEventTap
            case .session:
                sessionEventTap
            }
            if let interruptedTap {
                CGEvent.tapEnable(tap: interruptedTap, enable: true)
            }
            let reenabled = isRunning
            if !reenabled {
                stop()
            }
            onInterrupted(type)
            if reenabled {
                logger.error("ShortcutEventTap reenabled tap=\(tapKind.rawValue, privacy: .public) reason=\(Int(type.rawValue), privacy: .public)")
            } else {
                logger.error("ShortcutEventTap reenable_failed tap=\(tapKind.rawValue, privacy: .public) reason=\(Int(type.rawValue), privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }

        return onEvent(tapKind, type, event)
    }
}

private func shortcutHIDEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    shortcutEventTapCallback(tapKind: .hid, type: type, event: event, refcon: refcon)
}

private func shortcutSessionEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    shortcutEventTapCallback(tapKind: .session, type: type, event: event, refcon: refcon)
}

private func shortcutEventTapCallback(
    tapKind: ShortcutEventTap.TapKind,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let eventTap = Unmanaged<ShortcutEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        eventTap.handle(tapKind: tapKind, type: type, event: event)
    }
}
