import AppKit

/// Every real-world way a transport command reaches Keyway. To find or change how one behaves:
/// its entry point is documented here, it is classified only by `init(mediaRemoteSenderID:)`, and
/// `MediaTransportActionController.routeFromCache` switches over it once.
enum MediaTransportTrigger: String {
    /// Keyboard media keys and Shift+fn+F7–F9, including synthetic keys posted by BetterTouchTool or Karabiner.
    /// Enters: `ShortcutEventTap` → `VolumeHotkeyController.handle` → `MediaTransportActionController.routeFromMediaKey`.
    case mediaKey = "media_key"
    /// MediaRemote commands from Apple senders: AirPods/headset buttons, Control Center, Touch Bar, and the
    /// pause macOS sends when headphones disconnect.
    /// Enters: `MediaCommandCenterInterceptor` → `MediaTransportActionController.routeFromCommandCenter`.
    case systemRemote = "system_remote"
    /// MediaRemote commands from third-party apps, e.g. Superwhisper pausing media while it records.
    /// Enters like `systemRemote`.
    case appAutomation = "app_automation"
    /// The menu bar's choose-source action or its Settings → Shortcuts binding.
    /// Enters: `KeywayStatusItemController` or `GlobalShortcutController` → `MediaTransportActionController.showTargetChooser`.
    case explicitChooser = "explicit_chooser"

    /// `senderID` is MediaRemote's kMRMediaRemoteOptionSenderID description string:
    /// "SenderDevice = <Mac>, SenderBundleIdentifier = <...>, SenderPID = <123>".
    /// Classify inside the MediaRemote handler; short-lived senders exit right after sending.
    init(mediaRemoteSenderID senderID: String?) {
        let senderName = senderID?.components(separatedBy: "SenderBundleIdentifier = <").dropFirst().first
            .map { String($0.prefix { $0 != ">" }) }
        let senderPID = senderID?.components(separatedBy: "SenderPID = <").dropFirst().first
            .flatMap { pid_t($0.prefix(while: \.isNumber)) }
        // Since macOS 15.4 third-party apps such as Superwhisper reach MediaRemote through Apple's
        // /usr/bin/perl (mediaremote-adapter), which exits before its parent app can be resolved.
        let bundleIdentifier = senderName == "perl"
            ? senderName
            : senderPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        self = bundleIdentifier.map { !$0.hasPrefix("com.apple.") && $0 != Bundle.main.bundleIdentifier } == true
            ? .appAutomation
            : .systemRemote
    }

    var source: MediaTransportRouteSource {
        switch self {
        case .mediaKey:
            return .eventTap
        case .systemRemote, .appAutomation:
            return .commandCenter
        case .explicitChooser:
            return .userInterface
        }
    }
}

enum MediaTransportRouteSource: String {
    case eventTap = "event_tap"
    case commandCenter = "command_center"
    case userInterface = "user_interface"
}

struct MediaTransportInputMetadata: Equatable {
    let sourceUnixProcessID: Int64
    let sourceStateID: Int64
    let sourceUserData: Int64
    let targetUnixProcessID: Int64
    let sourceUserID: Int64
    let sourceGroupID: Int64
    let eventTimestamp: UInt64

    init(
        sourceUnixProcessID: Int64,
        sourceStateID: Int64,
        sourceUserData: Int64,
        targetUnixProcessID: Int64 = 0,
        sourceUserID: Int64 = 0,
        sourceGroupID: Int64 = 0,
        eventTimestamp: UInt64 = 0
    ) {
        self.sourceUnixProcessID = sourceUnixProcessID
        self.sourceStateID = sourceStateID
        self.sourceUserData = sourceUserData
        self.targetUnixProcessID = targetUnixProcessID
        self.sourceUserID = sourceUserID
        self.sourceGroupID = sourceGroupID
        self.eventTimestamp = eventTimestamp
    }

    var isPhysicalHIDSystemSource: Bool {
        sourceStateID == 1
            && sourceUserData == 0
    }

    var isUntargetedPhysicalHIDSystemSource: Bool {
        isPhysicalHIDSystemSource && targetUnixProcessID == 0
    }

    func matchesSameGeneratedMediaKey(as other: MediaTransportInputMetadata) -> Bool {
        guard eventTimestamp != 0,
              other.eventTimestamp != 0,
              eventTimestampsMatch(eventTimestamp, other.eventTimestamp)
        else {
            return false
        }

        return sourceUnixProcessID == other.sourceUnixProcessID
            && sourceStateID == other.sourceStateID
            && sourceUserData == other.sourceUserData
            && sourceUserID == other.sourceUserID
            && sourceGroupID == other.sourceGroupID
    }

    private func eventTimestampsMatch(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        let delta = lhs > rhs ? lhs - rhs : rhs - lhs
        return delta <= 1_000_000
    }
}

struct MediaCommandCenterInputMetadata: Equatable {
    let eventTimestamp: TimeInterval

    func matchesSameCommandCenterEvent(as other: MediaCommandCenterInputMetadata) -> Bool {
        guard eventTimestamp > 0, other.eventTimestamp > 0 else {
            return false
        }
        return abs(eventTimestamp - other.eventTimestamp) <= 0.001
    }
}
