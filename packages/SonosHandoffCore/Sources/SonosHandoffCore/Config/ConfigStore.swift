import Foundation

public protocol ConfigStoring {
    func load() throws -> AppConfig
    func save(_ config: AppConfig) throws
}

public enum ConfigStoreError: Error, Equatable {
    case unreadable(String)
    case unwritable(String)
}

public struct ConfigStore: ConfigStoring, @unchecked Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let configURL: URL

    public init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default,
        configURL: URL = ConfigPaths.configFileURL
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.fileManager = fileManager
        self.configURL = configURL
    }

    public func load() throws -> AppConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return AppConfig()
        }

        do {
            let data = try Data(contentsOf: configURL)
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            throw ConfigStoreError.unreadable(error.localizedDescription)
        }
    }

    public func save(_ config: AppConfig) throws {
        do {
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            throw ConfigStoreError.unwritable(error.localizedDescription)
        }
    }
}
