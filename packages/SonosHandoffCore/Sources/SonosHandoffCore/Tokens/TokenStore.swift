import Foundation
import Security

public protocol TokenStoring {
    func saveRefreshToken(_ token: String) throws
    func loadRefreshToken() throws -> String?
    func deleteRefreshToken() throws
}

public enum TokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    public init(
        service: String = AppIdentity.spotifyKeychainService,
        account: String = AppIdentity.spotifyRefreshTokenAccount
    ) {
        self.service = service
        self.account = account
    }

    public func saveRefreshToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        SecItemDelete(query as CFDictionary)

        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(status)
        }
    }

    public func loadRefreshToken() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public func deleteRefreshToken() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unexpectedStatus(status)
        }
    }
}
