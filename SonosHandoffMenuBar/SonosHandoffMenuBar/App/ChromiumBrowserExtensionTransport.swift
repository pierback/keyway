import AppKit
import Combine
import Foundation
import os

enum ChromiumBrowserExtensionTransport {
    static let backendName = "chromium_extension"
    static let mediaType = "chromium_extension"
    static let protocolVersion = 3
    static let targetIDPrefix = "chromium-tab:"
    static let nativeMessagingHostName = "com.fpieringer.keyway.chromium"
    static let extensionID = "gmdpkggbaohimgacbclndlfjghgcbael"
    static let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
    static let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
    static let focusResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.focusResult")
    static let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")
    private static let browserFamilyIdentityMatchers: [(family: String, keywords: [String])] = [
        ("helium", ["helium"]),
        ("arc", ["arc"]),
        ("brave", ["brave"]),
        ("edge", ["edge", "microsoft"]),
        ("opera", ["opera"]),
        ("vivaldi", ["vivaldi"]),
        ("chromium", ["chromium"]),
        ("chrome", ["chrome", "google"]),
    ]

    static func isTarget(_ target: MediaRemoteTarget) -> Bool {
        target.mediaType == mediaType || target.id.hasPrefix(targetIDPrefix)
    }

    static func profileGuid(targetID: String) -> String? {
        let parts = targetID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "chromium-tab" else {
            return nil
        }
        return String(parts[1])
    }

    static func browserFamily(target: MediaRemoteTarget) -> String? {
        guard isTarget(target) else {
            return nil
        }
        return target.browserFamily?.lowercased()
    }

    static func legacyBrowserFamily(target: MediaRemoteTarget) -> String? {
        guard !isTarget(target), target.isChromiumBrowserLike else {
            return nil
        }

        let identities = [target.bundleIdentifier, target.parentBundleIdentifier, target.displayName].map { $0.lowercased() }
        return browserFamily(identities: identities)
    }

    static func shadowsLegacyTarget(extensionTarget: MediaRemoteTarget, legacyTarget: MediaRemoteTarget) -> Bool {
        guard isTarget(extensionTarget),
              !isTarget(legacyTarget),
              legacyTarget.isChromiumBrowserLike,
              let extensionFamily = browserFamily(target: extensionTarget),
              let legacyFamily = legacyBrowserFamily(target: legacyTarget)
        else {
            return false
        }
        return extensionFamily == legacyFamily
    }

    private static func browserFamily(identities: [String]) -> String? {
        for matcher in browserFamilyIdentityMatchers
            where identities.contains(where: { identity in matcher.keywords.contains { identity.contains($0) } }) {
            return matcher.family
        }
        return nil
    }

    static func targetDisplayName(browser: String, pageTitle: String) -> String {
        let trimmedBrowser = browser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPageTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedBrowser.isEmpty {
            return trimmedPageTitle.isEmpty ? "Chromium" : trimmedPageTitle
        }
        if trimmedPageTitle.isEmpty {
            return trimmedBrowser
        }
        return "\(trimmedBrowser) - \(trimmedPageTitle)"
    }

    static func supports(command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> Bool {
        guard isTarget(target) else {
            return false
        }

        switch command {
        case .play, .pause, .playPause:
            return true
        case .next, .previous:
            return target.supportedCommands?.contains(command) == true
        }
    }

    static func unsupportedResult(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: false,
            message: "\(command.displayName) is not supported for Chromium extension targets.",
            backend: backendName,
            unsupported: true
        )
    }

    static func disconnectedResult(
        command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget
    ) -> MediaRemoteCommandResultEvent {
        MediaRemoteCommandResultEvent(
            type: "commandResult",
            requestID: UUID().uuidString,
            targetID: target.id,
            command: command.rawValue,
            ok: false,
            message: "Chromium extension is disconnected.",
            backend: backendName
        )
    }
}

struct ChromiumNativeMessagingHostInstallState: Equatable {
    let hostPath: String
    let manifestPaths: [String]
}

enum ChromiumNativeMessagingHostInstallError: LocalizedError, Equatable {
    case missingExecutable(path: String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            return "Bundled Chromium native host is missing or not executable at \(path)"
        }
    }
}

struct ChromiumNativeMessagingHostInstaller {
    private struct Manifest: Encodable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case path
            case type
            case allowedOrigins = "allowed_origins"
        }
    }

    private let fileManager: FileManager
    private let appBundleURL: URL

    init(
        appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.appBundleURL = appBundleURL
        self.fileManager = fileManager
    }

    var nativeHostExecutableURL: URL {
        appBundleURL.appendingPathComponent("Contents/Helpers/keyway-chromium-native-host")
    }

    func install() throws -> ChromiumNativeMessagingHostInstallState {
        guard fileManager.isExecutableFile(atPath: nativeHostExecutableURL.path) else {
            throw ChromiumNativeMessagingHostInstallError.missingExecutable(path: nativeHostExecutableURL.path)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Manifest(
            name: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            description: "Keyway Chromium media bridge",
            path: nativeHostExecutableURL.path,
            type: "stdio",
            allowedOrigins: ["chrome-extension://\(ChromiumBrowserExtensionTransport.extensionID)/"]
        ))

        let manifestPaths = nativeHostDirectories.map {
            $0.appendingPathComponent("\(ChromiumBrowserExtensionTransport.nativeMessagingHostName).json")
        }

        for manifestPath in manifestPaths {
            try fileManager.createDirectory(
                at: manifestPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: manifestPath, options: .atomic)
        }

        return ChromiumNativeMessagingHostInstallState(
            hostPath: nativeHostExecutableURL.path,
            manifestPaths: manifestPaths.map(\.path)
        )
    }

    private var nativeHostDirectories: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            "Library/Application Support/Arc/User Data/NativeMessagingHosts",
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Google/Chrome Canary/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser-Beta/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser-Dev/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser-Nightly/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge Beta/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge Dev/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge Canary/NativeMessagingHosts",
            "Library/Application Support/Vivaldi/NativeMessagingHosts",
            "Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts",
            "Library/Application Support/com.operasoftware.OperaGX/NativeMessagingHosts",
            "Library/Application Support/net.imput.helium/NativeMessagingHosts",
        ].map { home.appendingPathComponent($0) }
    }
}

enum ChromiumBrowserAudioCommand: Sendable {
    case mute
    case volumeDelta(Double)

    var rawValue: String {
        switch self {
        case .mute:
            return "mute"
        case .volumeDelta:
            return "volumeDelta"
        }
    }

    var displayName: String {
        switch self {
        case .mute:
            return "Mute"
        case .volumeDelta:
            return "Volume"
        }
    }

    var volumeDelta: Double? {
        switch self {
        case .mute:
            return nil
        case .volumeDelta(let delta):
            return delta
        }
    }
}

@MainActor
final class ChromiumBrowserExtensionController: ObservableObject {
    private static let commandResultTimeoutNanoseconds: UInt64 = 350_000_000
    private static let profileRetainVisibleDuration: TimeInterval = 10

    private struct SnapshotSource {
        let lastSnapshotAt: Date
        let targets: [MediaRemoteTarget]
        let browserBundleIdentifier: String?
        let visible: Bool
    }

    private struct ChromiumBrowserExtensionSnapshotEnvelope: Decodable {
        let protocolVersion: Int
        let profileGuid: String
        let connectionID: String
        let epoch: Int?
        let resumed: Bool?
        let browserBundleIdentifier: String?
    }

    private struct ChromiumBrowserExtensionCommandResultEnvelope: Decodable {
        let protocolVersion: Int
        let requestID: String
    }

    private struct ChromiumBrowserExtensionFocusResultEnvelope: Decodable {
        let protocolVersion: Int
        let requestID: String
    }

    @Published private(set) var connected = false
    @Published private(set) var targets: [MediaRemoteTarget] = []

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "ChromiumExtension")
    private let decoder = JSONDecoder()
    private var snapshotObserver: NSObjectProtocol?
    private var commandResultObserver: NSObjectProtocol?
    private var focusResultObserver: NSObjectProtocol?
    private var profileRetentionTimer: Timer?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var snapshotSourcesByProfileGuid: [String: SnapshotSource] = [:]
    private var connectionIDByProfileGuid: [String: String] = [:]
    private var highestAcceptedEpochByProfileGuid: [String: Int] = [:]
    private var pendingCommands: [String: ChromiumBrowserExtensionPendingCommand] = [:]
    private var commandResultTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingFocusRequests: [String: ChromiumBrowserExtensionPendingFocus] = [:]
    private var focusResultTimeouts: [String: Task<Void, Never>] = [:]

    var hasRoutableTargets: Bool {
        connected && !targets.isEmpty
    }

    func start() {
        guard snapshotObserver == nil else {
            return
        }

        snapshotObserver = DistributedNotificationCenter.default().addObserver(
            forName: ChromiumBrowserExtensionTransport.snapshotNotificationName,
            object: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            queue: .main
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? String else {
                self?.logger.error("Ignoring Chromium extension snapshot notification without payload")
                return
            }
            Task { @MainActor [weak self, payload] in
                self?.handleSnapshotPayload(payload)
            }
        }

        commandResultObserver = DistributedNotificationCenter.default().addObserver(
            forName: ChromiumBrowserExtensionTransport.commandResultNotificationName,
            object: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            queue: .main
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? String else {
                self?.logger.error("Ignoring Chromium extension command-result notification without payload")
                return
            }
            Task { @MainActor [weak self, payload] in
                self?.handleCommandResultPayload(payload)
            }
        }

        focusResultObserver = DistributedNotificationCenter.default().addObserver(
            forName: ChromiumBrowserExtensionTransport.focusResultNotificationName,
            object: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            queue: .main
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? String else {
                self?.logger.error("Ignoring Chromium extension focus-result notification without payload")
                return
            }
            Task { @MainActor [weak self, payload] in
                self?.handleFocusResultPayload(payload)
            }
        }

        profileRetentionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideSilentProfiles(now: Date())
            }
        }

        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleIdentifier = app.bundleIdentifier
            else {
                return
            }
            Task { @MainActor [weak self, bundleIdentifier] in
                self?.handleBrowserTermination(bundleIdentifier: bundleIdentifier)
            }
        }
    }

    func stop() {
        if let snapshotObserver {
            DistributedNotificationCenter.default().removeObserver(snapshotObserver)
        }
        if let commandResultObserver {
            DistributedNotificationCenter.default().removeObserver(commandResultObserver)
        }
        if let focusResultObserver {
            DistributedNotificationCenter.default().removeObserver(focusResultObserver)
        }
        if let workspaceTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceTerminationObserver)
        }
        snapshotObserver = nil
        commandResultObserver = nil
        focusResultObserver = nil
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
        resumed: Bool? = nil,
        browserBundleIdentifier: String? = nil,
        now: Date = Date()
    ) {
        guard acceptSnapshot(profileGuid: profileGuid, connectionID: connectionID, epoch: epoch, resumed: resumed) else {
            return
        }
        let chromiumTargets = targets.filter(ChromiumBrowserExtensionTransport.isTarget)
        snapshotSourcesByProfileGuid[profileGuid] = SnapshotSource(
            lastSnapshotAt: now,
            targets: chromiumTargets,
            browserBundleIdentifier: browserBundleIdentifier
                ?? chromiumTargets.compactMap(\.browserBundleIdentifier).first,
            visible: true
        )
        connectionIDByProfileGuid[profileGuid] = connectionID
        rebuildConnectionState()
    }

    func markDisconnected() {
        snapshotSourcesByProfileGuid = [:]
        connectionIDByProfileGuid = [:]
        highestAcceptedEpochByProfileGuid = [:]
        connected = false
        targets = []
    }

    func backendName(for target: MediaRemoteTarget) -> String? {
        ChromiumBrowserExtensionTransport.isTarget(target)
            ? ChromiumBrowserExtensionTransport.backendName
            : nil
    }

    func backendName(command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> String? {
        guard ChromiumBrowserExtensionTransport.isTarget(target) else {
            return nil
        }
        return ChromiumBrowserExtensionTransport.backendName
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
        guard connected else {
            onResult(SourceFocusResult(
                requestID: UUID().uuidString,
                targetID: target.id,
                ok: false,
                message: "Chromium extension is disconnected.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionDisconnected
            ))
            return true
        }
        guard let connectionID = connectionID(for: target) else {
            onResult(SourceFocusResult(
                requestID: UUID().uuidString,
                targetID: target.id,
                ok: false,
                message: "Chromium extension is disconnected.",
                backend: ChromiumBrowserExtensionTransport.backendName,
                failureReason: .chromiumExtensionDisconnected
            ))
            return true
        }

        let requestID = UUID().uuidString
        let payload = ChromiumBrowserExtensionFocusPayload(
            type: "focusTarget",
            protocolVersion: ChromiumBrowserExtensionTransport.protocolVersion,
            requestID: requestID,
            targetID: target.id,
            connectionID: connectionID
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
            resultHandler: onResult
        )
        armFocusResultTimeout(requestID: requestID)
        DistributedNotificationCenter.default().postNotificationName(
            ChromiumBrowserExtensionTransport.commandNotificationName,
            object: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            userInfo: ["payload": json],
            deliverImmediately: true
        )
        logger.info("ChromiumExtension focus_sent requestID=\(requestID, privacy: .public) target=\(target.id, privacy: .public)")
        return true
    }

    private func submit(
        commandName: String,
        volumeDelta: Double?,
        target: MediaRemoteTarget,
        onResult: @escaping (MediaRemoteCommandResultEvent) -> Void
    ) -> Bool? {
        guard let connectionID = connectionID(for: target) else {
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
            connectionID: connectionID
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
            resultHandler: onResult
        )
        armCommandResultTimeout(requestID: requestID)
        DistributedNotificationCenter.default().postNotificationName(
            ChromiumBrowserExtensionTransport.commandNotificationName,
            object: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            userInfo: ["payload": json],
            deliverImmediately: true
        )
        logger.info("ChromiumExtension command_sent requestID=\(requestID, privacy: .public) command=\(commandName, privacy: .public) target=\(target.id, privacy: .public)")
        return true
    }

    func targetsIncludingBrowserExtensionTargets(_ mediaRemoteTargets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        let visibleMediaRemoteTargets = mediaRemoteTargets.filter { target in
            !targets.contains {
                ChromiumBrowserExtensionTransport.shadowsLegacyTarget(extensionTarget: $0, legacyTarget: target)
            }
        }

        return visibleMediaRemoteTargets + targets.filter { extensionTarget in
            !visibleMediaRemoteTargets.contains { $0.id == extensionTarget.id }
        }
    }

    private func connectionID(for target: MediaRemoteTarget) -> String? {
        guard let profileGuid = ChromiumBrowserExtensionTransport.profileGuid(targetID: target.id) else {
            return nil
        }
        return connectionIDByProfileGuid[profileGuid]
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
            browserBundleIdentifier: snapshotEnvelope.browserBundleIdentifier
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
        guard result.targetID == pending.targetID,
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
        guard result.targetID == pending.targetID else {
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
        connected = !snapshotSourcesByProfileGuid.isEmpty

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
        epoch: Int,
        resumed: Bool?
    ) -> Bool {
        // A hello-derived snapshot (resumed true or false) always wins and adopts its
        // connectionID: it can only originate from the newest live worker for this
        // profile, so trusting it unconditionally is safe. Rejecting a resumed:true
        // hello whose persisted epoch lagged behind (a real race: the extension sends
        // the snapshot before its chrome.storage.session.set() write lands) would
        // otherwise leave connectionIDByProfileGuid pointing at the dead connection
        // forever -- every later ordinary snapshot (resumed == nil) from the live
        // worker would then fail the connectionID-mismatch check below regardless of
        // how high its epoch climbs, permanently wedging the profile until the
        // browser quits. Worst case of accepting eagerly is a sub-second regression
        // to slightly-stale bridge targets before the next real snapshot lands.
        if resumed != nil {
            highestAcceptedEpochByProfileGuid[profileGuid] = epoch
            return true
        }
        if let currentConnectionID = connectionIDByProfileGuid[profileGuid],
           currentConnectionID != connectionID,
           resumed == nil {
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
        for (profileGuid, source) in snapshotSourcesByProfileGuid where source.visible {
            if now.timeIntervalSince(source.lastSnapshotAt) > Self.profileRetainVisibleDuration {
                snapshotSourcesByProfileGuid[profileGuid] = SnapshotSource(
                    lastSnapshotAt: source.lastSnapshotAt,
                    targets: source.targets,
                    browserBundleIdentifier: source.browserBundleIdentifier,
                    visible: false
                )
                changed = true
            }
        }
        if changed {
            rebuildConnectionState()
        }
    }

    private func handleBrowserTermination(bundleIdentifier: String) {
        let terminatedProfileGuids = snapshotSourcesByProfileGuid.filter {
            $0.value.browserBundleIdentifier == bundleIdentifier
        }.keys
        guard !terminatedProfileGuids.isEmpty else {
            return
        }
        for profileGuid in terminatedProfileGuids {
            snapshotSourcesByProfileGuid.removeValue(forKey: profileGuid)
            connectionIDByProfileGuid.removeValue(forKey: profileGuid)
            highestAcceptedEpochByProfileGuid.removeValue(forKey: profileGuid)
        }
        rebuildConnectionState()
    }

    private func armCommandResultTimeout(requestID: String) {
        commandResultTimeouts[requestID]?.cancel()
        commandResultTimeouts[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.commandResultTimeoutNanoseconds)
            guard let self,
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
            try? await Task.sleep(nanoseconds: Self.commandResultTimeoutNanoseconds)
            guard let self,
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

private struct ChromiumBrowserExtensionPendingCommand {
    let startedAt: TimeInterval
    let commandName: String
    let targetID: String
    let resultHandler: (MediaRemoteCommandResultEvent) -> Void
}

private struct ChromiumBrowserExtensionPendingFocus {
    let startedAt: TimeInterval
    let targetID: String
    let resultHandler: (SourceFocusResult) -> Void
}

private struct ChromiumBrowserExtensionCommandPayload: Encodable {
    let type: String
    let protocolVersion: Int
    let requestID: String
    let targetID: String
    let command: String
    let volumeDelta: Double?
    let connectionID: String
}

private struct ChromiumBrowserExtensionFocusPayload: Encodable {
    let type: String
    let protocolVersion: Int
    let requestID: String
    let targetID: String
    let connectionID: String
}

private struct ChromiumBrowserExtensionSnapshotPayload: Decodable {
    let protocolVersion: Int
    let profileGuid: String
    let connectionID: String
    let targets: [ChromiumBrowserExtensionTargetPayload]
}

private struct ChromiumBrowserExtensionTargetPayload: Decodable {
    let id: String
    let browser: String
    let browserFamily: String?
    let browserDisplayName: String?
    let browserBundleIdentifier: String?
    let url: String
    let pageTitle: String
    let title: String
    let artist: String
    let album: String?
    let playing: Bool
    let duration: Double?
    let elapsedTime: Double?
    let supportedCommands: [String]

    var mediaRemoteTarget: MediaRemoteTarget {
        MediaRemoteTarget(
            id: id,
            bundleIdentifier: browserBundleIdentifier ?? ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            parentBundleIdentifier: "",
            displayName: ChromiumBrowserExtensionTransport.targetDisplayName(
                browser: browserDisplayName ?? browser,
                pageTitle: pageTitle
            ),
            pid: 0,
            title: title.isEmpty ? pageTitle : title,
            artist: artist.isEmpty ? url : artist,
            album: album ?? pageTitle,
            playbackRate: playing ? "1" : "0",
            mediaType: ChromiumBrowserExtensionTransport.mediaType,
            artworkBase64: nil,
            duration: duration,
            elapsedTime: elapsedTime,
            elapsedTimestamp: Date().timeIntervalSince1970,
            supportedCommands: supportedCommands.compactMap(MediaRemoteTransportCommand.init(rawValue:)),
            browserFamily: browserFamily,
            browserDisplayName: browserDisplayName,
            browserBundleIdentifier: browserBundleIdentifier
        )
    }
}
