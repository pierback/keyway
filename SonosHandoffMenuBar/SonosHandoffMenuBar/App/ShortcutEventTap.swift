@preconcurrency import ApplicationServices
import os

@MainActor
final class ShortcutEventTap {
    enum TapKind: String {
        case hid = "cghid"

        var tapLocation: CGEventTapLocation {
            .cghidEventTap
        }
    }

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "ShortcutEventTap")
    private let onInterrupted: @MainActor (CGEventType) -> Void
    private let onEvent: @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var activeTapKind: TapKind?

    var isRunning: Bool {
        eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    init(
        onInterrupted: @escaping @MainActor (CGEventType) -> Void,
        onEvent: @escaping @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    ) {
        self.onInterrupted = onInterrupted
        self.onEvent = onEvent
    }

    func start() -> Bool {
        if isRunning {
            return true
        }
        if eventTap != nil {
            stop()
        }

        let kind = TapKind.hid
        guard let eventTap = CGEvent.tapCreate(
            tap: kind.tapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: ShortcutEventParser.eventMask,
            callback: shortcutEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("ShortcutEventTap start_failed tap=\(kind.rawValue, privacy: .public)")
            return false
        }

        self.eventTap = eventTap
        activeTapKind = kind
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        guard CGEvent.tapIsEnabled(tap: eventTap) else {
            stop()
            logger.error("ShortcutEventTap start_failed tap=\(kind.rawValue, privacy: .public) reason=not_enabled")
            return false
        }
        logger.info("ShortcutEventTap started tap=\(kind.rawValue, privacy: .public) place=headInsert options=default events=media_and_function_keys")
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        activeTapKind = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            let reenabled = isRunning
            if !reenabled {
                stop()
            }
            onInterrupted(type)
            if reenabled {
                logger.error("ShortcutEventTap reenabled reason=\(Int(type.rawValue), privacy: .public)")
            } else {
                logger.error("ShortcutEventTap reenable_failed reason=\(Int(type.rawValue), privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }

        return onEvent(type, event)
    }
}

private func shortcutEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let eventTap = Unmanaged<ShortcutEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        eventTap.handle(type: type, event: event)
    }
}
