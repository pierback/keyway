import SonosHandoffCore

typealias VolumeDirection = SpeakerVolumeChangeDirection

enum PlaybackVolumeScope: Equatable, Sendable {
    case member
    case group
}

extension SpeakerVolumeChangeDirection {
    var logName: String {
        switch self {
        case .down:
            return "down"
        case .up:
            return "up"
        }
    }
}
