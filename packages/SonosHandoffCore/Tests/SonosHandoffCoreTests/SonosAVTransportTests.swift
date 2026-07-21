import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosAVTransportTests {
    @Test
    func joinUsesCoordinatorRinconURIOnJoiningSpeaker() async throws {
        let transport = makeTransport()

        try await transport.join(
            target: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT"),
            coordinator: ConnectSonosTarget(roomName: "Kitchen", host: "kitchen.local", version: nil, deviceID: "RINCON_KITCHEN")
        )

        let request = try #require(AVTransportURLProtocol.snapshot().first)
        #expect(request.url?.host == "port.local")
        #expect(request.url?.path == "/MediaRenderer/AVTransport/Control")
        #expect(request.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        #expect(request.body.contains("<CurrentURI>x-rincon:RINCON_KITCHEN</CurrentURI>"))
    }

    @Test
    func becomeStandaloneUsesAVTransportStandaloneAction() async throws {
        let transport = makeTransport()

        try await transport.becomeStandalone(
            target: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT")
        )

        let request = try #require(AVTransportURLProtocol.snapshot().first)
        #expect(request.url?.host == "port.local")
        #expect(request.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")
        #expect(request.body.contains("<u:BecomeCoordinatorOfStandaloneGroup"))
    }

    @Test
    func statusReadsAndDecodesMediaURIAndTransportState() async throws {
        let transport = makeTransport()

        let status = try await transport.status(
            on: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT")
        )

        #expect(status.currentURI == "x-sonos-vli:spotify%3atrack%3a123&flags=32")
        #expect(status.transportState == "PLAYING")
        #expect(AVTransportURLProtocol.snapshot().count == 2)
    }

    @Test
    func currentURIFailsWhenMediaInfoOmitsCurrentURI() async throws {
        let transport = makeTransport(mediaInfoPayload: "<ok/>")

        do {
            _ = try await transport.currentURI(
                on: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT")
            )
            Issue.record("Expected missing CurrentURI to fail.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .unsupported)
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }
    }

    @Test
    func currentURIAllowsAnEmptyCurrentURIElement() async throws {
        let transport = makeTransport(mediaInfoPayload: "<CurrentURI></CurrentURI>")

        let currentURI = try await transport.currentURI(
            on: ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT")
        )

        #expect(currentURI.isEmpty)
    }

    private func makeTransport(
        mediaInfoPayload: String = "<CurrentURI>x-sonos-vli:spotify%3atrack%3a123&amp;flags=32</CurrentURI>"
    ) -> SonosAVTransport {
        AVTransportURLProtocol.reset(mediaInfoPayload: mediaInfoPayload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AVTransportURLProtocol.self]

        return SonosAVTransport(
            soapClient: SonosSOAPClient(urlSession: URLSession(configuration: configuration))
        )
    }
}

private struct AVTransportRequest: Sendable {
    let url: URL?
    let soapAction: String?
    let body: String
}

private final class AVTransportURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var mediaInfoPayload = ""
    private nonisolated(unsafe) static var requests: [AVTransportRequest] = []

    static func reset(mediaInfoPayload: String) {
        lock.withLock {
            self.mediaInfoPayload = mediaInfoPayload
            requests = []
        }
    }

    static func snapshot() -> [AVTransportRequest] {
        lock.withLock {
            requests
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(from: request)
        Self.append(
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
        let payload: String
        if request.value(forHTTPHeaderField: "SOAPACTION")?.contains("#GetMediaInfo") == true {
            payload = Self.currentMediaInfoPayload()
        } else if request.value(forHTTPHeaderField: "SOAPACTION")?.contains("#GetTransportInfo") == true {
            payload = "<CurrentTransportState>PLAYING</CurrentTransportState>"
        } else {
            payload = "<ok/>"
        }
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func append(_ request: AVTransportRequest) {
        lock.withLock {
            requests.append(request)
        }
    }

    private static func currentMediaInfoPayload() -> String {
        lock.withLock {
            mediaInfoPayload
        }
    }

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
