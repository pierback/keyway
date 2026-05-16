import SonosHandoffCore

typealias VolumeDirection = SpeakerVolumeChangeDirection

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
