import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosAVTransportTests {
    @Test
    func joinUsesCoordinatorRinconURIOnJoiningSpeaker() async throws {
        AVTransportURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AVTransportURLProtocol.self]
        let transport = SonosAVTransport(
            soapClient: SonosSOAPClient(urlSession: URLSession(configuration: configuration))
        )

        try await transport.join(
            target: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT"),
            coordinator: ConnectSonosTarget(roomName: "Kitchen", host: "kitchen.local", version: nil, deviceID: "RINCON_KITCHEN")
        )

        let request = try #require(AVTransportURLProtocol.requests.first)
        #expect(request.url?.host == "port.local")
        #expect(request.url?.path == "/MediaRenderer/AVTransport/Control")
        #expect(request.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        #expect(request.body.contains("<CurrentURI>x-rincon:RINCON_KITCHEN</CurrentURI>"))
    }

    @Test
    func becomeStandaloneUsesAVTransportStandaloneAction() async throws {
        AVTransportURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AVTransportURLProtocol.self]
        let transport = SonosAVTransport(
            soapClient: SonosSOAPClient(urlSession: URLSession(configuration: configuration))
        )

        try await transport.becomeStandalone(
            target: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT")
        )

        let request = try #require(AVTransportURLProtocol.requests.first)
        #expect(request.url?.host == "port.local")
        #expect(request.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")
        #expect(request.body.contains("<u:BecomeCoordinatorOfStandaloneGroup"))
    }
}

private struct AVTransportRequest: Sendable {
    let url: URL?
    let soapAction: String?
    let body: String
}

private final class AVTransportURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [AVTransportRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(from: request)
        Self.requests.append(
            AVTransportRequest(
                url: request.url,
                soapAction: request.value(forHTTPHeaderField: "SOAPACTION"),
                body: body
            )
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<ok/>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(from request: URLRequest) -> String {
        if let httpBody = request.httpBody {
            return String(data: httpBody, encoding: .utf8) ?? ""
        }

        guard let bodyStream = request.httpBodyStream else {
            return ""
        }

        bodyStream.open()
        defer { bodyStream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while bodyStream.hasBytesAvailable {
            let count = bodyStream.read(buffer, maxLength: bufferSize)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
