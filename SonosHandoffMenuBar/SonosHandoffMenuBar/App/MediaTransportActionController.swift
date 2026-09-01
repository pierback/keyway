import Foundation
import Combine
import os
import SonosHandoffCore

@MainActor
final class MediaTransportActionController {
    private static let mediaKeyDownResetInterval: TimeInterval = 0.45
    private static let commandCenterMediaKeyShadowInterval: TimeInterval = 0.25
    private static let commandCenterInputShadowInterval: TimeInterval = 0.15
    private static let programmaticCommandCenterEchoWindow: TimeInterval = 1.25
    private static let programmaticGeneratedMediaKeyCallbackWindow: TimeInterval = 0.25
    private static let physicalMediaKeyReboundWindow: TimeInterval = 0.25
    private static let chooserTargetedMediaKeyEchoWindow: TimeInterval = 1.25
    private static let programmaticDispatchFallbackDelayNanoseconds: UInt64 = 250_000_000

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaTransport")
    private let mediaRemoteController: MediaRemoteController
    private let mediaSourceStore: MediaSourceStore
    private let overlayController: MediaTargetOverlayController
    private let commandCenterFilter: MediaTransportCommandCenterFilter
    private let desktopTransport = MediaDesktopTransportAdapter()
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let sourceFocusActionController: SourceFocusActionController
    private let targetSelectionMemory: MediaTargetSelectionMemory
    private let traceRecorder = MediaTransportTraceRecorder()
    private let chooserSession = MediaChooserSessionGuard()
    private let targetResolver = MediaTransportTargetResolver()
    private var programmaticDispatches: [UUID: MediaTransportPendingDispatchEcho] = [:]
    private var programmaticDispatchFallbackTasks: [UUID: Task<Void, Error>] = [:]
    private var routeConfirmationPresentation: (targetID: String, command: MediaRemoteTransportCommand)?

    init(
        mediaRemoteController: MediaRemoteController,
        mediaSourceStore: MediaSourceStore,
        overlayController: MediaTargetOverlayController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController = ChromiumBrowserExtensionController(),
        sourceFocusActionController: SourceFocusActionController,
        targetSelectionMemory: MediaTargetSelectionMemory
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.mediaSourceStore = mediaSourceStore
        self.overlayController = overlayController
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.sourceFocusActionController = sourceFocusActionController
        self.targetSelectionMemory = targetSelectionMemory
        self.commandCenterFilter = MediaTransportCommandCenterFilter(
            mediaKeyDownResetInterval: Self.mediaKeyDownResetInterval,
            mediaKeyShadowInterval: Self.commandCenterMediaKeyShadowInterval,
            commandCenterInputShadowInterval: Self.commandCenterInputShadowInterval,
            programmaticCommandCenterEchoWindow: Self.programmaticCommandCenterEchoWindow,
            programmaticGeneratedMediaKeyCallbackWindow: Self.programmaticGeneratedMediaKeyCallbackWindow,
            physicalMediaKeyReboundWindow: Self.physicalMediaKeyReboundWindow,
            chooserTargetedMediaKeyEchoWindow: Self.chooserTargetedMediaKeyEchoWindow
        )
    }

    deinit {
        MainActor.assumeIsolated {
            for task in programmaticDispatchFallbackTasks.values {
                task.cancel()
            }
        }
    }

    func route(command: MediaRemoteTransportCommand) {
        route(command: command, source: .userInterface)
    }

    func routeFromMediaKey(command: MediaRemoteTransportCommand, metadata: MediaTransportInputMetadata? = nil) {
        logInput(
            command: command,
            source: .eventTap,
            metadata: metadata,
            commandCenterMetadata: nil
        )
        routeAccepted(
            command: command,
            source: .eventTap,
            metadata: metadata,
            commandCenterMetadata: nil
        )
    }

    func ignoreReasonForMediaKeyDown(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata
    ) -> MediaTransportCommandCenterFilter.IgnoreReason? {
        commandCenterFilter.ignoreReasonForMediaKeyDown(command: command, metadata: metadata)
    }

    func noteMediaKeyUp(command: MediaRemoteTransportCommand) {
        commandCenterFilter.noteMediaKeyUp(command: command)
    }

    func resetMediaKeyState() {
        commandCenterFilter.resetMediaKeyState()
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
        logInput(
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
        switch source {
        case .eventTap:
            preconditionFailure("Media-key input must pass through the media-key state policy.")
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

        routeAccepted(
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func logInput(
        command: MediaRemoteTransportCommand,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) {
        logger.info("MediaTransport input command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) overlayVisible=\(self.overlayController.isVisible, privacy: .public) chooserActive=\(self.chooserSession.isActive, privacy: .public) canRoute=\(self.canRouteAnyCommands, privacy: .public) targetCount=\(self.mediaSourceStore.rows.count, privacy: .public)")
        trace(
            "input",
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
    }

    private func routeAccepted(
        command: MediaRemoteTransportCommand,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) {
        logger.info("MediaTransport decision=current_targets command=\(command.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")
        trace(
            "decision_current_targets",
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

    func showTargetChooser() {
        showChooserFromCache(command: nil)
    }

    func route(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget) {
        routeConfirmationPresentation = nil
        rememberTarget(target)
        let dispatchID = beginBoundedProgrammaticDispatch(command: command)
        send(command: command, to: target, dispatchID: dispatchID, context: .direct)
    }

    func focus(target: MediaRemoteTarget) {
        rememberTarget(target)
        sourceFocusActionController.focus(target: target)
    }

    private func showChooserFromCache(command: MediaRemoteTransportCommand?) {
        showChooserImmediately(command: command, source: .userInterface)
    }

    private func chooserReentryBlocked(
        command: MediaRemoteTransportCommand?,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) -> Bool {
        guard overlayController.isAwaitingSelection || chooserSession.isActive else {
            return false
        }

        let commandName = command?.rawValue ?? "none"
        let chooserState = overlayController.isAwaitingSelection ? "visible" : chooserSession.stateName
        logger.info("MediaTransport chooser_reentry_ignored command=\(commandName, privacy: .public) source=\(source.rawValue, privacy: .public) state=\(chooserState, privacy: .public)")
        trace(
            "chooser_reentry_ignored",
            command: command,
            source: source,
            reason: chooserState,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        )
        return true
    }

    private func showChooserImmediately(
        command: MediaRemoteTransportCommand?,
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata? = nil,
        commandCenterMetadata: MediaCommandCenterInputMetadata? = nil
    ) {
        if chooserReentryBlocked(
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        ) {
            return
        }

        let commandName = command?.rawValue ?? "none"
        let cached = sortedTargets(mediaSourceStore.rows.map(\.target))
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
        let targets = sortedTargets(mediaSourceStore.rows.map(\.target))
        guard !targets.isEmpty else {
            mediaRemoteController.refreshSnapshot()
            showChooserOverlay(
                command: command,
                targets: [],
                source: source,
                metadata: metadata,
                commandCenterMetadata: commandCenterMetadata
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

    private func route(
        command: MediaRemoteTransportCommand,
        targets: [MediaRemoteTarget],
        source: MediaTransportRouteSource,
        metadata: MediaTransportInputMetadata?,
        commandCenterMetadata: MediaCommandCenterInputMetadata?
    ) {
        let rowsByID = Dictionary(mediaSourceStore.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        if targets.count == 1 {
            if MediaTransportCommandRules.shouldOpenChooserForAutomaticRoute(reachability: rowsByID[targets[0].id]?.reachability) {
                showChooserOverlay(
                    command: command,
                    targets: targets,
                    source: source,
                    metadata: metadata,
                    commandCenterMetadata: commandCenterMetadata
                )
                return
            }
            send(
                command: command,
                to: targets[0],
                rows: sourceRows(for: targets),
                reason: .single
            )
            return
        }

        if MediaTransportCommandRules.isPlayFamily(command) {
            showChooserOverlay(
                command: command,
                targets: targets,
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
            if MediaTransportCommandRules.shouldOpenChooserForAutomaticRoute(reachability: rowsByID[decision.target.id]?.reachability) {
                showChooserOverlay(
                    command: command,
                    targets: targets,
                    source: source,
                    metadata: metadata,
                    commandCenterMetadata: commandCenterMetadata
                )
                return
            }
            send(
                command: command,
                to: decision.target,
                rows: sourceRows(for: targets),
                reason: decision.reason
            )
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
        if chooserReentryBlocked(
            command: command,
            source: source,
            metadata: metadata,
            commandCenterMetadata: commandCenterMetadata
        ) {
            return
        }

        let chooserID = chooserSession.begin(command: command)
        let previousRouteConfirmation = routeConfirmationPresentation.flatMap { presentation in
            overlayController.isVisible && !overlayController.isAwaitingSelection
                ? presentation
                : nil
        }

        overlayController.show(
            command: command,
            rows: sourceRows(for: targets),
            rowUpdates: overlayRowUpdates(),
            emptyDiagnostics: { [weak self] in
                self?.emptyDiscoveryDiagnostics() ?? "Helper unavailable / bridge disconnected"
            },
            onChoose: { [weak self] target, command in
                guard let self else { return nil }
                self.logger.info("MediaTransport chooser_select requestedCommand=\(command?.rawValue ?? "none", privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) playing=\(target.isCurrentlyPlaying, privacy: .public)")
                self.trace(
                    "chooser_select",
                    command: command,
                    target: target,
                    targetCount: self.mediaSourceStore.rows.count
                )

                guard let command else {
                    self.chooserSession.finish(id: chooserID)
                    self.trace(
                        "chooser_closed_without_command",
                        command: nil,
                        target: target,
                        targetCount: self.mediaSourceStore.rows.count
                    )
                    self.mediaRemoteController.refreshSnapshot()
                    StatusHUD.shared.finish(
                        title: "\(target.appName)",
                        message: "No transport command was pending.",
                        dismissAfter: 1.35
                    )
                    return nil
                }

                let confirmationCommand = MediaTransportCommandRules.rowScopedCommand(
                    command,
                    for: target,
                    after: previousRouteConfirmation?.targetID == target.id
                        ? previousRouteConfirmation?.command
                        : nil
                )
                self.routeConfirmationPresentation = (target.id, confirmationCommand)

                self.chooserSession.finish(id: chooserID)
                self.trace(
                    "chooser_closed_for_dispatch",
                    command: command,
                    target: target,
                    targetCount: self.mediaSourceStore.rows.count
                )
                self.dispatchFromChooser(
                    command: confirmationCommand,
                    to: target,
                    metadata: metadata
                )
                return confirmationCommand
            },
            onFocus: { [weak self] target in
                guard let self else { return }
                self.logger.info("MediaTransport chooser_focus target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public)")
                self.chooserSession.finish(id: chooserID)
                self.trace(
                    "chooser_closed_for_focus",
                    command: command,
                    target: target,
                    targetCount: self.mediaSourceStore.rows.count
                )
                self.rememberTarget(target)
                self.sourceFocusActionController.focus(target: target)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                let activeCommand = self.chooserSession.activeCommand(for: chooserID)?.rawValue ?? "stale"
                self.logger.info("MediaTransport chooser_dismissed command=\(activeCommand, privacy: .public)")
                self.trace("chooser_dismissed", command: self.chooserSession.activeCommand(for: chooserID))
                self.chooserSession.finish(id: chooserID)
            }
        )
    }

    private func sortedTargets(_ targets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        targetResolver.sortedTargets(
            targets,
            preferredTargetID: targetSelectionMemory.recentTargetID
        )
    }

    private func sourceRows(for targets: [MediaRemoteTarget]) -> [SourceRow] {
        let rowsByID = Dictionary(mediaSourceStore.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return targets.map { target in
            rowsByID[target.id] ?? SourceRow(target: target)
        }
    }

    private func overlayRowUpdates() -> AnyPublisher<[SourceRow], Never> {
        // Order the emitted rows, but keep the rows themselves: @Published emits from
        // willSet, so mediaSourceStore.rows still holds the PREVIOUS array during this
        // emission -- re-deriving rows via sourceRows(for:) here would hand the open
        // chooser reachability that is one emission stale (and default newly-appearing
        // rows to .live even when suspect). The emitted array already carries the
        // correct per-row reachability; only the ordering needs applying.
        mediaSourceStore.$rows
            .map { [weak self] rows in
                MainActor.assumeIsolated {
                    guard let self else {
                        return rows
                    }
                    let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    return self.sortedTargets(rows.map(\.target)).compactMap { rowsByID[$0.id] }
                }
            }
            .eraseToAnyPublisher()
    }

    private func emptyDiscoveryDiagnostics() -> String {
        let helperStatus = mediaRemoteController.health.isHealthy
            ? "Helper running"
            : "Helper \(mediaRemoteController.health.badgeTitle.lowercased())"
        let bridgeStatus = chromiumBrowserExtensionController.connected
            ? "bridge connected"
            : "bridge disconnected"
        return "\(helperStatus) / \(bridgeStatus)"
    }

    private func rememberTarget(_ target: MediaRemoteTarget) {
        targetSelectionMemory.remember(target)
    }

    private enum MediaTransportDispatchContext {
        case programmatic(reason: MediaTransportRoutingReason)
        case direct
        case chooser
    }

    private func send(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        rows: [SourceRow],
        reason: MediaTransportRoutingReason
    ) {
        logger.info("MediaTransport dispatch command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        rememberTarget(target)
        let previousConfirmationCommand = routeConfirmationPresentation.flatMap { presentation in
            overlayController.isVisible
                && !overlayController.isAwaitingSelection
                && presentation.targetID == target.id
                ? presentation.command
                : nil
        }
        let spotlightCommand = MediaTransportCommandRules.rowScopedCommand(
            command,
            for: target,
            after: previousConfirmationCommand
        )
        routeConfirmationPresentation = (target.id, spotlightCommand)
        overlayController.showAutomaticRoute(command: spotlightCommand, target: target, rows: rows)
        let dispatchID = beginBoundedProgrammaticDispatch(command: spotlightCommand)
        send(command: spotlightCommand, to: target, dispatchID: dispatchID, context: .programmatic(reason: reason))
    }

    private func send(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID,
        context: MediaTransportDispatchContext
    ) {
        if let backend = desktopTransport.submit(command: command, target: target, onResult: { [weak self] result in
            guard let self else { return }
            self.mediaSourceStore.recordCommandResult(result)
            self.trace(result: result, transportBackend: result.backend)
            self.finishDispatch(id: dispatchID, fallback: false)
            self.mediaRemoteController.refreshSnapshot()
            self.showCommandResult(
                result: result,
                target: target
            )
        }) {
            scheduleProgrammaticDispatchFallback(id: dispatchID)
            logDispatch(command: command, target: target, context: context, transport: backend)
            return
        }
        if let sent = chromiumBrowserExtensionController.submit(command: command, target: target, onResult: { [weak self] result in
            guard let self else { return }
            self.mediaSourceStore.recordCommandResult(result)
            self.trace(result: result, transportBackend: result.backend)
            self.finishDispatch(id: dispatchID, fallback: false)
            self.showCommandResult(
                result: result,
                target: target
            )
        }) {
            guard sent else {
                mediaSourceStore.markCommandFailed(targetID: target.id)
                finishDispatch(id: dispatchID, fallback: true)
                StatusHUD.shared.finish(
                    title: "Media Command Failed",
                    message: "Keyway could not reach \(target.appName).",
                    dismissAfter: 2.2
                )
                return
            }
            scheduleProgrammaticDispatchFallback(id: dispatchID)
            logDispatch(command: command, target: target, context: context, transport: "chromium_extension")
            return
        }
        fallbackMediaRemote(command: command, to: target, dispatchID: dispatchID, context: context)
    }

    private func fallbackMediaRemote(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID,
        context: MediaTransportDispatchContext
    ) {
        let routedCommand = MediaTransportCommandRules.rowScopedCommand(command, for: target, after: nil)
        guard sendMediaRemote(
            command: routedCommand,
            to: target,
            dispatchID: dispatchID,
            context: context
        ) else {
            self.mediaRemoteController.probeHelperLiveness()
            mediaRemoteDispatchFailed(
                command: command,
                target: target,
                dispatchID: dispatchID,
                context: context
            )
            return
        }
    }

    private func mediaRemoteDispatchFailed(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        dispatchID: UUID,
        context: MediaTransportDispatchContext
    ) {
        mediaSourceStore.markCommandFailed(targetID: target.id)
        finishDispatch(id: dispatchID, fallback: true)
        logDispatchFailure(command: command, target: target, context: context)
        StatusHUD.shared.finish(
            title: "Media Command Failed",
            message: "Keyway could not reach \(target.appName).",
            dismissAfter: 2.2
        )
    }

    private func sendMediaRemote(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        dispatchID: UUID,
        context: MediaTransportDispatchContext
    ) -> Bool {
        let sent = mediaRemoteController.submit(command: command, targetID: target.id) { [weak self] result in
            guard let self else {
                return
            }
            if !result.ok {
                self.mediaRemoteController.probeHelperLiveness()
            }
            self.mediaSourceStore.recordCommandResult(result)
            self.trace(result: result, transportBackend: Self.mediaRemotePlayerPathBackend)
            self.finishDispatch(id: dispatchID, fallback: false)
            self.showCommandResult(
                result: result,
                target: target
            )
        }
        if sent {
            scheduleProgrammaticDispatchFallback(id: dispatchID)
            logDispatch(command: command, target: target, context: context, transport: Self.mediaRemotePlayerPathBackend)
        }
        return sent
    }

    private func dispatchFromChooser(
        command: MediaRemoteTransportCommand,
        to target: MediaRemoteTarget,
        metadata: MediaTransportInputMetadata?
    ) {
        logger.info("MediaTransport chooser_dispatch command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public) playing=\(target.isCurrentlyPlaying, privacy: .public)")
        rememberTarget(target)
        let transportBackend = desktopTransportName(target: target)
            ?? Self.mediaRemotePlayerPathBackend
        trace("chooser_dispatch", command: command, target: target, transportBackend: transportBackend)
        let dispatchID = beginBoundedChooserDispatch(
            command: command,
            metadata: metadata,
            targetUnixProcessID: Int64(target.pid),
            applicationUnixProcessID: Int64(ProcessInfo.processInfo.processIdentifier)
        )
        send(command: command, to: target, dispatchID: dispatchID, context: .chooser)
    }

    private func logDispatch(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        context: MediaTransportDispatchContext,
        transport: String
    ) {
        switch context {
        case .programmatic(let reason):
            logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public) transport=\(transport, privacy: .public)")
        case .direct:
            logger.info("MediaTransport direct command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=\(transport, privacy: .public)")
        case .chooser:
            logger.info("MediaTransport chooser command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) transport=\(transport, privacy: .public)")
        }
    }

    private func logDispatchFailure(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        context: MediaTransportDispatchContext
    ) {
        switch context {
        case .programmatic(let reason):
            logger.error("MediaTransport route_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        case .direct:
            logger.error("MediaTransport direct_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
        case .chooser:
            logger.error("MediaTransport chooser_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
        }
    }

    private static let mediaRemotePlayerPathBackend = "mediaremote_player_path"

    private func desktopTransportName(target: MediaRemoteTarget) -> String? {
        desktopTransport.backendName(for: target)
            ?? chromiumBrowserExtensionController.backendName(for: target)
    }

    private func beginBoundedProgrammaticDispatch(command: MediaRemoteTransportCommand) -> UUID {
        let id = UUID()
        programmaticDispatches[id] = MediaTransportPendingDispatchEcho(command: command, kind: .automatic)
        commandCenterFilter.beginProgrammaticDispatch(command: command)
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
        return id
    }

    private func finishDispatch(id: UUID, fallback: Bool) {
        programmaticDispatchFallbackTasks.removeValue(forKey: id)?.cancel()
        guard let pending = programmaticDispatches.removeValue(forKey: id) else {
            return
        }
        let command = pending.command
        switch pending.kind {
        case .automatic:
            logger.info("MediaTransport programmatic_echo_window_closed command=\(command.rawValue, privacy: .public) fallback=\(fallback, privacy: .public)")
            trace("programmatic_echo_window_closed", command: command, reason: fallback ? "fallback" : "helper")
        case .chooser:
            logger.info("MediaTransport chooser_echo_window_closed command=\(command.rawValue, privacy: .public) fallback=\(fallback, privacy: .public)")
            trace("chooser_echo_window_closed", command: command, reason: fallback ? "fallback" : "helper")
        }
    }

    private func scheduleProgrammaticDispatchFallback(id: UUID) {
        guard programmaticDispatches[id] != nil else {
            return
        }
        programmaticDispatchFallbackTasks[id]?.cancel()
        programmaticDispatchFallbackTasks[id] = Task { @MainActor [weak self] in
            try await Task.sleep(nanoseconds: Self.programmaticDispatchFallbackDelayNanoseconds)
            try Task.checkCancellation()
            guard let self else {
                return
            }
            self.programmaticDispatchFallbackTasks[id] = nil
            guard let pending = self.programmaticDispatches.removeValue(forKey: id) else {
                return
            }
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
            canRoute: canRouteAnyCommands
        )
    }

    private func trace(result: MediaRemoteCommandResultEvent, transportBackend: String?) {
        traceRecorder.recordHelperResult(
            result,
            backend: transportBackend,
            overlayVisible: overlayController.isVisible,
            chooserActive: chooserSession.isActive,
            canRoute: canRouteAnyCommands
        )
    }

    private var canRouteAnyCommands: Bool {
        mediaRemoteController.isHelperPairReady
            || chromiumBrowserExtensionController.hasRoutableTargets
    }

    private func showCommandResult(
        result: MediaRemoteCommandResultEvent,
        target: MediaRemoteTarget
    ) {
        if result.ok {
            return
        }

        logger.error("MediaTransport async_route_failed command=\(result.command, privacy: .public) target=\(target.appName, privacy: .public) targetID=\(result.targetID, privacy: .public) message=\(result.message, privacy: .public)")
        if result.message.contains("-1743") {
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Allow Keyway to control \(target.appName) in System Settings > Privacy & Security > Automation, then retry.",
                dismissAfter: 2.2
            )
            return
        }
        if result.unsupported {
            StatusHUD.shared.finish(
                title: "Command Unsupported",
                message: result.message,
                dismissAfter: 2.2
            )
            return
        }
        if result.backend == ChromiumBrowserExtensionTransport.backendName {
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: result.message,
                dismissAfter: 2.2
            )
            return
        }
        StatusHUD.shared.finish(
            title: "Media Command Failed",
            message: "Keyway could not reach \(target.appName).",
            dismissAfter: 2.2
        )
    }

}
