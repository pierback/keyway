import Foundation

public enum TransferErrorCode: String, Error, Equatable, Sendable {
    case noActivePlayback
    case targetNotConfigured
    case targetNotVisible
    case authRequired
    case transferVerificationFailed
    case unsupported
    case spotifyAppNotInstalled
    case spotifyAppNotRunning
    case accessibilityNotGranted
}

public enum TransferResult: Equatable, Sendable {
    case success
    case failure(code: TransferErrorCode, message: String)
}
