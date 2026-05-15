import AppKit
import ApplicationServices
import Foundation
import SonosHandoffCore

private let targetName = targetArgument() ?? "Port"
private let step = max(5, min(25, optionValue("--step").flatMap(Int.init) ?? 5))
private let handoffService = SpotifyConnectHandoffService(configStore: ConfigStore())

private let mediaKeySubtype = 8
private let systemDefinedEventType = CGEventType(rawValue: 14)!
private let keyDownState = 0x0A
private let soundUpKeyCode = 0
private let soundDownKeyCode = 1
private let f11KeyCode: UInt16 = 103
private let f12KeyCode: UInt16 = 111

print("sonos-handoff-hotkeys: target=\(targetName) step=\(step)")
print("sonos-handoff-hotkeys: Shift+fn+F12 -> Port volume up")
print("sonos-handoff-hotkeys: Shift+fn+F11 -> Port volume down")

guard AXIsProcessTrusted() else {
    fputs("sonos-handoff-hotkeys: Accessibility permission is required for global media-key shortcuts.\n", stderr)
    fputs("Grant Accessibility to this executable, then run it again.\n", stderr)
    exit(2)
}

let eventMask = CGEventMask(1 << systemDefinedEventType.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: hotkeyCallback,
    userInfo: nil
) else {
    fputs("sonos-handoff-hotkeys: could not create event tap. Check Accessibility/Input Monitoring permissions.\n", stderr)
    exit(2)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)
CFRunLoopRun()

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let nsEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        return handleFunctionKey(event: event, nsEvent: nsEvent)
    }

    guard type == systemDefinedEventType, nsEvent.subtype.rawValue == mediaKeySubtype else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
    let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
    guard keyState == keyDownState else {
        return Unmanaged.passUnretained(event)
    }

    let modifiers = nsEvent.modifierFlags
    guard modifiers.contains(.shift) else {
        return Unmanaged.passUnretained(event)
    }

    if keyCode == soundDownKeyCode {
        runVolumeCommand("volume-down")
        return nil
    }

    if keyCode == soundUpKeyCode {
        runVolumeCommand("volume-up")
        return nil
    }

    return Unmanaged.passUnretained(event)
}

private func handleFunctionKey(event: CGEvent, nsEvent: NSEvent) -> Unmanaged<CGEvent>? {
    guard nsEvent.modifierFlags.contains(.shift) else {
        return Unmanaged.passUnretained(event)
    }

    if nsEvent.keyCode == f11KeyCode {
        runVolumeCommand("volume-down")
        return nil
    }

    if nsEvent.keyCode == f12KeyCode {
        runVolumeCommand("volume-up")
        return nil
    }

    return Unmanaged.passUnretained(event)
}

private func runVolumeCommand(_ command: String) {
    Task.detached(priority: .userInitiated) {
        do {
            let volume: Int
            switch command {
            case "volume-down":
                volume = try await handoffService.volumeDown(roomName: targetName, step: step)
            case "volume-up":
                volume = try await handoffService.volumeUp(roomName: targetName, step: step)
            default:
                return
            }
            print("\(command)=ok volume=\(volume)")
        } catch {
            fputs("sonos-handoff-hotkeys: \(command) failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

private func targetArgument() -> String? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var skipNext = false
    for argument in arguments {
        if skipNext {
            skipNext = false
            continue
        }

        if argument == "--step" {
            skipNext = true
            continue
        }

        if argument.hasPrefix("--") {
            continue
        }

        return argument.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    return nil
}

private func optionValue(_ option: String) -> String? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    for (index, argument) in arguments.enumerated() where argument == option {
        guard index + 1 < arguments.count else {
            return nil
        }

        return arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    let prefix = "\(option)="
    return arguments
        .first { $0.hasPrefix(prefix) }?
        .dropFirst(prefix.count)
        .description
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
