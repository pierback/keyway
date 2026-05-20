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

struct MockConnectTokenStatusStore: ConnectTokenStatusChecking {
    let statusValue: ConnectTokenStatus

    init(desktopTokenAvailable: Bool, projectTokenAvailable: Bool) {
        self.statusValue = ConnectTokenStatus(
            desktopTokenAvailable: desktopTokenAvailable,
            projectTokenAvailable: projectTokenAvailable
        )
    }

    func status() -> ConnectTokenStatus {
        statusValue
    }

    func validatedStatus() async -> ConnectTokenStatus {
        statusValue
    }

    func deleteProjectToken() throws {}
}

// MARK: - Accessibility

final class MockAccessibilityAutomator: AccessibilityAutomating, @unchecked Sendable {
    let permissionGranted: Bool

    init(permissionGranted: Bool = true) {
        self.permissionGranted = permissionGranted
    }

    func checkAccessibilityPermission() -> Bool {
        permissionGranted
    }
}
