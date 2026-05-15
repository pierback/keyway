import ApplicationServices
import Foundation

public enum AccessibilityPermission {
    public static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
