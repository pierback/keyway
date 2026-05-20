public protocol AccessibilityAutomating {
    func checkAccessibilityPermission() -> Bool
}

public struct SpotifyUIAutomator: AccessibilityAutomating {
    public init() {}

    public func checkAccessibilityPermission() -> Bool {
        AccessibilityPermission.isGranted()
    }
}
