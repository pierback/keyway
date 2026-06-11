import Combine
import Foundation
import os

enum ChromiumBrowserExtensionTransport {
    static let backendName = "chromium_extension"
    static let mediaType = "chromium_extension"
    static let targetIDPrefix = "chromium-extension:"
    static let nativeMessagingHostName = "com.fpieringer.keyway.chromium"
    static let extensionID = "gmdpkggbaohimgacbclndlfjghgcbael"
    static let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
    static let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
    static let focusResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.focusResult")
    static let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")

    static func isTarget(_ target: MediaRemoteTarget) -> Bool {
        target.mediaType == mediaType || target.id.hasPrefix(targetIDPrefix)
    }

    static func browserFamily(target: MediaRemoteTarget) -> String? {
        guard isTarget(target) else {
            return nil
        }
        let parts = target.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            return nil
        }
        return parts[1].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map {
            String($0).lowercased()
        }
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
        precondition(
            fileManager.isExecutableFile(atPath: nativeHostExecutableURL.path),
            "Bundled Chromium native host is missing or not executable at \(nativeHostExecutableURL.path)"
        )

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
    private static let disconnectInterval: TimeInterval = 2
    private static let commandResultTimeoutNanoseconds: UInt64 = 350_000_000

    @Published private(set) var connected = false
    @Published private(set) var targets: [MediaRemoteTarget] = []

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "ChromiumExtension")
    private let decoder = JSONDecoder()
    private var snapshotObserver: NSObjectProtocol?
    private var commandResultObserver: NSObjectProtocol?
    private var focusResultObserver: NSObjectProtocol?
    private var disconnectTimer: Timer?
    private var lastMessageAt: Date?
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
                preconditionFailure("Chromium native host snapshot notifications must include a payload.")
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
                preconditionFailure("Chromium native host command-result notifications must include a payload.")
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
                preconditionFailure("Chromium native host focus-result notifications must include a payload.")
            }
            Task { @MainActor [weak self, payload] in
                self?.handleFocusResultPayload(payload)
            }
        }

        disconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markDisconnectedIfStale(now: Date())
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
        snapshotObserver = nil
        commandResultObserver = nil
        focusResultObserver = nil
        disconnectTimer?.invalidate()
        disconnectTimer = nil
        commandResultTimeouts.values.forEach { $0.cancel() }
        commandResultTimeouts = [:]
        pendingCommands = [:]
        focusResultTimeouts.values.forEach { $0.cancel() }
        focusResultTimeouts = [:]
        pendingFocusRequests = [:]
        markDisconnected()
    }

    func markConnected(targets: [MediaRemoteTarget]) {
        lastMessageAt = Date()
        self.connected = true
        self.targets = targets.filter(ChromiumBrowserExtensionTransport.isTarget)
    }

    func markDisconnected() {
        connected = false
        targets = []
        lastMessageAt = nil
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

        let requestID = UUID().uuidString
        let targetAddress = ChromiumBrowserExtensionTargetAddress(targetID: target.id)
        let payload = ChromiumBrowserExtensionFocusPayload(
            type: "focusTarget",
            requestID: requestID,
            targetID: target.id,
            windowId: targetAddress.windowID,
            tabId: targetAddress.tabID
        )
        let data = try! JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8)!
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
        let requestID = UUID().uuidString
        let targetAddress = ChromiumBrowserExtensionTargetAddress(targetID: target.id)
        let payload = ChromiumBrowserExtensionCommandPayload(
            type: "command",
            requestID: requestID,
            targetID: target.id,
            tabId: targetAddress.tabID,
            frameId: targetAddress.frameID,
            mediaId: targetAddress.mediaID,
            command: commandName,
            volumeDelta: volumeDelta
        )
        let data = try! JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8)!
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
        mediaRemoteTargets + targets.filter { extensionTarget in
            !mediaRemoteTargets.contains { $0.id == extensionTarget.id }
        }
    }

    private func handleSnapshotPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            preconditionFailure("Chromium native host snapshot notifications must include UTF-8 JSON.")
        }
        let snapshot = try! decoder.decode(ChromiumBrowserExtensionSnapshotPayload.self, from: data)
        markConnected(targets: snapshot.targets.map(\.mediaRemoteTarget))
    }

    private func handleCommandResultPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            preconditionFailure("Chromium native host command-result notifications must include UTF-8 JSON.")
        }
        let result = try! decoder.decode(MediaRemoteCommandResultEvent.self, from: data)
        guard let requestID = result.requestID,
              let pending = pendingCommands.removeValue(forKey: requestID)
        else {
            return
        }
        commandResultTimeouts.removeValue(forKey: requestID)?.cancel()
        lastMessageAt = Date()
        let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
        logger.info("ChromiumExtension command_result requestID=\(requestID, privacy: .public) command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=\(result.ok, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
        pending.resultHandler(result)
    }

    private func handleFocusResultPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            preconditionFailure("Chromium native host focus-result notifications must include UTF-8 JSON.")
        }
        let result = try! decoder.decode(SourceFocusResult.self, from: data)
        guard let requestID = result.requestID,
              let pending = pendingFocusRequests.removeValue(forKey: requestID)
        else {
            return
        }
        focusResultTimeouts.removeValue(forKey: requestID)?.cancel()
        lastMessageAt = Date()
        let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
        logger.info("ChromiumExtension focus_result requestID=\(requestID, privacy: .public) target=\(result.targetID, privacy: .public) ok=\(result.ok, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
        pending.resultHandler(result)
    }

    private func markDisconnectedIfStale(now: Date) {
        guard let lastMessageAt else {
            return
        }
        guard now.timeIntervalSince(lastMessageAt) > Self.disconnectInterval else {
            return
        }
        markDisconnected()
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
    let requestID: String
    let targetID: String
    let tabId: Int
    let frameId: Int
    let mediaId: String
    let command: String
    let volumeDelta: Double?
}

private struct ChromiumBrowserExtensionFocusPayload: Encodable {
    let type: String
    let requestID: String
    let targetID: String
    let windowId: Int
    let tabId: Int
}

struct ChromiumBrowserExtensionTargetAddress {
    let browserKey: String
    let windowID: Int
    let tabID: Int
    let frameID: Int
    let mediaID: String

    init(targetID: String) {
        let parts = targetID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        precondition(
            parts.count >= 6 && parts[0] == "chromium-extension",
            "Chromium extension target IDs must include browser, window, tab, frame, and media components."
        )
        self.browserKey = parts[1]
        self.windowID = Int(parts[2])!
        self.tabID = Int(parts[3])!
        self.frameID = Int(parts[4])!
        self.mediaID = parts[5...].joined(separator: ":")
    }
}

private struct ChromiumBrowserExtensionSnapshotPayload: Decodable {
    let targets: [ChromiumBrowserExtensionTargetPayload]
}

private struct ChromiumBrowserExtensionTargetPayload: Decodable {
    let id: String
    let browser: String
    let url: String
    let pageTitle: String
    let title: String
    let artist: String
    let playing: Bool
    let duration: Double?
    let elapsedTime: Double?
    let supportedCommands: [String]

    var mediaRemoteTarget: MediaRemoteTarget {
        MediaRemoteTarget(
            id: id,
            bundleIdentifier: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            parentBundleIdentifier: "",
            displayName: ChromiumBrowserExtensionTransport.targetDisplayName(
                browser: browser,
                pageTitle: pageTitle
            ),
            pid: 0,
            title: title.isEmpty ? pageTitle : title,
            artist: artist.isEmpty ? url : artist,
            album: pageTitle,
            playbackRate: playing ? "1" : "0",
            mediaType: ChromiumBrowserExtensionTransport.mediaType,
            artworkBase64: nil,
            duration: duration,
            elapsedTime: elapsedTime,
            elapsedTimestamp: Date().timeIntervalSince1970,
            supportedCommands: supportedCommands.compactMap(MediaRemoteTransportCommand.init(rawValue:))
        )
    }
}
