import Foundation

@MainActor
final class MediaTransportTraceRecorder {
    private let runtimeStatus: ShortcutRuntimeStatus

    init(runtimeStatus: ShortcutRuntimeStatus = .shared) {
        self.runtimeStatus = runtimeStatus
    }

    func record(
        _ event: String,
        command: MediaRemoteTransportCommand?,
        source: MediaTransportRouteSource? = nil,
        target: MediaRemoteTarget? = nil,
        targets: [MediaRemoteTarget]? = nil,
        reason: String? = nil,
        transportBackend: String? = nil,
        targetCount: Int? = nil,
        mediaKeyMetadata: MediaTransportInputMetadata? = nil,
        commandCenterMetadata: MediaCommandCenterInputMetadata? = nil,
        overlayVisible: Bool,
        chooserActive: Bool,
        canRoute: Bool
    ) {
        var fields: [String: Any] = [
            "overlayVisible": overlayVisible,
            "chooserActive": chooserActive,
            "canRoute": canRoute,
        ]
        if let command {
            fields["command"] = command.rawValue
        }
        if let source {
            fields["source"] = source.rawValue
        }
        if let target {
            fields["target"] = target.appName
            fields["targetID"] = target.id
            fields["targetPlaying"] = target.isCurrentlyPlaying
        }
        if let reason {
            fields["reason"] = reason
        }
        if let transportBackend {
            fields["transportBackend"] = transportBackend
        }
        if let targetCount {
            fields["targetCount"] = targetCount
        }
        if let targets {
            fields["targets"] = targets.map { target in
                [
                    "id": target.id,
                    "app": target.appName,
                    "bundleIdentifier": target.bundleIdentifier,
                    "parentBundleIdentifier": target.parentBundleIdentifier,
                    "pid": target.pid,
                    "playing": target.isCurrentlyPlaying,
                    "playbackRate": target.playbackRate,
                    "title": target.title,
                    "artist": target.artist,
                    "freshness": target.playbackFreshness,
                ] as [String: Any]
            }
        }
        if let mediaKeyMetadata {
            fields["eventSourceUnixProcessID"] = mediaKeyMetadata.sourceUnixProcessID
            fields["eventSourceStateID"] = mediaKeyMetadata.sourceStateID
            fields["eventSourceUserData"] = mediaKeyMetadata.sourceUserData
            fields["eventTargetUnixProcessID"] = mediaKeyMetadata.targetUnixProcessID
            fields["eventSourceUserID"] = mediaKeyMetadata.sourceUserID
            fields["eventSourceGroupID"] = mediaKeyMetadata.sourceGroupID
            fields["eventTimestamp"] = mediaKeyMetadata.eventTimestamp
            fields["eventSourceIsPhysicalHIDSystem"] = mediaKeyMetadata.isPhysicalHIDSystemSource
            fields["eventSourceIsUntargetedPhysicalHIDSystem"] = mediaKeyMetadata.isUntargetedPhysicalHIDSystemSource
        }
        if let commandCenterMetadata {
            fields["commandCenterEventTimestamp"] = commandCenterMetadata.eventTimestamp
        }
        runtimeStatus.recordMediaTransportEvent(event, fields: fields)
    }

    func recordHelperResult(
        _ result: MediaRemoteCommandResultEvent,
        backend: String? = nil,
        overlayVisible: Bool,
        chooserActive: Bool,
        canRoute: Bool
    ) {
        var fields: [String: Any] = [
            "command": result.command,
            "requestID": result.requestID ?? "",
            "targetID": result.targetID,
            "ok": result.ok,
            "message": result.message,
            "overlayVisible": overlayVisible,
            "chooserActive": chooserActive,
            "canRoute": canRoute,
        ]
        if let backend = backend ?? result.backend {
            fields["transportBackend"] = backend
        }
        runtimeStatus.recordMediaTransportEvent(
            "helper_command_result",
            fields: fields
        )
    }
}
