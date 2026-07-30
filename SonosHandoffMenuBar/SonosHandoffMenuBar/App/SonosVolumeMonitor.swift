import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class SonosVolumeMonitor: ObservableObject {
    static let shared = SonosVolumeMonitor()

    @Published private(set) var snapshot: SpeakerVolumeSnapshot?

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "VolumeMonitor")
    private var volumeService: (any SpeakerVolumeAdjusting)?
    private var volumeCommands: SpeakerVolumeCommandQueue = .shared
    private var pollTask: Task<Void, Never>?
    private var selectedRoomName: String?
    private var selectedScope = PlaybackVolumeScope.member
    private var pollInFlight = false
    private var suppressUntil = Date.distantPast
    private var suppressedRoomName: String?
    private let reconciler = SpeakerVolumeMonitorReconciler()
    private static let pollIntervalNanoseconds: UInt64 = 450_000_000
    private static let localChangeSuppressionSeconds: TimeInterval = 1.25

    private init() {}

    func start(
        volumeService: any SpeakerVolumeAdjusting,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = volumeService
        self.volumeCommands = volumeCommands

        guard pollTask == nil else {
            return
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        volumeService = nil
        selectedRoomName = nil
        selectedScope = .member
        pollInFlight = false
        suppressUntil = .distantPast
        suppressedRoomName = nil
        snapshot = nil
    }

    func setTarget(roomName: String?, scope: PlaybackVolumeScope) {
        let normalizedRoomName = SonosRoomName.normalized(roomName)
        guard !SonosRoomName.matches(selectedRoomName, normalizedRoomName) || selectedScope != scope else {
            return
        }

        selectedRoomName = normalizedRoomName
        selectedScope = scope
        snapshot = nil
    }

    func noteLocalChange(roomName: String, volume: Int? = nil, muted: Bool? = nil) {
        suppressUntil = Date().addingTimeInterval(Self.localChangeSuppressionSeconds)
        suppressedRoomName = roomName

        guard let nextSnapshot = reconciler.snapshotAfterLocalChange(
            previousSnapshot: snapshot,
            roomName: roomName,
            volume: volume,
            muted: muted
        ) else { return }

        snapshot = nextSnapshot
    }

    private func pollOnce() async {
        guard !pollInFlight,
              let volumeService,
              let roomName = selectedRoomName
        else {
            return
        }
        let scope = selectedScope

        pollInFlight = true
        defer { pollInFlight = false }

        let result: Result<SpeakerVolumeStatus, Error>
        do {
            switch scope {
            case .member:
                result = .success(try await volumeCommands.volumeStatus(using: volumeService, roomName: roomName))
            case .group:
                result = .success(try await volumeCommands.groupVolumeStatus(using: volumeService, coordinatorRoomName: roomName))
            }
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success(let status):
            guard SonosRoomName.matches(selectedRoomName, roomName),
                  selectedScope == scope
            else {
                logger.info("SonosHandoffVolumeMonitor state=stale_ignored room=\(roomName, privacy: .public)")
                return
            }
            apply(status: status)
        case .failure(let error):
            logger.error("SonosHandoffVolumeMonitor result=failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(status: SpeakerVolumeStatus) {
        let decision = reconciler.reconcile(
            previousSnapshot: snapshot,
            status: status,
            suppressFeedback: isFeedbackSuppressed(status: status)
        )
        snapshot = decision.snapshot

        switch decision.logEvent {
        case .some(.primed):
            logger.info("SonosHandoffVolumeMonitor state=primed room=\(status.roomName, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public)")
        case .some(.changed):
            logger.info("SonosHandoffVolumeMonitor state=changed room=\(status.roomName, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public)")
        case nil:
            break
        }

        switch decision.feedback {
        case .some(.volume):
            StatusHUD.shared.showVolume(roomName: status.roomName, volume: status.volume, dismissAfter: 1.6)
        case .some(.mute):
            StatusHUD.shared.showMute(roomName: status.roomName, muted: status.muted, dismissAfter: 1.6)
        case nil:
            break
        }
    }

    private func isFeedbackSuppressed(status: SpeakerVolumeStatus) -> Bool {
        guard Date() < suppressUntil,
              let suppressedRoomName,
              SonosRoomName.matches(suppressedRoomName, status.roomName)
        else {
            return false
        }

        return true
    }
}
