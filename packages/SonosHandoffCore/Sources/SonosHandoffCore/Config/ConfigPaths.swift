import Foundation

public enum ConfigPaths {
    public static var applicationSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/sonos-handoff", isDirectory: true)
    }

    public static var configFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }
}

