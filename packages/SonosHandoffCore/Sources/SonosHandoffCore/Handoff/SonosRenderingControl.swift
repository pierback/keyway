import Foundation

struct SonosRenderingControl {
    private let soapClient: SonosSOAPClient

    init(soapClient: SonosSOAPClient) {
        self.soapClient = soapClient
    }

    func status(on target: ConnectSonosTarget) async throws -> SpeakerVolumeStatus {
        SpeakerVolumeStatus(
            roomName: target.roomName,
            host: target.host,
            volume: try await volume(on: target),
            outputFixed: try await outputFixed(on: target),
            muted: try await muted(on: target)
        )
    }

    func groupStatus(on target: ConnectSonosTarget) async throws -> SpeakerVolumeStatus {
        SpeakerVolumeStatus(
            roomName: target.roomName,
            host: target.host,
            volume: try await groupVolume(on: target),
            outputFixed: false,
            muted: try await groupMuted(on: target)
        )
    }

    func volumeDown(on target: ConnectSonosTarget, step: Int) async throws -> Int {
        let current = try await volume(on: target)
        return try await setVolume(on: target, to: current - clampedStep(step))
    }

    func volumeUp(on target: ConnectSonosTarget, step: Int) async throws -> Int {
        let current = try await volume(on: target)
        return try await setVolume(on: target, to: current + clampedStep(step))
    }

    func groupVolumeDown(on target: ConnectSonosTarget, step: Int) async throws -> Int {
        let current = try await groupVolume(on: target)
        return try await setGroupVolume(on: target, to: current - clampedStep(step))
    }

    func groupVolumeUp(on target: ConnectSonosTarget, step: Int) async throws -> Int {
        let current = try await groupVolume(on: target)
        return try await setGroupVolume(on: target, to: current + clampedStep(step))
    }

    func setVolume(on target: ConnectSonosTarget, to requestedVolume: Int) async throws -> Int {
        let volume = Self.clampVolume(requestedVolume)
        _ = try await call(action: "SetVolume", host: target.host, body: """
        <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(volume)</DesiredVolume></u:SetVolume>
        """)
        _ = try await setMute(on: target, to: false)
        return try await self.volume(on: target)
    }

    func setGroupVolume(on target: ConnectSonosTarget, to requestedVolume: Int) async throws -> Int {
        let volume = Self.clampVolume(requestedVolume)
        _ = try await groupCall(action: "SetGroupVolume", host: target.host, body: """
        <u:SetGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><InstanceID>0</InstanceID><DesiredVolume>\(volume)</DesiredVolume></u:SetGroupVolume>
        """)
        _ = try await setGroupMute(on: target, to: false)
        return try await groupVolume(on: target)
    }

    func toggleMute(on target: ConnectSonosTarget) async throws -> Bool {
        let muted = try await muted(on: target)
        return try await setMute(on: target, to: !muted)
    }

    func toggleGroupMute(on target: ConnectSonosTarget) async throws -> Bool {
        let muted = try await groupMuted(on: target)
        return try await setGroupMute(on: target, to: !muted)
    }

    func setMute(on target: ConnectSonosTarget, to muted: Bool) async throws -> Bool {
        let desiredMute = muted ? 1 : 0
        _ = try await call(action: "SetMute", host: target.host, body: """
        <u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(desiredMute)</DesiredMute></u:SetMute>
        """)
        return try await self.muted(on: target)
    }

    func setGroupMute(on target: ConnectSonosTarget, to muted: Bool) async throws -> Bool {
        let desiredMute = muted ? 1 : 0
        _ = try await groupCall(action: "SetGroupMute", host: target.host, body: """
        <u:SetGroupMute xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><InstanceID>0</InstanceID><DesiredMute>\(desiredMute)</DesiredMute></u:SetGroupMute>
        """)
        return try await groupMuted(on: target)
    }

    private func volume(on target: ConnectSonosTarget) async throws -> Int {
        let response = try await call(action: "GetVolume", host: target.host, body: """
        <u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume>
        """)

        guard let volume = SonosRuntimeSupport.firstMatch(#"<CurrentVolume>(\d+)</CurrentVolume>"#, in: response).flatMap(Int.init) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos volume.")
        }

        return volume
    }

    private func groupVolume(on target: ConnectSonosTarget) async throws -> Int {
        let response = try await groupCall(action: "GetGroupVolume", host: target.host, body: """
        <u:GetGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><InstanceID>0</InstanceID></u:GetGroupVolume>
        """)

        guard let volume = SonosRuntimeSupport.firstMatch(#"<CurrentVolume>(\d+)</CurrentVolume>"#, in: response).flatMap(Int.init) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos group volume.")
        }

        return volume
    }

    private func outputFixed(on target: ConnectSonosTarget) async throws -> Bool {
        let response = try await call(action: "GetOutputFixed", host: target.host, body: """
        <u:GetOutputFixed xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID></u:GetOutputFixed>
        """)

        guard let rawValue = SonosRuntimeSupport.firstMatch(#"<CurrentFixed>([01])</CurrentFixed>"#, in: response) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos fixed-output state.")
        }

        return rawValue == "1"
    }

    private func muted(on target: ConnectSonosTarget) async throws -> Bool {
        let response = try await call(action: "GetMute", host: target.host, body: """
        <u:GetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetMute>
        """)

        guard let rawValue = SonosRuntimeSupport.firstMatch(#"<CurrentMute>([01])</CurrentMute>"#, in: response) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos mute state.")
        }

        return rawValue == "1"
    }

    private func groupMuted(on target: ConnectSonosTarget) async throws -> Bool {
        let response = try await groupCall(action: "GetGroupMute", host: target.host, body: """
        <u:GetGroupMute xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><InstanceID>0</InstanceID></u:GetGroupMute>
        """)

        guard let rawValue = SonosRuntimeSupport.firstMatch(#"<CurrentMute>([01])</CurrentMute>"#, in: response) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos group mute state.")
        }

        return rawValue == "1"
    }

    private func call(action: String, host: String, body: String) async throws -> String {
        try await soapClient.call(
            host: host,
            service: "RenderingControl",
            action: action,
            path: "/MediaRenderer/RenderingControl/Control",
            body: body
        )
    }

    private func groupCall(action: String, host: String, body: String) async throws -> String {
        try await soapClient.call(
            host: host,
            service: "GroupRenderingControl",
            action: action,
            path: "/MediaRenderer/GroupRenderingControl/Control",
            body: body
        )
    }

    private func clampedStep(_ step: Int) -> Int {
        min(25, max(5, step))
    }

    private static func clampVolume(_ volume: Int) -> Int {
        min(100, max(0, volume))
    }
}
