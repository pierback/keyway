import Foundation

public enum TransferErrorCode: String, Error, Equatable, Sendable {
    case targetNotVisible
    case authRequired
    case transferVerificationFailed
    case unsupported
}

public enum TransferResult: Equatable, Sendable {
    case success
    case failure(code: TransferErrorCode, message: String)
}
