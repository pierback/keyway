import AVFoundation
import Combine
import Foundation
import MediaPlayer
import os
import SonosHandoffCore

@MainActor
final class MediaCommandCenterInterceptor {
    nonisolated(unsafe) private static let routeShieldRenderBlock: AVAudioSourceNodeRenderBlock = { _, _, _, audioBufferList -> OSStatus in
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else {
                continue
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0 ..< count {
                samples[index] = 0.0000001
            }
        }
        return noErr
    }

    nonisolated private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaCommandCenter")
    private let mediaSourceStore: MediaSourceStore
    private let mediaRemoteController: MediaRemoteController
    private let route: @MainActor (MediaRemoteTransportCommand, MediaCommandCenterInputMetadata) -> Void
    private let readinessChanged: @MainActor (Bool) -> Void
    private var commandTargets: [Any] = []
    private var routeShieldPlaybackSubscription: AnyCancellable?
    private let routeShieldEngine = AVAudioEngine()
    private var routeShieldSourceNode: AVAudioSourceNode?
    private var isRunning = false
    private(set) var isReady = false
    private var activeHelperGeneration: UInt?
    private var routeShieldRequestSequence = 0
    private var routeShieldRequestInFlight = false
    private var desiredRouteShieldPlayback = false
    private var acknowledgedRouteShieldPlayback: Bool?

    init(
        mediaSourceStore: MediaSourceStore,
        mediaRemoteController: MediaRemoteController,
        readinessChanged: @escaping @MainActor (Bool) -> Void,
        route: @escaping @MainActor (MediaRemoteTransportCommand, MediaCommandCenterInputMetadata) -> Void
    ) {
        self.mediaSourceStore = mediaSourceStore
        self.mediaRemoteController = mediaRemoteController
        self.readinessChanged = readinessChanged
        self.route = route
    }

    var running: Bool {
        isRunning
    }

    @discardableResult
    func start(helperGeneration: UInt) -> Bool {
        guard !isRunning else {
            return activeHelperGeneration == helperGeneration
        }
        guard mediaRemoteController.isHelperPairReady,
              mediaRemoteController.helperGeneration == helperGeneration
        else {
            return false
        }

        isRunning = true
        activeHelperGeneration = helperGeneration
        guard armRouteShield(reason: "start") else {
            stop()
            logger.error("MediaCommandCenter state=failed reason=route_shield_unavailable")
            return false
        }
        logger.info("MediaCommandCenter state=starting commands=play_pause_next_previous")
        return true
    }

    func stop() {
        guard isRunning else {
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()
        for target in commandTargets {
            commandCenter.togglePlayPauseCommand.removeTarget(target)
            commandCenter.playCommand.removeTarget(target)
            commandCenter.pauseCommand.removeTarget(target)
            commandCenter.nextTrackCommand.removeTarget(target)
            commandCenter.previousTrackCommand.removeTarget(target)
        }
        commandTargets.removeAll()
        isRunning = false
        activeHelperGeneration = nil
        routeShieldRequestSequence += 1
        routeShieldRequestInFlight = false
        acknowledgedRouteShieldPlayback = nil
        _ = mediaRemoteController.setRouteShield(info: nil) { _ in }
        disarmRouteShield(reason: "stop")
        setReady(false)
        logger.info("MediaCommandCenter state=disabled")
    }

    private func register(
        _ remoteCommand: MPRemoteCommand,
        command: MediaRemoteTransportCommand,
        helperGeneration: UInt
    ) -> Any {
        remoteCommand.isEnabled = true
        return remoteCommand.addTarget { [weak self] event in
            let metadata = MediaCommandCenterInputMetadata(eventTimestamp: event.timestamp)

            Task { @MainActor [weak self] in
                guard let self,
                      self.isReady,
                      self.activeHelperGeneration == helperGeneration,
                      self.mediaRemoteController.helperGeneration == helperGeneration
                else {
                    return
                }
                self.logger.info("MediaCommandCenter event command=\(command.rawValue, privacy: .public) timestamp=\(metadata.eventTimestamp, privacy: .public)")
                self.route(command, metadata)
                if self.routeShieldSourceNode != nil {
                    guard self.publishNowPlayingRoute(
                        isPlaying: self.mediaSourceStore.rows.contains { $0.target.isCurrentlyPlaying }
                    ) else {
                        self.routeShieldFailed(reason: "command_update")
                        return
                    }
                }
            }
            return .success
        }
    }

    @discardableResult
    func armRouteShield(reason: String) -> Bool {
        guard isRunning,
              let activeHelperGeneration,
              mediaRemoteController.isHelperPairReady,
              mediaRemoteController.helperGeneration == activeHelperGeneration
        else {
            return false
        }
        guard startRouteShieldAudio() else {
            return false
        }
        guard publishNowPlayingRoute(
            isPlaying: mediaSourceStore.rows.contains { $0.target.isCurrentlyPlaying }
        ) else {
            return false
        }
        observeRouteShieldPlaybackIfNeeded()
        logger.info("MediaCommandCenter routeShield=armed reason=\(reason, privacy: .public)")
        return true
    }

    func disarmRouteShield(reason: String) {
        routeShieldPlaybackSubscription?.cancel()
        routeShieldPlaybackSubscription = nil
        stopRouteShieldAudio()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        logger.info("MediaCommandCenter routeShield=disarmed reason=\(reason, privacy: .public)")
    }

    private func startRouteShieldAudio() -> Bool {
        guard routeShieldSourceNode == nil else {
            return true
        }

        let sourceNode = AVAudioSourceNode(renderBlock: Self.routeShieldRenderBlock)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        routeShieldEngine.attach(sourceNode)
        routeShieldEngine.connect(sourceNode, to: routeShieldEngine.mainMixerNode, format: format)
        routeShieldEngine.mainMixerNode.outputVolume = 1
        do {
            try routeShieldEngine.start()
        } catch {
            logger.error("MediaCommandCenter routeShieldAudio=failed error=\(error.localizedDescription, privacy: .public)")
            routeShieldEngine.stop()
            routeShieldEngine.detach(sourceNode)
            return false
        }
        routeShieldSourceNode = sourceNode
        return true
    }

    private func stopRouteShieldAudio() {
        routeShieldEngine.stop()
        if let routeShieldSourceNode {
            routeShieldEngine.detach(routeShieldSourceNode)
            self.routeShieldSourceNode = nil
        }
    }

    private func observeRouteShieldPlaybackIfNeeded() {
        guard routeShieldPlaybackSubscription == nil else {
            return
        }

        routeShieldPlaybackSubscription = mediaSourceStore.$rows
            .map { rows in rows.contains { $0.target.isCurrentlyPlaying } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isPlaying in
                guard let self,
                      self.publishNowPlayingRoute(isPlaying: isPlaying)
                else {
                    self?.routeShieldFailed(reason: "playback_update")
                    return
                }
            }
    }

    private func publishNowPlayingRoute(isPlaying: Bool) -> Bool {
        desiredRouteShieldPlayback = isPlaying
        let playbackRate = isPlaying ? 1.0 : 0.0
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "Keyway",
            MPMediaItemPropertyArtist: "Media key routing",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: ProcessInfo.processInfo.systemUptime,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        guard acknowledgedRouteShieldPlayback != isPlaying else {
            return true
        }
        guard !routeShieldRequestInFlight else {
            return true
        }
        guard let helperGeneration = activeHelperGeneration,
              mediaRemoteController.helperGeneration == helperGeneration
        else {
            return false
        }

        routeShieldRequestSequence += 1
        let requestSequence = routeShieldRequestSequence
        routeShieldRequestInFlight = true
        let sent = mediaRemoteController.setRouteShield(info: info) { [weak self] succeeded in
            guard let self,
                  self.isRunning,
                  self.activeHelperGeneration == helperGeneration,
                  self.mediaRemoteController.helperGeneration == helperGeneration,
                  self.routeShieldRequestSequence == requestSequence
            else {
                return
            }
            self.routeShieldRequestInFlight = false
            guard succeeded else {
                self.routeShieldFailed(reason: "helper_rejected")
                return
            }
            self.acknowledgedRouteShieldPlayback = isPlaying
            guard self.registerCommandsIfNeeded(helperGeneration: helperGeneration) else {
                self.routeShieldFailed(reason: "missing_command_target")
                return
            }
            self.setReady(true)
            self.logger.info("MediaCommandCenter state=enabled commands=play_pause_next_previous")
            if self.desiredRouteShieldPlayback != isPlaying,
               !self.publishNowPlayingRoute(isPlaying: self.desiredRouteShieldPlayback) {
                self.routeShieldFailed(reason: "playback_update")
            }
        }
        if !sent {
            routeShieldRequestInFlight = false
        }
        return sent
    }

    private func registerCommandsIfNeeded(helperGeneration: UInt) -> Bool {
        guard commandTargets.isEmpty else {
            return commandTargets.count == 5
        }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandTargets = [
            register(
                commandCenter.togglePlayPauseCommand,
                command: .playPause,
                helperGeneration: helperGeneration
            ),
            register(
                commandCenter.playCommand,
                command: .play,
                helperGeneration: helperGeneration
            ),
            register(
                commandCenter.pauseCommand,
                command: .pause,
                helperGeneration: helperGeneration
            ),
            register(
                commandCenter.nextTrackCommand,
                command: .next,
                helperGeneration: helperGeneration
            ),
            register(
                commandCenter.previousTrackCommand,
                command: .previous,
                helperGeneration: helperGeneration
            ),
        ]
        return commandTargets.count == 5
    }

    private func routeShieldFailed(reason: String) {
        guard isRunning else {
            return
        }
        logger.error("MediaCommandCenter routeShield=failed reason=\(reason, privacy: .public)")
        let stopWillNotify = isReady
        stop()
        if !stopWillNotify {
            readinessChanged(false)
        }
    }

    private func setReady(_ ready: Bool) {
        guard isReady != ready else {
            return
        }
        isReady = ready
        readinessChanged(ready)
    }

}
