import AppKit
import Combine
import Foundation
import KeywayChromiumBridgeIPC
import os

struct ChromiumBrowserProfileConnection: Equatable {
    let profileGuid: String
    let browserBundleIdentifier: String
}

@MainActor
final class ChromiumBrowserExtensionController: ObservableObject {
    private static let responseTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let connectionCloseGraceNanoseconds: UInt64 = 2_000_000_000
    private static let profileSuspectVisibleDuration: TimeInterval = 3
    private static let profileRetainVisibleDuration: TimeInterval = 10

    private struct SnapshotSource {
        let lastSnapshotAt: Date
        let targets: [MediaRemoteTarget]
        let browserBundleIdentifier: String
        let browserProcessIdentifier: Int
        let visible: Bool
    }

    private struct PendingConnectionClosure {
        let connectionID: String
        let connectionGeneration: UInt64
        let task: Task<Void, Never>
    }
    @Published private(set) var connected = false
    @Published private(set) var profileConnections: [ChromiumBrowserProfileConnection] = []
    @Published private(set) var targets: [MediaRemoteTarget] = []
    @Published private(set) var suspectTargetIDs: Set<String> = []

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "ChromiumExtension")
    private let decoder = JSONDecoder()
    private let ipc: any ChromiumBrowserExtensionIPC
    private var ipcStarted = false
    private var profileRetentionTimer: Timer?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var snapshotSourcesByProfileGuid: [String: SnapshotSource] = [:]
    private var connectionIDByProfileGuid: [String: String] = [:]
    private var highestAcceptedConnectionGenerationByProfileGuid: [String: UInt64] = [:]
    private var highestAcceptedEpochByProfileGuid: [String: Int] = [:]
    private var pendingConnectionClosuresByProfileGuid: [String: PendingConnectionClosure] = [:]
    private var pendingCommands: [String: ChromiumBrowserExtensionPendingCommand] = [:]
    private var commandResultTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingFocusRequests: [String: ChromiumBrowserExtensionPendingFocus] = [:]
    private var focusResultTimeouts: [String: Task<Void, Never>] = [:]
    private var runGeneration: UInt = 0

    init(ipc: (any ChromiumBrowserExtensionIPC)? = nil) {
        self.ipc = ipc ?? ChromiumBrowserExtensionIPCAdapter()
    }

    var hasRoutableTargets: Bool {
        connected && !targets.isEmpty
    }

    func start() {
        guard !ipcStarted else {
            return
        }
        runGeneration &+= 1
        let generation = runGeneration

        do {
            try ipc.start(
                onEvent: { [weak self] event, payload in
                    guard let self, runGeneration == generation else {
                        return
                    }
                    switch event {
                    case .snapshot:
                        handleSnapshotPayload(payload)
                    case .commandResult:
                        handleCommandResultPayload(payload)
                    case .focusResult:
                        handleFocusResultPayload(payload)
                    }
                },
                onConnectionClosed: { [weak self] lastSnapshotPayload in
                    guard let self,
                          runGeneration == generation,
                          let lastSnapshotPayload
                    else {
                        return
                    }
                    handleConnectionClosedPayload(lastSnapshotPayload)
                }
            )
            ipcStarted = true
        } catch {
            preconditionFailure("Unable to start authenticated Chromium bridge IPC: \(error)")
        }

        profileRetentionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, runGeneration == generation else {
                    return
                }
                hideSilentProfiles(now: Date())
            }
        }

        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let processIdentifier = Int(app.processIdentifier)
            Task { @MainActor [weak self] in
                guard let self, runGeneration == generation else {
                    return
                }
                handleBrowserTermination(processIdentifier: processIdentifier)
            }
        }

    }

    func stop() {
        runGeneration &+= 1
        if ipcStarted {
            ipc.stop()
            ipcStarted = false
        }
        if let workspaceTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceTerminationObserver)
        }
        workspaceTerminationObserver = nil
        profileRetentionTimer?.invalidate()
        profileRetentionTimer = nil
        commandResultTimeouts.values.forEach { $0.cancel() }
        commandResultTimeouts = [:]
        pendingCommands = [:]
        focusResultTimeouts.values.forEach { $0.cancel() }
        focusResultTimeouts = [:]
        pendingFocusRequests = [:]
        markDisconnected()
    }

    func markConnected(
        profileGuid: String,
        connectionID: String,
        targets: [MediaRemoteTarget],
        epoch: Int = 0,
        resumed: Bool? = false,
        connectionGeneration: UInt64 = 0,
        browserBundleIdentifier: String,
        browserProcessIdentifier: Int,
        now: Date = Date()
    ) {
        guard acceptSnapshot(
            profileGuid: profileGuid,
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            epoch: epoch,
            resumed: resumed
        ) else {
            return
        }
        pendingConnectionClosuresByProfileGuid.removeValue(forKey: profileGuid)?.task.cancel()
        let previousConnectionID = connectionIDByProfileGuid[profileGuid]
        let chromiumTargets = targets.filter(ChromiumBrowserExtensionTransport.isTarget)
        snapshotSourcesByProfileGuid[profileGuid] = SnapshotSource(
            lastSnapshotAt: now,
            targets: chromiumTargets,
            browserBundleIdentifier: browserBundleIdentifier,
            browserProcessIdentifier: browserProcessIdentifier,
            visible: true
        )
        clearSilentSuspects(profileGuid: profileGuid)
        connectionIDByProfileGuid[profileGuid] = connectionID
        if let previousConnectionID, previousConnectionID != connectionID {
            failPendingRequests(
                connectionID: previousConnectionID,
                message: "Chromium extension connection was replaced."
            )
        }
        rebuildConnectionState()
    }

    func markDisconnected() {
        pendingConnectionClosuresByProfileGuid.values.forEach { $0.task.cancel() }
        pendingConnectionClosuresByProfileGuid = [:]
        snapshotSourcesByProfileGuid = [:]
        connectionIDByProfileGuid = [:]
        highestAcceptedConnectionGenerationByProfileGuid = [:]
        highestAcceptedEpochByProfileGuid = [:]
        connected = false
        profileConnections = []
        targets = []
        suspectTargetIDs = []
    }

    func markConnectionClosed(
        profileGuid: String,
        connectionID: String,
        connectionGeneration: UInt64
    ) {
        guard connectionIDByProfileGuid[profileGuid] == connectionID,
              highestAcceptedConnectionGenerationByProfileGuid[profileGuid] == connectionGeneration
        else {
            return
        }

        pendingConnectionClosuresByProfileGuid.removeValue(forKey: profileGuid)?.task.cancel()
        let controllerGeneration = runGeneration
        let task = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: Self.connectionCloseGraceNanoseconds)) != nil,
                  !Task.isCancelled,
                  let self,
                  runGeneration == controllerGeneration,
                  connectionIDByProfileGuid[profileGuid] == connectionID,
                  highestAcceptedConnectionGenerationByProfileGuid[profileGuid] == connectionGeneration,
                  pendingConnectionClosuresByProfileGuid[profileGuid]?.connectionID == connectionID,
                  pendingConnectionClosuresByProfileGuid[profileGuid]?.connectionGeneration == connectionGeneration
            else {
                return
            }

            pendingConnectionClosuresByProfileGuid[profileGuid] = nil
            failPendingRequests(
                connectionID: connectionID,
                message: "Chromium extension connection closed."
            )
            snapshotSourcesByProfileGuid.removeValue(forKey: profileGuid)
            connectionIDByProfileGuid.removeValue(forKey: profileGuid)
            highestAcceptedEpochByProfileGuid.removeValue(forKey: profileGuid)
            clearSilentSuspects(profileGuid: profileGuid)
            rebuildConnectionState()
        }
        pendingConnectionClosuresByProfileGuid[profileGuid] = PendingConnectionClosure(
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            task: task
        )
    }

    func backendName(for target: MediaRemoteTarget) -> String? {
        ChromiumBrowserExtensionTransport.isTarget(target)
            ? ChromiumBrowserExtensionTransport.backendName
            : nil
    }

    func submit(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        onResult: @escaping (MediaRemoteCommandResultEvent) -> Void
    ) -> Bool? {
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        guard ChromiumBrowserExtensionTransport.supports(command: command, target: target) else {
            onResult(ChromiumBrowserExtensionTransport.unsupportedResult(command: command, target: target))
            return true
        }
        guard connected else {
            onResult(ChromiumBrowserExtensionTransport.disconnectedResult(command: command, target: target))
            return true
        }

        return submit(
            commandName: command.rawValue,
            volumeDelta: nil,
            target: target,
            onResult: onResult
        )
    }

    func submit(
        audioCommand: ChromiumBrowserAudioCommand,
        target: MediaRemoteTarget,
        onResult: @escaping (MediaRemoteCommandResultEvent) -> Void
    ) -> Bool? {
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        guard connected else {
            onResult(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: UUID().uuidString,
                targetID: target.id,
                command: audioCommand.rawValue,
                ok: false,
                message: "Chromium extension is disconnected.",
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
            return true
        }

        return submit(
            commandName: audioCommand.rawValue,
            volumeDelta: audioCommand.volumeDelta,
            target: target,
            onResult: onResult
        )
    }

    func focus(
        target: MediaRemoteTarget,
        onResult: @escaping (SourceFocusResult) -> Void
    ) -> Bool? {
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        guard connected,
              targets.contains(where: { $0.id == target.id }),
              !suspectTargetIDs.contains(target.id),
              let authority = connectionAuthority(for: target)
        else {

            return nil
        }

        let requestID = UUID().uuidString
        let payload = ChromiumBrowserExtensionFocusPayload(
            type: "focusTarget",
            protocolVersion: ChromiumBrowserExtensionTransport.protocolVersion,
            requestID: requestID,
            targetID: target.id,
            connectionID: authority.connectionID
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            logger.error("ChromiumExtension focus_encode_failed requestID=\(requestID, privacy: .public) target=\(target.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onResult(SourceFocusResult(
                requestID: requestID,
                targetID: target.id,
                ok: false,
                message: "Chromium extension focus payload encoding failed.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionPayloadEncodingFailed
            ))
            return true
        }
        guard let json = String(data: data, encoding: .utf8) else {
            logger.error("ChromiumExtension focus_encode_failed requestID=\(requestID, privacy: .public) target=\(target.id, privacy: .public) error=non_utf8_json")
            onResult(SourceFocusResult(
                requestID: requestID,
                targetID: target.id,
                ok: false,
                message: "Chromium extension focus payload encoding failed.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionPayloadEncodingFailed
            ))
            return true
        }
        pendingFocusRequests[requestID] = ChromiumBrowserExtensionPendingFocus(
            startedAt: ProcessInfo.processInfo.systemUptime,
            targetID: target.id,
            connectionID: authority.connectionID,
            connectionGeneration: authority.connectionGeneration,
            resultHandler: onResult
        )
        armFocusResultTimeout(requestID: requestID)
        ipc.sendCommand(json)
        logger.info("ChromiumExtension focus_sent requestID=\(requestID, privacy: .public) target=\(target.id, privacy: .public)")
        return true
    }

    private func submit(
        commandName: String,
        volumeDelta: Double?,
        target: MediaRemoteTarget,
        onResult: @escaping (MediaRemoteCommandResultEvent) -> Void
    ) -> Bool? {
        guard let authority = connectionAuthority(for: target) else {
            onResult(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: UUID().uuidString,
                targetID: target.id,
                command: commandName,
                ok: false,
                message: "Chromium extension is disconnected.",
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
            return true
        }
        let requestID = UUID().uuidString
        let payload = ChromiumBrowserExtensionCommandPayload(
            type: "command",
            protocolVersion: ChromiumBrowserExtensionTransport.protocolVersion,
            requestID: requestID,
            targetID: target.id,
            command: commandName,
            volumeDelta: volumeDelta,
            connectionID: authority.connectionID
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            logger.error("ChromiumExtension command_encode_failed requestID=\(requestID, privacy: .public) command=\(commandName, privacy: .public) target=\(target.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onResult(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: requestID,
                targetID: target.id,
                command: commandName,
                ok: false,
                message: "Chromium extension command payload encoding failed.",
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
            return true
        }
        guard let json = String(data: data, encoding: .utf8) else {
            logger.error("ChromiumExtension command_encode_failed requestID=\(requestID, privacy: .public) command=\(commandName, privacy: .public) target=\(target.id, privacy: .public) error=non_utf8_json")
            onResult(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: requestID,
                targetID: target.id,
                command: commandName,
                ok: false,
                message: "Chromium extension command payload encoding failed.",
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
            return true
        }
        pendingCommands[requestID] = ChromiumBrowserExtensionPendingCommand(
            startedAt: ProcessInfo.processInfo.systemUptime,
            commandName: commandName,
            targetID: target.id,
            connectionID: authority.connectionID,
            connectionGeneration: authority.connectionGeneration,
            resultHandler: onResult
        )
        armCommandResultTimeout(requestID: requestID)
        ipc.sendCommand(json)
        logger.info("ChromiumExtension command_sent requestID=\(requestID, privacy: .public) command=\(commandName, privacy: .public) target=\(target.id, privacy: .public)")
        return true
    }

    private func connectionAuthority(
        for target: MediaRemoteTarget
    ) -> (connectionID: String, connectionGeneration: UInt64)? {
        guard let profileGuid = ChromiumBrowserExtensionTransport.profileGuid(targetID: target.id),
              let connectionID = connectionIDByProfileGuid[profileGuid],
              let connectionGeneration = highestAcceptedConnectionGenerationByProfileGuid[profileGuid]
        else {
            return nil
        }
        return (connectionID, connectionGeneration)
    }

    private func handleSnapshotPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            logger.error("Ignoring Chromium extension snapshot with non-UTF-8 payload")
            return
        }
        let snapshotEnvelope: ChromiumBrowserExtensionSnapshotEnvelope
        do {
            snapshotEnvelope = try decoder.decode(ChromiumBrowserExtensionSnapshotEnvelope.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension snapshot envelope decode failure error=\(String(describing: error), privacy: .public)")
            return
        }
        guard snapshotEnvelope.protocolVersion == ChromiumBrowserExtensionTransport.protocolVersion else {
            logger.error("Ignoring Chromium extension snapshot protocol=\(snapshotEnvelope.protocolVersion, privacy: .public)")
            return
        }
        let snapshot: ChromiumBrowserExtensionSnapshotPayload
        do {
            snapshot = try decoder.decode(ChromiumBrowserExtensionSnapshotPayload.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension snapshot payload decode failure error=\(String(describing: error), privacy: .public)")
            return
        }
        markConnected(
            profileGuid: snapshot.profileGuid,
            connectionID: snapshot.connectionID,
            targets: snapshot.targets.map(\.mediaRemoteTarget),
            epoch: snapshotEnvelope.epoch ?? 0,
            resumed: snapshotEnvelope.resumed,
            connectionGeneration: snapshotEnvelope.connectionGeneration,
            browserBundleIdentifier: snapshotEnvelope.browserBundleIdentifier,
            browserProcessIdentifier: snapshotEnvelope.browserProcessIdentifier
        )
    }

    private func handleConnectionClosedPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            logger.error("Ignoring Chromium extension connection closure with non-UTF-8 snapshot payload")
            return
        }
        let snapshotEnvelope: ChromiumBrowserExtensionSnapshotEnvelope
        do {
            snapshotEnvelope = try decoder.decode(ChromiumBrowserExtensionSnapshotEnvelope.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension connection closure snapshot decode failure error=\(String(describing: error), privacy: .public)")
            return
        }
        guard snapshotEnvelope.protocolVersion == ChromiumBrowserExtensionTransport.protocolVersion else {
            logger.error("Ignoring Chromium extension connection closure protocol=\(snapshotEnvelope.protocolVersion, privacy: .public)")
            return
        }
        markConnectionClosed(
            profileGuid: snapshotEnvelope.profileGuid,
            connectionID: snapshotEnvelope.connectionID,
            connectionGeneration: snapshotEnvelope.connectionGeneration
        )
    }

    private func handleCommandResultPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            logger.error("Ignoring Chromium extension command-result with non-UTF-8 payload")
            return
        }
        let commandEnvelope: ChromiumBrowserExtensionCommandResultEnvelope
        do {
            commandEnvelope = try decoder.decode(ChromiumBrowserExtensionCommandResultEnvelope.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension command-result envelope decode failure error=\(String(describing: error), privacy: .public)")
            return
        }
        guard commandEnvelope.protocolVersion == ChromiumBrowserExtensionTransport.protocolVersion else {
            logger.error("Ignoring Chromium extension command-result protocol=\(commandEnvelope.protocolVersion, privacy: .public) requestID=\(commandEnvelope.requestID, privacy: .public)")
            guard let pending = pendingCommands.removeValue(forKey: commandEnvelope.requestID) else {
                return
            }
            commandResultTimeouts.removeValue(forKey: commandEnvelope.requestID)?.cancel()
            pending.resultHandler(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: commandEnvelope.requestID,
                targetID: pending.targetID,
                command: pending.commandName,
                ok: false,
                message: "Chromium extension protocol mismatch.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                unsupported: true
            ))
            return
        }
        let result: MediaRemoteCommandResultEvent
        do {
            result = try decoder.decode(MediaRemoteCommandResultEvent.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension command-result payload decode failure requestID=\(commandEnvelope.requestID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        guard let requestID = result.requestID,
              let pending = pendingCommands[requestID]
        else {
            return
        }
        guard commandEnvelope.connectionID == pending.connectionID,
              commandEnvelope.connectionGeneration == pending.connectionGeneration,
              result.targetID == pending.targetID,
              result.command == pending.commandName
        else {
            pendingCommands.removeValue(forKey: requestID)
            commandResultTimeouts.removeValue(forKey: requestID)?.cancel()
            let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
            logger.error(
                "ChromiumExtension command_result_mismatch requestID=\(requestID, privacy: .public) expectedCommand=\(pending.commandName, privacy: .public) actualCommand=\(result.command, privacy: .public) expectedTarget=\(pending.targetID, privacy: .public) actualTarget=\(result.targetID, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)"
            )
            pending.resultHandler(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: requestID,
                targetID: pending.targetID,
                command: pending.commandName,
                ok: false,
                message: "Chromium extension command-result did not match the queued request.",
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
            return
        }
        pendingCommands.removeValue(forKey: requestID)
        commandResultTimeouts.removeValue(forKey: requestID)?.cancel()
        let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
        logger.info("ChromiumExtension command_result requestID=\(requestID, privacy: .public) command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=\(result.ok, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
        pending.resultHandler(result)
    }

    private func handleFocusResultPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            logger.error("Ignoring Chromium extension focus-result with non-UTF-8 payload")
            return
        }
        let focusEnvelope: ChromiumBrowserExtensionFocusResultEnvelope
        do {
            focusEnvelope = try decoder.decode(ChromiumBrowserExtensionFocusResultEnvelope.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension focus-result envelope decode failure error=\(String(describing: error), privacy: .public)")
            return
        }
        guard focusEnvelope.protocolVersion == ChromiumBrowserExtensionTransport.protocolVersion else {
            logger.error("Ignoring Chromium extension focus-result protocol=\(focusEnvelope.protocolVersion, privacy: .public) requestID=\(focusEnvelope.requestID, privacy: .public)")
            guard let pending = pendingFocusRequests.removeValue(forKey: focusEnvelope.requestID) else {
                return
            }
            focusResultTimeouts.removeValue(forKey: focusEnvelope.requestID)?.cancel()
            pending.resultHandler(SourceFocusResult(
                requestID: focusEnvelope.requestID,
                targetID: pending.targetID,
                ok: false,
                message: "Chromium extension protocol mismatch.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionProtocolMismatch
            ))
            return
        }
        let result: SourceFocusResult
        do {
            result = try decoder.decode(SourceFocusResult.self, from: data)
        } catch {
            logger.error("Ignoring Chromium extension focus-result payload decode failure requestID=\(focusEnvelope.requestID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        guard let requestID = result.requestID,
              let pending = pendingFocusRequests[requestID]
        else {
            return
        }
        guard focusEnvelope.connectionID == pending.connectionID,
              focusEnvelope.connectionGeneration == pending.connectionGeneration,
              result.targetID == pending.targetID
        else {
            pendingFocusRequests.removeValue(forKey: requestID)
            focusResultTimeouts.removeValue(forKey: requestID)?.cancel()
            let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
            logger.error(
                "ChromiumExtension focus_result_mismatch requestID=\(requestID, privacy: .public) expectedTarget=\(pending.targetID, privacy: .public) actualTarget=\(result.targetID, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)"
            )
            pending.resultHandler(SourceFocusResult(
                requestID: requestID,
                targetID: pending.targetID,
                ok: false,
                message: "Chromium extension focus-result did not match the queued request.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionProtocolMismatch
            ))
            return
        }
        pendingFocusRequests.removeValue(forKey: requestID)
        focusResultTimeouts.removeValue(forKey: requestID)?.cancel()
        let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
        logger.info("ChromiumExtension focus_result requestID=\(requestID, privacy: .public) target=\(result.targetID, privacy: .public) ok=\(result.ok, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
        pending.resultHandler(result)
    }

    private func rebuildConnectionState() {
        let nextConnected = !snapshotSourcesByProfileGuid.isEmpty
        if connected != nextConnected {
            connected = nextConnected
        }
        let nextProfileConnections = snapshotSourcesByProfileGuid.keys.sorted().compactMap { profileGuid in
            snapshotSourcesByProfileGuid[profileGuid].map {
                ChromiumBrowserProfileConnection(
                    profileGuid: profileGuid,
                    browserBundleIdentifier: $0.browserBundleIdentifier
                )
            }
        }
        if profileConnections != nextProfileConnections {
            profileConnections = nextProfileConnections
        }

        var seenTargetIDs: Set<String> = []
        targets = snapshotSourcesByProfileGuid.keys.sorted()
            .compactMap { snapshotSourcesByProfileGuid[$0] }
            .filter(\.visible)
            .flatMap(\.targets)
            .filter { target in
                seenTargetIDs.insert(target.id).inserted
            }
    }

    private func acceptSnapshot(
        profileGuid: String,
        connectionID: String,
        connectionGeneration: UInt64,
        epoch: Int,
        resumed: Bool?
    ) -> Bool {
        guard let acceptedGeneration = highestAcceptedConnectionGenerationByProfileGuid[profileGuid] else {
            guard resumed != nil else {
                return false
            }
            highestAcceptedConnectionGenerationByProfileGuid[profileGuid] = connectionGeneration
            highestAcceptedEpochByProfileGuid[profileGuid] = epoch
            return true
        }

        guard connectionGeneration >= acceptedGeneration else {
            return false
        }
        if connectionGeneration > acceptedGeneration {
            guard resumed != nil else {
                return false
            }
            highestAcceptedConnectionGenerationByProfileGuid[profileGuid] = connectionGeneration
            highestAcceptedEpochByProfileGuid[profileGuid] = epoch
            return true
        }

        guard let currentConnectionID = connectionIDByProfileGuid[profileGuid],
              currentConnectionID == connectionID
        else {
            return false
        }
        if let highestAcceptedEpoch = highestAcceptedEpochByProfileGuid[profileGuid],
           epoch < highestAcceptedEpoch {
            return false
        }
        highestAcceptedEpochByProfileGuid[profileGuid] = max(
            highestAcceptedEpochByProfileGuid[profileGuid] ?? epoch,
            epoch
        )
        return true
    }

    private func hideSilentProfiles(now: Date) {
        var changed = false
        var nextSuspectTargetIDs: Set<String> = []
        for (profileGuid, source) in snapshotSourcesByProfileGuid where source.visible {
            let silenceDuration = now.timeIntervalSince(source.lastSnapshotAt)
            if silenceDuration > Self.profileRetainVisibleDuration {
                snapshotSourcesByProfileGuid[profileGuid] = SnapshotSource(
                    lastSnapshotAt: source.lastSnapshotAt,
                    targets: source.targets,
                    browserBundleIdentifier: source.browserBundleIdentifier,
                    browserProcessIdentifier: source.browserProcessIdentifier,
                    visible: false
                )
                changed = true
            } else if silenceDuration > Self.profileSuspectVisibleDuration {
                nextSuspectTargetIDs.formUnion(source.targets.map(\.id))
            }
        }
        if suspectTargetIDs != nextSuspectTargetIDs {
            suspectTargetIDs = nextSuspectTargetIDs
        }
        if changed {
            rebuildConnectionState()
        }
    }

    private func handleBrowserTermination(processIdentifier: Int) {
        let terminatedProfileGuids = snapshotSourcesByProfileGuid.filter {
            $0.value.browserProcessIdentifier == processIdentifier
        }.keys
        guard !terminatedProfileGuids.isEmpty else {
            return
        }
        for profileGuid in terminatedProfileGuids {
            pendingConnectionClosuresByProfileGuid.removeValue(forKey: profileGuid)?.task.cancel()
            if let connectionID = connectionIDByProfileGuid[profileGuid] {
                failPendingRequests(
                    connectionID: connectionID,
                    message: "Chromium browser process terminated."
                )
            }
            snapshotSourcesByProfileGuid.removeValue(forKey: profileGuid)
            connectionIDByProfileGuid.removeValue(forKey: profileGuid)
            highestAcceptedEpochByProfileGuid.removeValue(forKey: profileGuid)
        }
        suspectTargetIDs.subtract(
            suspectTargetIDs.filter { targetID in
                guard let profileGuid = ChromiumBrowserExtensionTransport.profileGuid(targetID: targetID) else {
                    return false
                }
                return terminatedProfileGuids.contains(profileGuid)
            }
        )
        rebuildConnectionState()
    }

    private func failPendingRequests(connectionID: String, message: String) {
        let commandRequestIDs = pendingCommands.compactMap {
            $0.value.connectionID == connectionID ? $0.key : nil
        }
        for requestID in commandRequestIDs {
            guard let pending = pendingCommands.removeValue(forKey: requestID) else {
                continue
            }
            commandResultTimeouts.removeValue(forKey: requestID)?.cancel()
            pending.resultHandler(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: requestID,
                targetID: pending.targetID,
                command: pending.commandName,
                ok: false,
                message: message,
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
        }

        let focusRequestIDs = pendingFocusRequests.compactMap {
            $0.value.connectionID == connectionID ? $0.key : nil
        }
        for requestID in focusRequestIDs {
            guard let pending = pendingFocusRequests.removeValue(forKey: requestID) else {
                continue
            }
            focusResultTimeouts.removeValue(forKey: requestID)?.cancel()
            pending.resultHandler(SourceFocusResult(
                requestID: requestID,
                targetID: pending.targetID,
                ok: false,
                message: message,
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .browserTargetUnavailable
            ))
        }
    }

    private func clearSilentSuspects(profileGuid: String) {
        suspectTargetIDs.subtract(
            suspectTargetIDs.filter { targetID in
                ChromiumBrowserExtensionTransport.profileGuid(targetID: targetID) == profileGuid
            }
        )
    }

    private func armCommandResultTimeout(requestID: String) {
        commandResultTimeouts[requestID]?.cancel()
        commandResultTimeouts[requestID] = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: Self.responseTimeoutNanoseconds)) != nil,
                  !Task.isCancelled,
                  let self,
                  let pending = self.pendingCommands.removeValue(forKey: requestID)
            else {
                return
            }
            self.commandResultTimeouts[requestID] = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
            self.logger.error("ChromiumExtension command_timeout requestID=\(requestID, privacy: .public) command=\(pending.commandName, privacy: .public) target=\(pending.targetID, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
            pending.resultHandler(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: requestID,
                targetID: pending.targetID,
                command: pending.commandName,
                ok: false,
                message: "Chromium extension command timed out",
                backend: ChromiumBrowserExtensionTransport.backendName
            ))
        }
    }

    private func armFocusResultTimeout(requestID: String) {
        focusResultTimeouts[requestID]?.cancel()
        focusResultTimeouts[requestID] = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: Self.responseTimeoutNanoseconds)) != nil,
                  !Task.isCancelled,
                  let self,
                  let pending = self.pendingFocusRequests.removeValue(forKey: requestID)
            else {
                return
            }
            self.focusResultTimeouts[requestID] = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
            self.logger.error("ChromiumExtension focus_timeout requestID=\(requestID, privacy: .public) target=\(pending.targetID, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
            pending.resultHandler(SourceFocusResult(
                requestID: requestID,
                targetID: pending.targetID,
                ok: false,
                message: "Chromium extension focus timed out",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionTimedOut
            ))
        }
    }
}
