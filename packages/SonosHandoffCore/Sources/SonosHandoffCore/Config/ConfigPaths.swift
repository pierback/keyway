import Foundation

public enum ConfigPaths {
    public static var applicationSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(AppIdentity.applicationSupportDirectoryName)", isDirectory: true)
    }

    public static var legacyApplicationSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(AppIdentity.legacyApplicationSupportDirectoryName)", isDirectory: true)
    }

    public static var configFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }
}
