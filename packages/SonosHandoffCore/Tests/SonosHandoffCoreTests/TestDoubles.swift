import Foundation
@testable import SonosHandoffCore

// MARK: - Config

struct MockConfigStore: ConfigStoring {
    var config: AppConfig

    init(config: AppConfig = AppConfig()) {
        self.config = config
    }

    func load() throws -> AppConfig {
        config
    }

    func save(_ config: AppConfig) throws {}
}

// MARK: - Tokens

struct MockTokenStore: TokenStoring {
    let token: String?

    func saveRefreshToken(_ token: String) throws {}

    func loadRefreshToken() throws -> String? {
        token
    }

    func deleteRefreshToken() throws {}
}

struct FailingSaveTokenStore: TokenStoring {
    func saveRefreshToken(_ token: String) throws {
        throw TokenStoreError.encodingFailed
    }

    func loadRefreshToken() throws -> String? {
        nil
    }

    func deleteRefreshToken() throws {}
}
