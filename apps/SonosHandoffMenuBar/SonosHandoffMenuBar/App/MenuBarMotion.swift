import SwiftUI

@MainActor
enum MenuBarMotion {
    static let modeSwitch = Animation.smooth(duration: 0.18)
    static let rowUpdate = Animation.smooth(duration: 0.16)
    static let selection = Animation.smooth(duration: 0.12)
    static let rowTransition = AnyTransition.opacity
    static let modeTransition = AnyTransition.opacity
    static let statusTransition = AnyTransition.opacity
}
