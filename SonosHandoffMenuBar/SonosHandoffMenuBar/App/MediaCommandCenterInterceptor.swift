import AVFoundation
import Combine
import Darwin
import Foundation
import MediaPlayer
import os
import SonosHandoffCore

@MainActor
final class MediaCommandCenterInterceptor {
    nonisolated private static let duplicateCallbackInterval: TimeInterval = 0.15
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
    private let route: @MainActor (MediaRemoteTransportCommand, MediaCommandCenterInputMetadata) -> Void
    private let mediaRemoteRouteShield = MediaRemotePrivateRouteShield()
    private var commandTargets: [Any] = []
    private var routeShieldPlaybackSubscription: AnyCancellable?
    private let routeShieldEngine = AVAudioEngine()
    private var routeShieldSourceNode: AVAudioSourceNode?
    private var isRunning = false
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var lastAcceptedCommand: MediaRemoteTransportCommand?
    nonisolated(unsafe) private var lastAcceptedAt: TimeInterval = 0

    init(
        mediaSourceStore: MediaSourceStore,
        route: @escaping @MainActor (MediaRemoteTransportCommand, MediaCommandCenterInputMetadata) -> Void
    ) {
        self.mediaSourceStore = mediaSourceStore
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
        armRouteShield(reason: "start")
        logger.info("MediaCommandCenter state=enabled commands=play_pause_next_previous")
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
        disarmRouteShield(reason: "stop")
        isRunning = false
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

            guard self.acceptCommandCallback(command) else {
                self.logger.info("MediaCommandCenter duplicate_ignored command=\(command.rawValue, privacy: .public)")
                return .success
            }

            Task { @MainActor in
                self.logger.info("MediaCommandCenter event command=\(command.rawValue, privacy: .public) timestamp=\(metadata.eventTimestamp, privacy: .public)")
                self.route(command, metadata)
                if self.routeShieldSourceNode != nil {
                    self.publishNowPlayingRoute(
                        isPlaying: self.mediaSourceStore.rows.contains { $0.target.isCurrentlyPlaying }
                    )
                }
            }
            return .success
        }
    }

    func armRouteShield(reason: String) {
        guard isRunning else {
            return
        }
        guard startRouteShieldAudio() else {
            return
        }
        publishNowPlayingRoute(
            isPlaying: mediaSourceStore.rows.contains { $0.target.isCurrentlyPlaying }
        )
        observeRouteShieldPlaybackIfNeeded()
        logger.info("MediaCommandCenter routeShield=armed reason=\(reason, privacy: .public)")
    }

    func disarmRouteShield(reason: String) {
        routeShieldPlaybackSubscription?.cancel()
        routeShieldPlaybackSubscription = nil
        stopRouteShieldAudio()
        mediaRemoteRouteShield.disable()
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
                self?.publishNowPlayingRoute(isPlaying: isPlaying)
            }
    }

    private func publishNowPlayingRoute(isPlaying: Bool) {
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
        mediaRemoteRouteShield.publish(info: info)
    }

    private nonisolated func acceptCommandCallback(_ command: MediaRemoteTransportCommand) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }

        if let lastAcceptedCommand,
           commandsMatch(lastAcceptedCommand, command),
           now - lastAcceptedAt < Self.duplicateCallbackInterval {
            return false
        }

        lastAcceptedCommand = command
        lastAcceptedAt = now
        return true
    }

    private nonisolated func commandsMatch(
        _ expected: MediaRemoteTransportCommand,
        _ actual: MediaRemoteTransportCommand
    ) -> Bool {
        if expected == actual {
            return true
        }

        return isPlayPauseFamily(expected) && isPlayPauseFamily(actual)
    }

    private nonisolated func isPlayPauseFamily(_ command: MediaRemoteTransportCommand) -> Bool {
        command == .playPause || command == .pause || command == .play
    }
}

private final class MediaRemotePrivateRouteShield {
    private typealias SetCanBeNowPlayingApplication = @convention(c) (Bool) -> Void
    private typealias SetNowPlayingInfo = @convention(c) (CFDictionary) -> Void
    private typealias SetNowPlayingApplicationOverrideEnabled = @convention(c) (Bool) -> Void
    private typealias SetOverriddenNowPlayingApplication = @convention(c) (CFString) -> Void

    private let bundleIdentifier = Bundle.main.bundleIdentifier! as CFString
    private let setCanBeNowPlayingApplication: SetCanBeNowPlayingApplication
    private let setNowPlayingInfo: SetNowPlayingInfo
    private let setNowPlayingApplicationOverrideEnabled: SetNowPlayingApplicationOverrideEnabled
    private let setOverriddenNowPlayingApplication: SetOverriddenNowPlayingApplication

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)!
        setCanBeNowPlayingApplication = unsafeBitCast(
            dlsym(handle, "MRMediaRemoteSetCanBeNowPlayingApplication")!,
            to: SetCanBeNowPlayingApplication.self
        )
        setNowPlayingInfo = unsafeBitCast(
            dlsym(handle, "MRMediaRemoteSetNowPlayingInfo")!,
            to: SetNowPlayingInfo.self
        )
        setNowPlayingApplicationOverrideEnabled = unsafeBitCast(
            dlsym(handle, "MRMediaRemoteSetNowPlayingApplicationOverrideEnabled")!,
            to: SetNowPlayingApplicationOverrideEnabled.self
        )
        setOverriddenNowPlayingApplication = unsafeBitCast(
            dlsym(handle, "MRMediaRemoteSetOverriddenNowPlayingApplication")!,
            to: SetOverriddenNowPlayingApplication.self
        )
    }

    func publish(info: [String: Any]) {
        setCanBeNowPlayingApplication(true)
        setOverriddenNowPlayingApplication(bundleIdentifier)
        setNowPlayingApplicationOverrideEnabled(true)
        setNowPlayingInfo(info as CFDictionary)
    }

    func disable() {
        setNowPlayingApplicationOverrideEnabled(false)
        setCanBeNowPlayingApplication(false)
    }
}
