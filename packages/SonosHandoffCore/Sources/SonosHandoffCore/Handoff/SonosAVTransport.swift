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
