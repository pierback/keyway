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
    private var routeShieldRequestGeneration = 0

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
    func start() -> Bool {
        guard !isRunning else {
            return true
        }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandTargets = [
            register(commandCenter.togglePlayPauseCommand, command: .playPause),
            register(commandCenter.playCommand, command: .play),
            register(commandCenter.pauseCommand, command: .pause),
            register(commandCenter.nextTrackCommand, command: .next),
            register(commandCenter.previousTrackCommand, command: .previous),
        ]
        guard commandTargets.count == 5 else {
            commandTargets.removeAll()
            logger.error("MediaCommandCenter state=failed reason=missing_command_target")
            return false
        }
        isRunning = true
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
        routeShieldRequestGeneration += 1
        _ = mediaRemoteController.setRouteShield(info: nil) { _ in }
        disarmRouteShield(reason: "stop")
        setReady(false)
        logger.info("MediaCommandCenter state=disabled")
    }

    private func register(
        _ remoteCommand: MPRemoteCommand,
        command: MediaRemoteTransportCommand
    ) -> Any {
        remoteCommand.isEnabled = true
        return remoteCommand.addTarget { [weak self] event in
            guard let self else {
                return .commandFailed
            }
            let metadata = MediaCommandCenterInputMetadata(eventTimestamp: event.timestamp)

            Task { @MainActor in
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
        guard isRunning else {
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
        routeShieldRequestGeneration += 1
        let generation = routeShieldRequestGeneration
        return mediaRemoteController.setRouteShield(info: info) { [weak self] succeeded in
            guard let self,
                  self.isRunning,
                  self.routeShieldRequestGeneration == generation
            else {
                return
            }
            guard succeeded else {
                self.routeShieldFailed(reason: "helper_rejected")
                return
            }
            self.setReady(true)
            self.logger.info("MediaCommandCenter state=enabled commands=play_pause_next_previous")
        }
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
