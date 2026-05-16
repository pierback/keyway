import Foundation

public enum SpeakerVolumeChangeDirection: Equatable, Sendable {
    case down
    case up
}

public enum SpeakerVolumeMonitorLogEvent: Equatable, Sendable {
    case primed
    case changed
}

public enum SpeakerVolumeMonitorFeedback: Equatable, Sendable {
    case volume(direction: SpeakerVolumeChangeDirection)
    case mute
}

public struct SpeakerVolumeSnapshot: Equatable, Sendable {
    public let roomName: String
    public let host: String
    public let volume: Int
    public let outputFixed: Bool
    public let muted: Bool

    public init(status: SpeakerVolumeStatus) {
        self.roomName = status.roomName
        self.host = status.host
        self.volume = status.volume
        self.outputFixed = status.outputFixed
        self.muted = status.muted
    }

    public init(roomName: String, host: String, volume: Int, outputFixed: Bool, muted: Bool) {
        self.roomName = roomName
        self.host = host
        self.volume = volume
        self.outputFixed = outputFixed
        self.muted = muted
    }
}

public struct SpeakerVolumeMonitorDecision: Equatable, Sendable {
    public let snapshot: SpeakerVolumeSnapshot
    public let logEvent: SpeakerVolumeMonitorLogEvent?
    public let feedback: SpeakerVolumeMonitorFeedback?

    public init(
        snapshot: SpeakerVolumeSnapshot,
        logEvent: SpeakerVolumeMonitorLogEvent?,
        feedback: SpeakerVolumeMonitorFeedback?
    ) {
        self.snapshot = snapshot
        self.logEvent = logEvent
        self.feedback = feedback
    }
}

public struct SpeakerVolumeMonitorReconciler: Sendable {
    public init() {}

    public func reconcile(
        previousSnapshot: SpeakerVolumeSnapshot?,
        status: SpeakerVolumeStatus,
        suppressFeedback: Bool
    ) -> SpeakerVolumeMonitorDecision {
        let nextSnapshot = SpeakerVolumeSnapshot(status: status)

        guard let previousSnapshot,
              SonosRoomName.matches(previousSnapshot.roomName, status.roomName)
        else {
            return SpeakerVolumeMonitorDecision(
                snapshot: nextSnapshot,
                logEvent: .primed,
                feedback: nil
            )
        }

        let volumeChanged = previousSnapshot.volume != status.volume
        let muteChanged = previousSnapshot.muted != status.muted
        guard volumeChanged || muteChanged else {
            return SpeakerVolumeMonitorDecision(
                snapshot: nextSnapshot,
                logEvent: nil,
                feedback: nil
            )
        }

        let feedback: SpeakerVolumeMonitorFeedback?
        if suppressFeedback {
            feedback = nil
        } else if volumeChanged {
            feedback = .volume(direction: status.volume < previousSnapshot.volume ? .down : .up)
        } else {
            feedback = .mute
        }

        return SpeakerVolumeMonitorDecision(
            snapshot: nextSnapshot,
            logEvent: .changed,
            feedback: feedback
        )
    }

    public func snapshotAfterLocalChange(
        previousSnapshot: SpeakerVolumeSnapshot?,
        roomName: String,
        volume: Int? = nil,
        muted: Bool? = nil
    ) -> SpeakerVolumeSnapshot? {
        guard let previousSnapshot,
              SonosRoomName.matches(previousSnapshot.roomName, roomName)
        else {
            return nil
        }

        return SpeakerVolumeSnapshot(
            roomName: previousSnapshot.roomName,
            host: previousSnapshot.host,
            volume: volume ?? previousSnapshot.volume,
            outputFixed: previousSnapshot.outputFixed,
            muted: muted ?? previousSnapshot.muted
        )
    }

}
