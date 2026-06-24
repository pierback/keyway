import Foundation
import os
import SonosHandoffCore

@MainActor
final class MediaTransportActionController {
    private static let commandCenterMediaKeyShadowInterval: TimeInterval = 0.25
    private static let commandCenterInputShadowInterval: TimeInterval = 0.15
    private static let programmaticCommandCenterEchoWindow: TimeInterval = 1.25
    private static let programmaticGeneratedMediaKeyCallbackWindow: TimeInterval = 0.25
    private static let physicalMediaKeyReboundWindow: TimeInterval = 0.25
    private static let chooserTargetedMediaKeyEchoWindow: TimeInterval = 1.25
    private static let programmaticDispatchFallbackDelayNanoseconds: UInt64 = 250_000_000
    private static let selectedRowDispatchRouteShieldReleaseDelayNanoseconds: UInt64 = 180_000_000

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaTransport")
    private let mediaRemoteController: MediaRemoteController
    private let overlayController: MediaTargetOverlayController
    private let commandCenterFilter: MediaTransportCommandCenterFilter
    private let desktopTransport = MediaDesktopTransportAdapter()
    private let spotifyPlaybackController: any SpotifyActivePlaybackObserving
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let sourceFocusActionController: SourceFocusActionController
    private let targetSelectionMemory: MediaTargetSelectionMemory
    private let traceRecorder = MediaTransportTraceRecorder()
    private let chooserSession = MediaChooserSessionGuard()
    private let targetResolver = MediaTransportTargetResolver()
    var relaxRouteShield: ((String) -> Void)?
    private var programmaticDispatches: [UUID: MediaTransportPendingDispatchEcho] = [:]

    init(
        mediaRemoteController: MediaRemoteController,
        overlayController: MediaTargetOverlayController,
        spotifyPlaybackController: any SpotifyActivePlaybackObserving,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController = ChromiumBrowserExtensionController(),
        sourceFocusActionController: SourceFocusActionController,
        targetSelectionMemory: MediaTargetSelectionMemory
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.overlayController = overlayController
        self.spotifyPlaybackController = spotifyPlaybackController
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.sourceFocusActionController = sourceFocusActionController
        self.targetSelectionMemory = targetSelectionMemory
        self.commandCenterFilter = MediaTransportCommandCenterFilter(
            mediaKeyShadowInterval: Self.commandCenterMediaKeyShadowInterval,
            commandCenterInputShadowInterval: Self.commandCenterInputShadowInterval,
            programmaticCommandCenterEchoWindow: Self.programmaticCommandCenterEchoWindow,
            programmaticGeneratedMediaKeyCallbackWindow: Self.programmaticGeneratedMediaKeyCallbackWindow,
            physicalMediaKeyReboundWindow: Self.physicalMediaKeyReboundWindow,
            chooserTargetedMediaKeyEchoWindow: Self.chooserTargetedMediaKeyEchoWindow
        )
    }

    func route(command: MediaRemoteTransportCommand) {
        route(command: command, source: .userInterface)
    }

    func routeFromMediaKey(command: MediaRemoteTransportCommand, metadata: MediaTransportInputMetadata? = nil) {
        route(command: command, source: .eventTap, metadata: metadata)
    }

    func noteGeneratedMediaKeyIgnored(command: MediaRemoteTransportCommand, metadata: MediaTransportInputMetadata) {
        commandCenterFilter.noteMediaKey(command: command, metadata: metadata)
        trace(
            "generated_media_key_shadow_armed",
            command: command,
            source: .eventTap,
            metadata: metadata
        )
    }

    func routeFromCommandCenter(
        command: MediaRemoteTransportCommand,
        metadata: MediaCommandCenterInputMetadata? = nil
    ) {
        route(command: command, source: .commandCenter, commandCenterMetadata: metadata)
    }

    private func route(
        command: MediaRemoteTransportCommand,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata? = nil,
        commandCenterMetadata: MediaCommandCenterInputMetadata? = nil
    ) {
        logger.info("MediaTransport input command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) overlayVisible=\(self.overlayController.isVisible, privacy: .public) chooserActive=\(self.chooserSession.isActive, privacy: .public) canRoute=\(self.mediaRemoteController.canRouteCommands, privacy: .public) targetCount=\(self.mediaRemoteController.targets.count, privacy: .public)")
        trace(
            "input",
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
        switch source {
        case .eventTap:
            if let reason = commandCenterFilter.ignoreReasonForMediaKey(command: command, metadata: metadata) {
                logger.info("MediaTransport \(reason.rawValue, privacy: .public) command=\(command.rawValue, privacy: .public)")
                trace(
                    "input_ignored",
                    command: command,
                    source: source,
                    reason: reason.rawValue,
                    metadata: metadata
                )
                return
            }
            commandCenterFilter.noteMediaKey(command: command, metadata: metadata)
        case .commandCenter:
            if let reason = commandCenterFilter.ignoreReasonForCommandCenter(command: command, metadata: commandCenterMetadata) {
                logger.info("MediaTransport \(reason.rawValue, privacy: .public) command=\(command.rawValue, privacy: .public)")
                trace(
                    "input_ignored",
                    command: command,
                    source: source,
                    reason: reason.rawValue,
                    commandCenterMetadata: commandCenterMetadata
                )
                return
            }
            commandCenterFilter.noteCommandCenterInput(command: command, metadata: commandCenterMetadata)
        case .userInterface:
            break
        }

        if MediaTransportCommandRules.isPlayFamily(command) {
            if shouldRoutePlayFamilyWithoutChooser(source: source, metadata: metadata) {
                routePlayFamilyWithoutChooser(
                    command: command,
                    source: source,
                    metadata: metadata,
                    commandCenterMetadata: commandCenterMetadata
                )
                return
            }
            logger.info("MediaTransport decision=chooser command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")
            trace(
                "decision_chooser",
                command: command,
                source: source,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            showChooserImmediately(
                command: command,
                source: source,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            return
        }
        logger.info("MediaTransport decision=cache_route command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")
        trace(
            "decision_cache_route",
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
        routeFromCache(
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func shouldRoutePlayFamilyWithoutChooser(
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?
    ) -> Bool {
        guard source == .eventTap,
              let metadata,
              metadata.isPhysicalHIDSystemSource
        else {
            return false
        }
        return !metadata.isUntargetedPhysicalHIDSystemSource
    }

    func showChooser(command: MediaRemoteTransportCommand = .playPause) {
        showChooserFromCache(command: command)
    }

    func showTargetChooser() {
        showChooserFromCache(command: nil)
    }

    func route(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget) {
        send(command: command, to: target, reason: .current)
    }

    func focus(target: MediaRemoteTarget) {
        sourceFocusActionController.focus(target: target)
    }

    func currentRouteStatus() -> MediaRouteStatus {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty else {
            return MediaRouteStatus(kind: .unavailable, target: nil, targetCount: 0)
        }

        if let decision = targetResolver.automaticTarget(
            command: .playPause,
            from: targets,
            recentTargetID: targetSelectionMemory.recentTargetID
        ) {
            let kind: MediaRouteStatusKind = targets.count > 1
                ? .chooser
                : MediaTransportCommandRules.statusKind(for: decision.reason)

            return MediaRouteStatus(
                kind: kind,
                target: decision.target,
                targetCount: targets.count
            )
        }

        return MediaRouteStatus(
            kind: .chooser,
            target: mediaRemoteController.activeTarget ?? targets.first,
            targetCount: targets.count
        )
    }

    private func showChooserFromCache(command: MediaRemoteTransportCommand?) {
        showChooserImmediately(command: command, source: .userInterface)
    }

    private func showChooserImmediately(
        command: MediaRemoteTransportCommand?,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata? = nil,
        commandCenterMetadata: MediaCommandCenterInputMetadata? = nil
    ) {
        let commandName = command?.rawValue ?? "none"
        if overlayController.isVisible || chooserSession.isActive {
            let chooserState = chooserSession.stateName
            logger.info("MediaTransport chooser_reentry_ignored command=\(commandName, privacy: .public) source=\(source.rawValue, privacy: .public) state=\(chooserState, privacy: .public)")
            trace(
                "chooser_reentry_ignored",
                command: command,
                source: source,
                reason: chooserState,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            return
        }
        let cached = sortedTargets(mediaRemoteController.targets)
        let refreshQueued = mediaRemoteController.refreshSnapshot()

        logger.info("MediaTransport chooser_show command=\(commandName, privacy: .public) source=\(source.rawValue, privacy: .public) targetCount=\(cached.count, privacy: .public) refreshQueued=\(refreshQueued, privacy: .public) targets=\(MediaTransportCommandRules.targetLogSummary(cached), privacy: .public)")
        trace(
            "chooser_show",
            command: command,
            source: source,
            targets: cached,
            targetCount: cached.count,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
        showChooserOverlay(
            command: command,
            targets: cached,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func routeFromCache(
        command: MediaRemoteTransportCommand,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty else {
            mediaRemoteController.refreshSnapshot()
            StatusHUD.shared.finish(
                title: "No Media Target",
                message: "Start Spotify, a browser video, or QuickTime playback.",
                dismissAfter: 2.4
            )
            return
        }

        mediaRemoteController.refreshSnapshot()
        route(
            command: command,
            targets: targets,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func routePlayFamilyWithoutChooser(
        command: MediaRemoteTransportCommand,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty else {
            mediaRemoteController.refreshSnapshot()
            logger.info("MediaTransport play_family_no_chooser_no_target command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")
            trace(
                "play_family_no_chooser_no_target",
                command: command,
                source: source,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            return
        }

        mediaRemoteController.refreshSnapshot()
        if let metadata,
           let target = targetResolver.targetedInputTarget(
               targetUnixProcessID: metadata.targetUnixProcessID,
               from: targets
           ) {
            logger.info("MediaTransport decision=targeted_no_chooser command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public)")
            trace(
                "decision_targeted_no_chooser",
                command: command,
                source: source,
                target: target,
                targetCount: targets.count,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            send(command: command, to: target, reason: .current)
            return
        }

        if let metadata,
           metadata.targetUnixProcessID > 0 {
            logger.info("MediaTransport play_family_targeted_route_unresolved command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) targetPID=\(metadata.targetUnixProcessID, privacy: .public) targetCount=\(targets.count, privacy: .public)")
            trace(
                "play_family_targeted_route_unresolved",
                command: command,
                source: source,
                targets: targets,
                targetCount: targets.count,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            showChooserImmediately(
                command: command,
                source: source,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            return
        }

        if let decision = targetResolver.automaticTarget(
            command: command,
            from: targets,
            recentTargetID: targetSelectionMemory.recentTargetID
        ) {
            logger.info("MediaTransport decision=automatic_no_chooser command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) target=\(decision.target.appName, privacy: .public) targetID=\(decision.target.id, privacy: .public) reason=\(decision.reason.rawValue, privacy: .public)")
            trace(
                "decision_automatic_no_chooser",
                command: command,
                source: source,
                target: decision.target,
                reason: decision.reason.rawValue,
                targetCount: targets.count,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
            )
            send(command: command, to: decision.target, reason: decision.reason)
            return
        }

        logger.info("MediaTransport play_family_direct_route_ambiguous command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) targetCount=\(targets.count, privacy: .public)")
        trace(
            "play_family_direct_route_ambiguous",
            command: command,
            source: source,
            targets: targets,
            targetCount: targets.count,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
        showChooserImmediately(
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func route(
        command: MediaRemoteTransportCommand,
        targets: [MediaRemoteTarget],
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) {
        if let decision = targetResolver.automaticTarget(
            command: command,
            from: targets,
            recentTargetID: targetSelectionMemory.recentTargetID
        ) {
            send(command: command, to: decision.target, reason: decision.reason)
            return
        }

        showChooserOverlay(
            command: command,
            targets: targets,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func showChooserOverlay(
        command: MediaRemoteTransportCommand?,
        targets: [MediaRemoteTarget],
        source: MediaTransportRouteSource = .userInterface,
        metadata: MediaTransportInputMetadata? = nil,
        commandCenterMetadata: MediaCommandCenterInputMetadata? = nil
    ) {
        let chooserID = chooserSession.begin(command: command)

        overlayController.show(
            command: command,
            targets: targets,
            onChoose: { [weak self] target, command in
                guard let self else { return }
                self.logger.info("MediaTransport chooser_select requestedCommand=\(command?.rawValue ?? "none", privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) playing=\(target.isCurrentlyPlaying, privacy: .public)")
                self.trace(
                    "chooser_select",
                    command: command,
                    target: target,
                    targetCount: self.mediaRemoteController.targets.count
                )

                guard let command else {
                    self.finishChooser(id: chooserID)
                    self.trace(
                        "chooser_closed_without_command",
                        command: nil,
                        target: target,
                        targetCount: self.mediaRemoteController.targets.count
                    )
                    self.mediaRemoteController.refreshSnapshot()
                    StatusHUD.shared.finish(
                        title: "\(target.appName)",
                        message: "No transport command was pending.",
                        dismissAfter: 1.35
                    )
                    return
                }

                let routedCommand = self.chooserScopedCommand(command, for: target)
                self.finishChooser(
                    id: chooserID,
                    selected: true
                )
                self.trace(
                    "chooser_closed_for_dispatch",
                    command: command,
                    target: target,
                    targetCount: self.mediaRemoteController.targets.count
                )
                if let desktopTransport = self.desktopTransportName(target: target) {
                    self.trace(
                        "selected_row_dispatch_route_shield_kept",
                        command: command,
                        target: target,
                        reason: desktopTransport,
                        transportBackend: desktopTransport
                    )
                } else {
                    self.relaxRouteShield?("selected_row_dispatch")
                }
                Task { @MainActor [weak self] in
                    try! await Task.sleep(nanoseconds: Self.selectedRowDispatchRouteShieldReleaseDelayNanoseconds)
                    self?.dispatchFromChooser(
                        command: routedCommand,
                        requestedCommand: command,
                        to: target,
                        metadata: metadata
                    )
                }
            },
            onFocus: { [weak self] target in
                guard let self else { return }
                self.logger.info("MediaTransport chooser_focus target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public)")
                self.finishChooser(
                    id: chooserID,
                    selected: true
                )
                self.trace(
                    "chooser_closed_for_focus",
                    command: command,
                    target: target,
                    targetCount: self.mediaRemoteController.targets.count
                )
                self.relaxRouteShield?("chooser_focus")
                self.sourceFocusActionController.focus(target: target)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                let activeCommand = self.chooserSession.activeCommandRawValue(for: chooserID) ?? "stale"
                self.logger.info("MediaTransport chooser_dismissed command=\(activeCommand, privacy: .public)")
                self.trace("chooser_dismissed", command: self.chooserSession.activeCommand(for: chooserID))
                self.finishChooser(id: chooserID)
                self.relaxRouteShield?("chooser_dismissed")
            }
        )
    }

    private func sortedTargets(_ targets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        targetResolver.sortedTargets(
            targets,
            preferredTargetID: targetSelectionMemory.recentTargetID
        )
    }

    private func rememberTarget(_ target: MediaRemoteTarget) {
        targetSelectionMemory.remember(target)
    }

    private func send(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget, reason: MediaTransportRoutingReason) {
        logger.info("MediaTransport dispatch command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        rememberTarget(target)
        let dispatchID = beginBoundedProgrammaticDispatch(command: command)
        if let result = desktopTransport.submit(command: command, target: target) {
            trace(result: result, transportBackend: result.backend)
            if shouldFallbackFromUnsupportedDesktopResult(target: target),
               result.unsupported,
               sendProgrammaticSpotifyWebAPI(command: command, to: target, dispatchID: dispatchID, reason: reason) {
                trace(
                    "desktop_transport_fallback",
                    command: command,
                    target: target,
                    reason: "unsupported",
                    transportBackend: result.backend
                )
                return
            }
            if shouldFallbackFromUnsupportedDesktopResult(target: target),
               result.unsupported,
               sendProgrammaticMediaRemote(command: command, to: target, dispatchID: dispatchID, reason: reason) {
                trace(
                    "desktop_transport_fallback",
                    command: command,
                    target: target,
                    reason: "unsupported",
                    transportBackend: result.backend
                )
                return
            }
            finishProgrammaticDispatch(
                id: dispatchID,
                fallback: false
            )
            mediaRemoteController.refreshSnapshot()
            showCommandFailureIfNeeded(result: result, target: target)
            logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=\(result.backend ?? "desktop", privacy: .public)")
            return
        }
        if let sent = chromiumBrowserExtensionController.submit(command: command, target: target, onResult: { [weak self] result in
            guard let self else { return }
            self.trace(result: result, transportBackend: result.backend)
            self.finishProgrammaticDispatch(
                id: dispatchID,
                fallback: false
            )
            self.showCommandFailureIfNeeded(result: result, target: target)
        }) {
            guard sent else {
                finishProgrammaticDispatch(id: dispatchID, fallback: true)
                StatusHUD.shared.finish(
                    title: "Media Command Failed",
                    message: "Keyway could not reach \(target.appName).",
                    dismissAfter: 2.2
                )
                return
            }
            logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=chromium_extension")
            return
        }
        fallbackProgrammaticMediaRemote(command: command, to: target, dispatchID: dispatchID, reason: reason)
    }

    private func fallbackProgrammaticMediaRemote(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID,
        reason: MediaTransportRoutingReason
    ) {
        guard canUseMediaRemotePlayerPath(command: command, target: target) else {
            finishProgrammaticDispatch(id: dispatchID, fallback: true)
            return
        }
        guard sendProgrammaticMediaRemote(command: command, to: target, dispatchID: dispatchID, reason: reason) else {
            finishProgrammaticDispatch(id: dispatchID, fallback: true)
            logger.error("MediaTransport route_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
            return
        }

    }

    private func sendProgrammaticSpotifyWebAPI(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID,
        reason: MediaTransportRoutingReason
    ) -> Bool {
        guard let spotifyCommand = spotifyPlaybackCommand(command: command, target: target) else {
            return false
        }
        Task { @MainActor [weak self, spotifyPlaybackController] in
            guard let self else { return }
            do {
                try await spotifyPlaybackController.sendActivePlaybackCommand(spotifyCommand)
                let result = Self.spotifyWebAPIResult(
                    command: command,
                    target: target,
                    ok: true,
                    message: "submitted Spotify Web API \(spotifyCommand.rawValue)"
                )
                self.trace(result: result, transportBackend: Self.spotifyWebAPIBackend)
                self.finishProgrammaticDispatch(
                    id: dispatchID,
                    fallback: false
                )
                self.mediaRemoteController.refreshSnapshot()
            } catch {
                let result = Self.spotifyWebAPIResult(
                    command: command,
                    target: target,
                    ok: false,
                    message: error.localizedDescription
                )
                self.trace(result: result, transportBackend: Self.spotifyWebAPIBackend)
                if self.sendProgrammaticMediaRemote(command: command, to: target, dispatchID: dispatchID, reason: reason) {
                    self.trace(
                        "spotify_webapi_fallback",
                        command: command,
                        target: target,
                        reason: "failed",
                        transportBackend: Self.spotifyWebAPIBackend
                    )
                    return
                }
                self.finishProgrammaticDispatch(
                    id: dispatchID,
                    fallback: false
                )
                self.showCommandFailureIfNeeded(result: result, target: target)
            }
        }
        logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=\(Self.spotifyWebAPIBackend, privacy: .public)")
        return true
    }

    private func sendProgrammaticMediaRemote(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID,
        reason: MediaTransportRoutingReason
    ) -> Bool {
        guard canUseMediaRemotePlayerPath(command: command, target: target) else {
            return false
        }

        let sent = mediaRemoteController.submit(command: command, targetID: target.id) { [weak self] result in
            self?.trace(result: result, transportBackend: Self.mediaRemotePlayerPathBackend)
            self?.finishProgrammaticDispatch(
                id: dispatchID,
                fallback: false
            )
            self?.showCommandFailureIfNeeded(result: result, target: target)
        }
        if sent {
            logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=\(Self.mediaRemotePlayerPathBackend, privacy: .public)")
        }
        return sent
    }

    private func dispatchFromChooser(
        command: MediaRemoteTransportCommand,
        requestedCommand: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        metadata: MediaTransportInputMetadata?
    ) {
        logger.info("MediaTransport chooser_dispatch requestedCommand=\(requestedCommand.rawValue, privacy: .public) routedCommand=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) playing=\(target.isCurrentlyPlaying, privacy: .public)")
        rememberTarget(target)
        let transportBackend = transportBackendName(command: command, target: target)
        trace("chooser_dispatch", command: command, target: target, transportBackend: transportBackend)
        let dispatchID = beginBoundedChooserDispatch(
            command: command,
            metadata: metadata,
            targetUnixProcessID: Int64(target.pid),
            applicationUnixProcessID: Int64(ProcessInfo.processInfo.processIdentifier)
        )
        sendFromChooser(command: command, to: target, dispatchID: dispatchID)
    }

    private func finishChooser(
        id: UUID,
        selected: Bool = false
    ) {
        chooserSession.finish(
            id: id,
            selected: selected
        )
    }

    private func sendFromChooser(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID
    ) {
        if let result = desktopTransport.submit(command: command, target: target) {
            trace(result: result, transportBackend: result.backend)
            if shouldFallbackFromUnsupportedDesktopResult(target: target),
               result.unsupported,
               sendChooserSpotifyWebAPI(command: command, to: target, dispatchID: dispatchID) {
                trace(
                    "desktop_transport_fallback",
                    command: command,
                    target: target,
                    reason: "unsupported",
                    transportBackend: result.backend
                )
                return
            }
            if shouldFallbackFromUnsupportedDesktopResult(target: target),
               result.unsupported,
               sendChooserMediaRemote(command: command, to: target, dispatchID: dispatchID) {
                trace(
                    "desktop_transport_fallback",
                    command: command,
                    target: target,
                    reason: "unsupported",
                    transportBackend: result.backend
                )
                return
            }
            finishChooserDispatch(
                id: dispatchID,
                fallback: false
            )
            mediaRemoteController.refreshSnapshot()
            showCommandFailureIfNeeded(result: result, target: target)
            logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=\(result.backend ?? "desktop", privacy: .public)")
            return
        }
        if let sent = chromiumBrowserExtensionController.submit(command: command, target: target, onResult: { [weak self] result in
            guard let self else { return }
            self.trace(result: result, transportBackend: result.backend)
            self.finishChooserDispatch(
                id: dispatchID,
                fallback: false
            )
            self.showCommandFailureIfNeeded(result: result, target: target)
        }) {
            guard sent else {
                finishChooserDispatch(id: dispatchID, fallback: true)
                StatusHUD.shared.finish(
                    title: "Media Command Failed",
                    message: "Keyway could not reach \(target.appName).",
                    dismissAfter: 2.2
                )
                return
            }
            logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=chromium_extension")
            return
        }
        fallbackChooserMediaRemote(command: command, to: target, dispatchID: dispatchID)
    }

    private func fallbackChooserMediaRemote(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID
    ) {
        guard canUseMediaRemotePlayerPath(command: command, target: target) else {
            finishChooserDispatch(id: dispatchID, fallback: true)
            return
        }
        guard sendChooserMediaRemote(command: command, to: target, dispatchID: dispatchID) else {
            finishChooserDispatch(id: dispatchID, fallback: true)
            logger.error("MediaTransport chooser_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
            return
        }

    }

    private func sendChooserSpotifyWebAPI(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID
    ) -> Bool {
        guard let spotifyCommand = spotifyPlaybackCommand(command: command, target: target) else {
            return false
        }
        Task { @MainActor [weak self, spotifyPlaybackController] in
            guard let self else { return }
            do {
                try await spotifyPlaybackController.sendActivePlaybackCommand(spotifyCommand)
                let result = Self.spotifyWebAPIResult(
                    command: command,
                    target: target,
                    ok: true,
                    message: "submitted Spotify Web API \(spotifyCommand.rawValue)"
                )
                self.trace(result: result, transportBackend: Self.spotifyWebAPIBackend)
                self.finishChooserDispatch(
                    id: dispatchID,
                    fallback: false
                )
                self.mediaRemoteController.refreshSnapshot()
            } catch {
                let result = Self.spotifyWebAPIResult(
                    command: command,
                    target: target,
                    ok: false,
                    message: error.localizedDescription
                )
                self.trace(result: result, transportBackend: Self.spotifyWebAPIBackend)
                if self.sendChooserMediaRemote(command: command, to: target, dispatchID: dispatchID) {
                    self.trace(
                        "spotify_webapi_fallback",
                        command: command,
                        target: target,
                        reason: "failed",
                        transportBackend: Self.spotifyWebAPIBackend
                    )
                    return
                }
                self.finishChooserDispatch(
                    id: dispatchID,
                    fallback: false
                )
                self.showCommandFailureIfNeeded(result: result, target: target)
            }
        }
        logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=\(Self.spotifyWebAPIBackend, privacy: .public)")
        return true
    }

    private func sendChooserMediaRemote(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID
    ) -> Bool {
        guard canUseMediaRemotePlayerPath(command: command, target: target) else {
            return false
        }

        let sent = mediaRemoteController.submit(command: command, targetID: target.id) { [weak self] result in
            self?.trace(result: result, transportBackend: Self.mediaRemotePlayerPathBackend)
            self?.finishChooserDispatch(
                id: dispatchID,
                fallback: false
            )
            self?.showCommandFailureIfNeeded(result: result, target: target)
        }
        if sent {
            logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=\(Self.mediaRemotePlayerPathBackend, privacy: .public)")
        }
        return sent
    }

    private func canUseMediaRemotePlayerPath(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> Bool {
        if ChromiumBrowserExtensionTransport.isTarget(target) {
            return true
        }
        if desktopTransport.backendName(for: target) != nil {
            return true
        }
        if target.isChromiumBrowserLike {
            trace(
                "browser_legacy_mediaremote_blocked",
                command: command,
                target: target,
                reason: "requires_browser_extension",
                transportBackend: Self.mediaRemotePlayerPathBackend
            )
            StatusHUD.shared.finish(
                title: "Browser Extension Required",
                message: "Install and enable the Keyway browser extension in \(target.appName), then retry.",
                dismissAfter: 2.8
            )
            return false
        }
        return true
    }

    private func shouldFallbackFromUnsupportedDesktopResult(target: MediaRemoteTarget) -> Bool {
        !target.isChromiumBrowserLike
    }

    private func chooserScopedCommand(
        _ command: MediaRemoteTransportCommand,
        for target: MediaRemoteTarget
    ) -> MediaRemoteTransportCommand {
        guard command == .playPause else {
            return MediaTransportCommandRules.rowScopedCommand(command, for: target)
        }
        if desktopTransport.keepsPlayPauseToggle(for: target) {
            return .playPause
        }
        return MediaTransportCommandRules.rowScopedCommand(command, for: target)
    }

    private static let mediaRemotePlayerPathBackend = "mediaremote_player_path"
    private static let spotifyWebAPIBackend = "spotify_web_api"

    private func transportBackendName(command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> String {
        desktopTransport.backendName(command: command, target: target)
            ?? chromiumBrowserExtensionController.backendName(command: command, target: target)
            ?? Self.mediaRemotePlayerPathBackend
    }

    private func spotifyPlaybackCommand(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> SpotifyPlaybackCommand? {
        guard target.isSpotify else {
            return nil
        }
        switch command {
        case .play:
            return .play
        case .pause:
            return .pause
        case .playPause:
            return .playPause
        case .next:
            return .next
        case .previous:
            return .previous
        }
    }

    private static func spotifyWebAPIResult(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        ok: Bool,
        message: String
    ) -> MediaRemoteCommandResultEvent {
        MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: ok,
            message: message,
            backend: Self.spotifyWebAPIBackend
        )
    }

    private func desktopTransportName(target: MediaRemoteTarget) -> String? {
        desktopTransport.backendName(for: target)
            ?? chromiumBrowserExtensionController.backendName(for: target)
    }

    private func beginBoundedProgrammaticDispatch(command: MediaRemoteTransportCommand) -> UUID {
        let id = UUID()
        programmaticDispatches[id] = MediaTransportPendingDispatchEcho(command: command, kind: .automatic)
        commandCenterFilter.beginProgrammaticDispatch(command: command)
        scheduleProgrammaticDispatchFallback(id: id)
        return id
    }

    private func beginBoundedChooserDispatch(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata?,
        targetUnixProcessID: Int64,
        applicationUnixProcessID: Int64
    ) -> UUID {
        let id = UUID()
        programmaticDispatches[id] = MediaTransportPendingDispatchEcho(command: command, kind: .chooser)
        commandCenterFilter.beginChooserDispatch(
            command: command,
            metadata: metadata,
            targetUnixProcessID: targetUnixProcessID,
            applicationUnixProcessID: applicationUnixProcessID
        )
        scheduleProgrammaticDispatchFallback(id: id)
        return id
    }

    private func finishProgrammaticDispatch(id: UUID, fallback: Bool) {
        guard let pending = programmaticDispatches.removeValue(forKey: id) else {
            return
        }
        let command = pending.command
        logger.info("MediaTransport programmatic_echo_window_closed command=\(command.rawValue, privacy: .public) fallback=\(fallback, privacy: .public)")
        trace("programmatic_echo_window_closed", command: command, reason: fallback ? "fallback" : "helper")
    }

    private func finishChooserDispatch(id: UUID, fallback: Bool) {
        guard let pending = programmaticDispatches.removeValue(forKey: id) else {
            return
        }
        let command = pending.command
        logger.info("MediaTransport chooser_echo_window_closed command=\(command.rawValue, privacy: .public) fallback=\(fallback, privacy: .public)")
        trace("chooser_echo_window_closed", command: command, reason: fallback ? "fallback" : "helper")
    }

    private func scheduleProgrammaticDispatchFallback(id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.programmaticDispatchFallbackDelayNanoseconds)
            guard let self,
                  let pending = self.programmaticDispatches[id]
            else {
                return
            }
            self.programmaticDispatches[id] = nil
            self.logger.error("MediaTransport programmatic_echo_window_fallback command=\(pending.command.rawValue, privacy: .public) kind=\(pending.kind.rawValue, privacy: .public)")
            self.trace(
                "echo_window_fallback",
                command: pending.command,
                reason: pending.kind.rawValue
            )
        }
    }

    private func trace(
        _ event: String,
        command: MediaRemoteTransportCommand?,
        source: MediaTransportRouteSource? = nil,
        target: MediaRemoteTarget? = nil,
        reason: String? = nil,
        transportBackend: String? = nil,
        targets: [MediaRemoteTarget]? = nil,
        targetCount: Int? = nil,
        metadata: MediaTransportInputMetadata? = nil,
        commandCenterMetadata: MediaCommandCenterInputMetadata? = nil
    ) {
        traceRecorder.record(
            event,
            command: command,
            source: source,
            target: target,
            targets: targets,
            reason: reason,
            transportBackend: transportBackend,
            targetCount: targetCount,
            mediaKeyMetadata: metadata,
            commandCenterMetadata: commandCenterMetadata,
            overlayVisible: overlayController.isVisible,
            chooserActive: chooserSession.isActive,
            canRoute: mediaRemoteController.canRouteCommands
        )
    }

    private func trace(result: MediaRemoteCommandResultEvent, transportBackend: String?) {
        traceRecorder.recordHelperResult(
            result,
            backend: transportBackend,
            overlayVisible: overlayController.isVisible,
            chooserActive: chooserSession.isActive,
            canRoute: mediaRemoteController.canRouteCommands
        )
    }

    private func showCommandFailureIfNeeded(result: MediaRemoteCommandResultEvent, target: MediaRemoteTarget) {
        guard !result.ok else {
            return
        }

        logger.error("MediaTransport async_route_failed command=\(result.command, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(result.targetID, privacy: .public) message=\(result.message, privacy: .public)")
        if result.unsupported {
            StatusHUD.shared.finish(
                title: "Command Unsupported",
                message: result.message,
                dismissAfter: 2.2
            )
            return
        }
        StatusHUD.shared.finish(
            title: "Media Command Failed",
            message: result.message.contains("-1743")
                ? "Allow Keyway to control \(target.appName) in System Settings > Privacy & Security > Automation, then retry."
                : "Keyway could not reach \(target.appName).",
            dismissAfter: 2.2
        )
    }

}
