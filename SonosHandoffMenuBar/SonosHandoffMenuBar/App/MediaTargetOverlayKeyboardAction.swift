import Foundation

enum MediaTargetOverlayKeyboardAction: Equatable {
    case moveSelection(Int)
    case adjustExpandedVolume(MediaAudioVolumeDirection)
    case routeSelected
    case focusSelected
    case close
    case toggleControls
    case quickRoute(Int)
    case quickSelect(Int)
    case none
}

enum MediaTargetOverlayKeyboardInterpreter {
    static func action(
        keyCode: UInt16,
        characters: String,
        commandDown: Bool,
        expanded: Bool,
        targetCount: Int
    ) -> MediaTargetOverlayKeyboardAction {
        if expanded, commandDown, keyCode == 126 {
            return .adjustExpandedVolume(.up)
        }
        if expanded, commandDown, keyCode == 125 {
            return .adjustExpandedVolume(.down)
        }

        switch keyCode {
        case 126:
            return .moveSelection(-1)
        case 125:
            return .moveSelection(1)
        case 36, 76:
            return commandDown ? .focusSelected : .routeSelected
        case 53:
            return .close
        case 48:
            return .toggleControls
        default:
            break
        }

        guard let number = Int(characters), (1 ... 9).contains(number) else {
            return .none
        }

        let index = number - 1
        guard index < targetCount else {
            return .none
        }
        return expanded ? .quickSelect(index) : .quickRoute(index)
    }
}
