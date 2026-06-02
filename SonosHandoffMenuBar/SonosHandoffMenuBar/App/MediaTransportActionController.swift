import AppKit
import ApplicationServices
import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class MediaTransportActionController {
    private static let commandCenterMediaKeyShadowInterval: TimeInterval = 0.25
    private static let commandCenterInputShadowInterval: TimeInterval = 0.15
    private static let programmaticCommandCenterEchoWindow: TimeInterval = 0.25
    private static let programmaticGeneratedMediaKeyCallbackWindow: TimeInterval = 0.25
    private static let physicalMediaKeyReboundWindow: TimeInterval = 0.25
    private static let chooserTargetedMediaKeyEchoWindow: TimeInterval = 1.25
    private static let programmaticDispatchFallbackDelayNanoseconds: UInt64 = 250_000_000
    private static let selectedRowDispatchRouteShieldReleaseDelayNanoseconds: UInt64 = 180_000_000

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaTransport")
    private let mediaRemoteController: MediaRemoteController
    private let overlayController: MediaTargetOverlayController
    private let commandCenterFilter: MediaTransportCommandCenterFilter
    private let traceRecorder = MediaTransportTraceRecorder()
    private let chooserSession = MediaChooserSessionGuard()
    private let focusResolver = MediaTargetFocusResolver()
    private var recentTargetIdentity: String?
    var relaxRouteShield: ((String) -> Void)?
    private var targetSubscription: AnyCancellable?
    private var programmaticDispatches: [UUID: MediaTransportPendingDispatchEcho] = [:]

    init(
        mediaRemoteController: MediaRemoteController,
        overlayController: MediaTargetOverlayController
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.overlayController = overlayController
        self.commandCenterFilter = MediaTransportCommandCenterFilter(
            mediaKeyShadowInterval: Self.commandCenterMediaKeyShadowInterval,
            commandCenterInputShadowInterval: Self.commandCenterInputShadowInterval,
            programmaticCommandCenterEchoWindow: Self.programmaticCommandCenterEchoWindow,
            programmaticGeneratedMediaKeyCallbackWindow: Self.programmaticGeneratedMediaKeyCallbackWindow,
            physicalMediaKeyReboundWindow: Self.physicalMediaKeyReboundWindow,
            chooserTargetedMediaKeyEchoWindow: Self.chooserTargetedMediaKeyEchoWindow
        )
        targetSubscription = mediaRemoteController.$targets
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTargets in
                guard let self else { return }
                guard !self.chooserSession.isActive else { return }
                let sorted = self.sortedTargets(newTargets)
                self.overlayController.updateTargetsIfVisible(
                    targets: sorted,
                    generation: self.overlayController.currentGeneration
                )
            }
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
            logger.info("MediaTransport command_center_route_shield_only_ignored command=\(command.rawValue, privacy: .public)")
            trace(
                "input_ignored",
                command: command,
                source: source,
                reason: "command_center_route_shield_only_ignored",
                commandCenterMetadata: commandCenterMetadata
            )
            return
        case .userInterface:
            break
        }

        if MediaTransportCommandRules.isPlayFamily(command) {
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
        routeFromCache(command: command)
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

    func currentRouteStatus() -> MediaRouteStatus {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty, mediaRemoteController.canRouteCommands else {
            return MediaRouteStatus(kind: .unavailable, target: nil, targetCount: 0)
        }

        if let decision = automaticTarget(from: targets) {
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
        guard mediaRemoteController.canRouteCommands else {
            logger.error("MediaTransport chooser_blocked command=\(commandName, privacy: .public) reason=helper_not_running")
            StatusHUD.shared.finish(
                title: "Media Targets Unavailable",
                message: "MediaRemote helper is not running.",
                dismissAfter: 2.4
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

    private func routeFromCache(command: MediaRemoteTransportCommand) {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty, mediaRemoteController.canRouteCommands else {
            mediaRemoteController.refreshSnapshot()
            StatusHUD.shared.finish(
                title: "No Media Target",
                message: "Start Spotify, a browser video, or QuickTime playback.",
                dismissAfter: 2.4
            )
            return
        }

        mediaRemoteController.refreshSnapshot()
        route(command: command, targets: targets)
    }

    private func route(command: MediaRemoteTransportCommand, targets: [MediaRemoteTarget]) {
        if let decision = automaticTarget(from: targets) {
            send(command: command, to: decision.target, reason: decision.reason)
            return
        }

        showChooserOverlay(command: command, targets: targets)
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
        MediaTransportCommandRules.sortedTargets(
            targets,
            preferredTargetID: recentTargetIdentity
        )
    }

    private func rememberTarget(_ target: MediaRemoteTarget) {
        recentTargetIdentity = target.routingIdentity
    }

    private func automaticTarget(from targets: [MediaRemoteTarget]) -> (target: MediaRemoteTarget, reason: MediaTransportRoutingReason)? {
        if targets.count == 1, let target = targets.first {
            return (target, .single)
        }

        let playingTargets = targets.filter(\.isCurrentlyPlaying)

        if let focusedTarget = focusResolver.focusedTarget(in: targets) {
            return (focusedTarget, .focused)
        }

        if playingTargets.count == 1, let playingTarget = playingTargets.first {
            return (playingTarget, .current)
        }

        return nil
    }

    private func send(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget, reason: MediaTransportRoutingReason) {
        logger.info("MediaTransport dispatch command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        rememberTarget(target)
        let dispatchID = beginBoundedProgrammaticDispatch(command: command)
        if usesSpotifyDesktopTransport(target: target) {
            let result = submitSpotifyDesktopCommand(command: command, target: target)
            trace(result: result, transportBackend: result.backend)
            finishProgrammaticDispatch(
                id: dispatchID,
                fallback: false
            )
            mediaRemoteController.refreshSnapshot()
            showCommandFailureIfNeeded(result: result, target: target)
            logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=spotify_desktop")
            return
        }
        if usesHeliumDesktopTransport(target: target), command == .playPause {
            let result = submitHeliumDesktopCommand(command: command, target: target)
            trace(result: result, transportBackend: result.backend)
            finishProgrammaticDispatch(
                id: dispatchID,
                fallback: false
            )
            mediaRemoteController.refreshSnapshot()
            showCommandFailureIfNeeded(result: result, target: target)
            logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=helium_desktop")
            return
        }
        let sent = mediaRemoteController.submit(command: command, targetID: target.id) { [weak self] result in
            self?.trace(result: result, transportBackend: Self.mediaRemotePlayerPathBackend)
            self?.finishProgrammaticDispatch(
                id: dispatchID,
                fallback: false
            )
            self?.showCommandFailureIfNeeded(result: result, target: target)
        }
        guard sent else {
            finishProgrammaticDispatch(id: dispatchID, fallback: true)
            logger.error("MediaTransport route_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
            return
        }

        logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
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
        if usesSpotifyDesktopTransport(target: target) {
            let result = submitSpotifyDesktopCommand(command: command, target: target)
            trace(result: result, transportBackend: result.backend)
            finishChooserDispatch(
                id: dispatchID,
                fallback: false
            )
            mediaRemoteController.refreshSnapshot()
            showCommandFailureIfNeeded(result: result, target: target)
            logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=spotify_desktop")
            return
        }
        if usesHeliumDesktopTransport(target: target), command == .playPause {
            let result = submitHeliumDesktopCommand(command: command, target: target)
            trace(result: result, transportBackend: result.backend)
            finishChooserDispatch(
                id: dispatchID,
                fallback: false
            )
            mediaRemoteController.refreshSnapshot()
            showCommandFailureIfNeeded(result: result, target: target)
            logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=helium_desktop")
            return
        }
        let sent = mediaRemoteController.submit(command: command, targetID: target.id) { [weak self] result in
            self?.trace(result: result, transportBackend: Self.mediaRemotePlayerPathBackend)
            self?.finishChooserDispatch(
                id: dispatchID,
                fallback: false
            )
            self?.showCommandFailureIfNeeded(result: result, target: target)
        }
        guard sent else {
            finishChooserDispatch(id: dispatchID, fallback: true)
            logger.error("MediaTransport chooser_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
            return
        }

        logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
    }

    private func chooserScopedCommand(
        _ command: MediaRemoteTransportCommand,
        for target: MediaRemoteTarget
    ) -> MediaRemoteTransportCommand {
        guard command == .playPause else {
            return MediaTransportCommandRules.rowScopedCommand(command, for: target)
        }
        if usesSpotifyDesktopTransport(target: target) || usesHeliumDesktopTransport(target: target) {
            return .playPause
        }
        return MediaTransportCommandRules.rowScopedCommand(command, for: target)
    }

    private static let mediaRemotePlayerPathBackend = "mediaremote_player_path"

    private func transportBackendName(command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> String {
        if usesSpotifyDesktopTransport(target: target) {
            return "spotify_apple_event"
        }
        if usesHeliumDesktopTransport(target: target), command == .playPause {
            return "helium_javascript"
        }
        return Self.mediaRemotePlayerPathBackend
    }

    private func desktopTransportName(target: MediaRemoteTarget) -> String? {
        if usesSpotifyDesktopTransport(target: target) {
            return "spotify_apple_event"
        }
        if usesHeliumDesktopTransport(target: target) {
            return "helium_javascript"
        }
        return nil
    }

    private func usesSpotifyDesktopTransport(target: MediaRemoteTarget) -> Bool {
        target.bundleIdentifier == "com.spotify.client" || target.parentBundleIdentifier == "com.spotify.client"
    }

    private func usesHeliumDesktopTransport(target: MediaRemoteTarget) -> Bool {
        target.bundleIdentifier == "net.imput.helium" || target.parentBundleIdentifier == "net.imput.helium"
    }

    private func submitSpotifyDesktopCommand(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        let eventID = Self.spotifyAppleEventID(command: command)
        let status = Self.sendAppleEvent(
            bundleIdentifier: "com.spotify.client",
            eventClass: "spfy",
            eventID: eventID
        )
        let ok = status == noErr
        return MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: ok,
            message: ok ? "submitted Spotify AppleEvent command event=\(eventID)" : "Spotify AppleEvent failed status=\(status)",
            backend: "spotify_apple_event"
        )
    }

    private func submitHeliumDesktopCommand(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        let result = runHeliumJavaScriptToggle()
        return MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: result.ok,
            message: result.ok ? "submitted Helium JavaScript command state=\(result.message)" : "Helium JavaScript failed: \(result.message)",
            backend: "helium_javascript"
        )
    }

    private func runHeliumJavaScriptToggle() -> (ok: Bool, message: String) {
        let script = NSAppleScript(source: Self.heliumJavaScriptToggleAppleScriptSource())!
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""
        if let error {
            return (false, String(describing: error))
        }
        return (output == "paused" || output == "playing" || output == "play_requested", output)
    }

    nonisolated private static func spotifyAppleEventID(command: MediaRemoteTransportCommand) -> String {
        switch command {
        case .play:
            return "Play"
        case .pause:
            return "Paus"
        case .playPause:
            return "PlPs"
        case .next:
            return "Next"
        case .previous:
            return "Prev"
        }
    }

    nonisolated private static func sendAppleEvent(
        bundleIdentifier: String,
        eventClass: String,
        eventID: String
    ) -> OSStatus {
        var target = AEAddressDesc()
        let targetStatus = bundleIdentifier.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                bundleIdentifier.lengthOfBytes(using: .utf8),
                &target
            )
        }
        guard targetStatus == noErr else {
            return OSStatus(targetStatus)
        }
        defer { AEDisposeDesc(&target) }

        var event = AppleEvent()
        let eventStatus = AECreateAppleEvent(
            AEEventClass(fourCharCode(eventClass)),
            AEEventID(fourCharCode(eventID)),
            &target,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        )
        guard eventStatus == noErr else {
            return OSStatus(eventStatus)
        }
        defer { AEDisposeDesc(&event) }

        return AESendMessage(
            &event,
            nil,
            AESendMode(kAENoReply | kAECanInteract | kAECanSwitchLayer),
            kAEDefaultTimeout
        )
    }

    nonisolated private static func fourCharCode(_ value: String) -> OSType {
        var result: UInt32 = 0
        for byte in value.utf8 {
            result = (result << 8) + UInt32(byte)
        }
        return result
    }

    nonisolated private static func heliumJavaScriptToggleAppleScriptSource() -> String {
        #"""
tell application id "net.imput.helium"
    if (count of windows) = 0 then return "no_windows"
    return execute active tab of front window javascript "(() => { const isReady = element => !element.ended && element.readyState > 0 && (Number.isFinite(element.duration) ? element.duration > 0 : true); const isPlaying = element => !element.paused && !element.ended; const collectDeepMedia = () => { const media = []; const seen = new Set(); const roots = [document]; for (let index = 0; index < roots.length; index += 1) { const root = roots[index]; root.querySelectorAll('video,audio').forEach(element => { if (!seen.has(element)) { seen.add(element); media.push(element); } }); root.querySelectorAll('*').forEach(element => { if (element.shadowRoot) roots.push(element.shadowRoot); }); root.querySelectorAll('iframe,frame').forEach(frame => { const source = frame.getAttribute('src') || ''; const sameOrigin = source === '' || source.startsWith('about:') || new URL(frame.src || source, location.href).origin === location.origin; const sandbox = frame.getAttribute('sandbox'); const sandboxAllowsSameOrigin = sandbox === null || sandbox.split(/\\s+/).includes('allow-same-origin'); if (sameOrigin && sandboxAllowsSameOrigin && frame.contentDocument) roots.push(frame.contentDocument); }); } return media; }; const direct = Array.from(document.querySelectorAll('video,audio')).filter(isReady); const directPlaying = direct.filter(isPlaying); if (directPlaying.length > 0) { directPlaying.forEach(element => element.pause()); return 'paused'; } const deep = collectDeepMedia().filter(isReady); const deepPlaying = deep.filter(isPlaying); if (deepPlaying.length > 0) { deepPlaying.forEach(element => element.pause()); return 'paused'; } let playable = deep.length > 0 ? deep : direct; const visibleArea = element => { const rect = element.getBoundingClientRect(); const view = element.ownerDocument.defaultView || window; const width = Math.max(0, Math.min(rect.right, view.innerWidth) - Math.max(rect.left, 0)); const height = Math.max(0, Math.min(rect.bottom, view.innerHeight) - Math.max(rect.top, 0)); return width * height; }; playable.sort((left, right) => visibleArea(right) - visibleArea(left) || ((right.videoWidth || 1) * (right.videoHeight || 1)) - ((left.videoWidth || 1) * (left.videoHeight || 1)) || right.duration - left.duration); const target = playable[0]; if (!target) return 'no_media'; target.play(); return target.paused ? 'play_requested' : 'playing'; })()"
end tell
"""#
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
        StatusHUD.shared.finish(
            title: "Media Command Failed",
            message: result.message.contains("-1743")
                ? "Allow Keyway to control \(target.appName) in System Settings > Privacy & Security > Automation, then retry."
                : "Keyway could not reach \(target.appName).",
            dismissAfter: 2.2
        )
    }

}
