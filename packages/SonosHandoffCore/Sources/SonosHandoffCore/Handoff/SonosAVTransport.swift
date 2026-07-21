import Foundation

struct SonosAVTransport {
    private let soapClient: SonosSOAPClient

    init(soapClient: SonosSOAPClient) {
        self.soapClient = soapClient
    }

    func join(target: ConnectSonosTarget, coordinator: ConnectSonosTarget) async throws {
        let coordinatorID = SonosSOAPClient.xmlEscape(coordinator.deviceID ?? coordinator.roomName)
        _ = try await call(host: target.host, action: "SetAVTransportURI", body: """
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>x-rincon:\(coordinatorID)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI>
        """)
    }

    func becomeStandalone(target: ConnectSonosTarget) async throws {
        _ = try await call(host: target.host, action: "BecomeCoordinatorOfStandaloneGroup", body: """
        <u:BecomeCoordinatorOfStandaloneGroup xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:BecomeCoordinatorOfStandaloneGroup>
        """)
    }

    func play(on target: ConnectSonosTarget) async throws {
        _ = try await call(host: target.host, action: "Play", body: """
        <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>
        """)
    }

    func status(on target: ConnectSonosTarget) async throws -> (currentURI: String, transportState: String) {
        async let currentURI = currentURI(on: target)
        async let transportState = transportState(on: target)
        let status = try await (currentURI, transportState)
        guard let transportState = status.1 else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos transport status.")
        }

        return (status.0, transportState)
    }

    func currentURI(on target: ConnectSonosTarget) async throws -> String {
        let mediaInfo = try await call(host: target.host, action: "GetMediaInfo", body: """
        <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetMediaInfo>
        """)
        guard let currentURI = SonosRuntimeSupport.firstMatch(#"<CurrentURI>([^<]*)</CurrentURI>"#, in: mediaInfo) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos media URI.")
        }

        return SonosRuntimeSupport.xmlUnescape(currentURI)
    }

    func transportState(on target: ConnectSonosTarget) async throws -> String? {
        let transportInfo = try await call(host: target.host, action: "GetTransportInfo", body: """
        <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo>
        """)

        return SonosRuntimeSupport.firstMatch(#"<CurrentTransportState>([^<]*)</CurrentTransportState>"#, in: transportInfo)
    }

    private func call(host: String, action: String, body: String) async throws -> String {
        try await soapClient.call(
            host: host,
            service: "AVTransport",
            action: action,
            path: "/MediaRenderer/AVTransport/Control",
            body: body
        )
    }
}
