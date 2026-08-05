import Foundation
import Security

struct ChromiumBridgePeerIdentity: Sendable {
    let processIdentifier: pid_t
    let auditToken: Data
}

struct ChromiumBridgePeerValidator: @unchecked Sendable {
    private let validation: @Sendable (ChromiumBridgePeerIdentity) throws -> Void

    init(_ validation: @escaping @Sendable (ChromiumBridgePeerIdentity) throws -> Void) {
        self.validation = validation
    }

    func validate(peerIdentity: ChromiumBridgePeerIdentity) throws {
        try validation(peerIdentity)
    }

    static let keywayApp = codeRequirement(
        identifier: KeywayChromiumBridgeContract.appBundleIdentifier
    )

    static let nativeHost = codeRequirement(
        identifier: KeywayChromiumBridgeContract.nativeHostCodeIdentifier
    )

    private static func codeRequirement(identifier: String) -> ChromiumBridgePeerValidator {
        let requirement = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(KeywayChromiumBridgeContract.teamIdentifier)\""
        return ChromiumBridgePeerValidator { peerIdentity in
            let attributes = [
                kSecGuestAttributeAudit as String: peerIdentity.auditToken as CFData,
            ] as CFDictionary
            var guestCode: SecCode?
            let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode)
            guard guestStatus == errSecSuccess, let guestCode else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(guestStatus))
            }

            var codeRequirement: SecRequirement?
            let requirementStatus = SecRequirementCreateWithString(
                requirement as CFString,
                [],
                &codeRequirement
            )
            guard requirementStatus == errSecSuccess, let codeRequirement else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(requirementStatus))
            }

            let validationStatus = SecCodeCheckValidity(guestCode, [], codeRequirement)
            guard validationStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(validationStatus))
            }
        }
    }
}
