import Foundation

public enum KeywayChromiumBridgeEndpoint {
    public static let environmentKey = "KEYWAY_CHROMIUM_BRIDGE_ENDPOINT"

    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(KeywayChromiumBridgeContract.appBundleIdentifier, isDirectory: true)
            .appendingPathComponent("chromium-bridge.sock", isDirectory: false)
    }
}
