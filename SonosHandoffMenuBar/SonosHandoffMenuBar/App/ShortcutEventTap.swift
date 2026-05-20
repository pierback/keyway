@preconcurrency import ApplicationServices

@MainActor
final class ShortcutEventTap {
    private let onEvent: @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        eventTap != nil
    }

    init(onEvent: @escaping @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        self.onEvent = onEvent
    }

    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: ShortcutEventParser.eventMask,
            callback: shortcutEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.eventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
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
