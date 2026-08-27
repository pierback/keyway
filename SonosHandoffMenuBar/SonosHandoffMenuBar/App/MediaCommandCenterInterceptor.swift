import AVFoundation
import Darwin
import Foundation
import MediaPlayer
import os
import SonosHandoffCore

@MainActor
final class MediaCommandCenterInterceptor {
    private typealias AsyncCommandCompletion = @convention(block) (CFArray?) -> Void
    private typealias AsyncCommandHandler = @convention(block) (
        UInt32,
        CFDictionary?,
        @escaping AsyncCommandCompletion
    ) -> Void
    private typealias AddAsyncCommandHandler = @convention(c) (
        @escaping AsyncCommandHandler
    ) -> UnsafeMutableRawPointer?
    private typealias RemoveCommandHandler = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetCanBeNowPlayingApplication = @convention(c) (UInt8) -> UInt8
    private typealias GetLocalOrigin = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CommandInfoCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CommandInfoSetCommand = @convention(c) (CFTypeRef?, UInt32) -> Void
    private typealias CommandInfoSetEnabled = @convention(c) (CFTypeRef?, UInt8) -> Void
    private typealias SupportedCommandsCompletion = @convention(block) (UInt32) -> Void
    private typealias SetSupportedCommands = @convention(c) (
        CFArray,
        UnsafeMutableRawPointer?,
        DispatchQueue?,
        SupportedCommandsCompletion?
    ) -> Void
    private typealias SetNowPlayingVisibility = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Void
    private typealias SetNowPlayingApplicationOverrideEnabled = @convention(c) (UInt8) -> Void
    private typealias SetOverriddenNowPlayingApplication = @convention(c) (CFString) -> Void

    private static let commandHandlerSuccess: UInt32 = 0
    private static let commandHandlerFailed: UInt32 = 2
    private static let neverVisible: UInt32 = 3
    private static let mediaRemoteHandle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_NOW
    )!
    private static let getLocalOrigin = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteGetLocalOrigin")!,
        to: GetLocalOrigin.self
    )
    private static let addAsyncCommandHandler = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteAddAsyncCommandHandlerBlock")!,
        to: AddAsyncCommandHandler.self
    )
    private static let removeCommandHandler = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteRemoveCommandHandlerBlock")!,
        to: RemoveCommandHandler.self
    )
    private static let setCanBeNowPlayingApplication = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteSetCanBeNowPlayingApplication")!,
        to: SetCanBeNowPlayingApplication.self
    )
    private static let commandInfoCreate = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteCommandInfoCreate")!,
        to: CommandInfoCreate.self
    )
    private static let commandInfoSetCommand = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteCommandInfoSetCommand")!,
        to: CommandInfoSetCommand.self
    )
    private static let commandInfoSetEnabled = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteCommandInfoSetEnabled")!,
        to: CommandInfoSetEnabled.self
    )
    private static let setSupportedCommands = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteSetSupportedCommands")!,
        to: SetSupportedCommands.self
    )
    private static let setNowPlayingVisibility = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteSetNowPlayingVisibility")!,
        to: SetNowPlayingVisibility.self
    )
    private static let setNowPlayingApplicationOverrideEnabled = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteSetNowPlayingApplicationOverrideEnabled")!,
        to: SetNowPlayingApplicationOverrideEnabled.self
    )
    private static let setOverriddenNowPlayingApplication = unsafeBitCast(
        dlsym(mediaRemoteHandle, "MRMediaRemoteSetOverriddenNowPlayingApplication")!,
        to: SetOverriddenNowPlayingApplication.self
    )
    nonisolated(unsafe) private static let silentRenderBlock: AVAudioSourceNodeRenderBlock = {
        _, _, _, audioBufferList in
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaCommandCenter")
    private let route: @MainActor (MediaRemoteTransportCommand, MediaCommandCenterInputMetadata) -> Void
    private let audioEngine = AVAudioEngine()
    private var audioSourceNode: AVAudioSourceNode?
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    private var commandHandler: UnsafeMutableRawPointer?
    private var commandHandlerBlock: AsyncCommandHandler?
    private var isPlaying = false
    private(set) var running = false

    init(
        route: @escaping @MainActor (MediaRemoteTransportCommand, MediaCommandCenterInputMetadata) -> Void
    ) {
        self.route = route
    }

    func start() {
        guard !running else {
            return
        }

        let sourceNode = AVAudioSourceNode(renderBlock: Self.silentRenderBlock)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0
        try! audioEngine.start()
        audioSourceNode = sourceNode

        precondition(Self.setCanBeNowPlayingApplication(1) != 0)
        registerCommandHandler()
        publishSupportedCommands()
        running = true
        audioEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioEngineConfigurationChanged()
            }
        }
        publishHiddenSession()
        logger.info("MediaCommandCenter state=enabled receiver=media_remote visibility=never_visible")
    }

    func updatePlaybackState(isPlaying: Bool) {
        guard self.isPlaying != isPlaying else {
            return
        }
        self.isPlaying = isPlaying
        if running {
            publishHiddenSession()
        }
    }

    func stop() {
        guard running else {
            return
        }

        running = false
        Self.setNowPlayingApplicationOverrideEnabled(0)
        if let audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
            self.audioEngineConfigurationObserver = nil
        }
        Self.removeCommandHandler(commandHandler)
        commandHandler = nil
        commandHandlerBlock = nil
        Self.setSupportedCommands([] as CFArray, Self.getLocalOrigin(), nil, nil)
        _ = Self.setCanBeNowPlayingApplication(0)

        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState = .stopped
        Self.setNowPlayingVisibility(Self.getLocalOrigin(), 0)

        audioEngine.stop()
        if let audioSourceNode {
            audioEngine.detach(audioSourceNode)
            self.audioSourceNode = nil
        }
        logger.info("MediaCommandCenter state=disabled")
    }

    private func registerCommandHandler() {
        let block: AsyncCommandHandler = { [weak self] rawCommand, _, completion in
            guard let command = Self.transportCommand(rawCommand) else {
                completion([NSNumber(value: Self.commandHandlerFailed)] as CFArray)
                return
            }
            completion([NSNumber(value: Self.commandHandlerSuccess)] as CFArray)
            let metadata = MediaCommandCenterInputMetadata(
                eventTimestamp: ProcessInfo.processInfo.systemUptime
            )
            Task { @MainActor [weak self] in
                guard let self, self.running else {
                    return
                }
                self.logger.info("MediaCommandCenter event command=\(command.rawValue, privacy: .public) timestamp=\(metadata.eventTimestamp, privacy: .public)")
                self.route(command, metadata)
                self.publishHiddenSession()
            }
        }
        commandHandlerBlock = block
        commandHandler = Self.addAsyncCommandHandler(block)
        precondition(commandHandler != nil)
    }

    private func publishSupportedCommands() {
        let commands = NSMutableArray()
        for rawCommand in [UInt32(0), 1, 2, 4, 5] {
            let commandInfo = Self.commandInfoCreate(kCFAllocatorDefault)!.takeRetainedValue()
            Self.commandInfoSetCommand(commandInfo, rawCommand)
            Self.commandInfoSetEnabled(commandInfo, 1)
            commands.add(commandInfo)
        }
        Self.setSupportedCommands(commands, Self.getLocalOrigin(), nil, nil)
    }

    nonisolated private static func transportCommand(
        _ rawCommand: UInt32
    ) -> MediaRemoteTransportCommand? {
        switch rawCommand {
        case 0:
            return .play
        case 1:
            return .pause
        case 2:
            return .playPause
        case 4:
            return .next
        case 5:
            return .previous
        default:
            return nil
        }
    }

    private func audioEngineConfigurationChanged() {
        guard running else {
            return
        }
        if !audioEngine.isRunning {
            try! audioEngine.start()
        }
        publishHiddenSession()
        logger.info("MediaCommandCenter state=rearmed reason=audio_configuration_changed")
    }

    private func publishHiddenSession() {
        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = [
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        nowPlaying.playbackState = isPlaying ? .playing : .paused
        Self.setOverriddenNowPlayingApplication(AppIdentity.bundleIdentifier as CFString)
        Self.setNowPlayingApplicationOverrideEnabled(1)
        Self.setNowPlayingVisibility(Self.getLocalOrigin(), Self.neverVisible)
    }
}
