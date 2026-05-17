import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosRenderingControlTests {
    @Test
    func setMuteOnSendsDesiredMuteOneAndConfirmsState() async throws {
        RenderingControlURLProtocol.requests = []
        RenderingControlURLProtocol.currentMute = "1"
        let control = renderingControl()

        let muted = try await control.setMute(on: target(), to: true)

        #expect(muted)
        let setMuteRequest = try #require(RenderingControlURLProtocol.requests.first)
        #expect(setMuteRequest.url?.host == "port.local")
        #expect(setMuteRequest.url?.path == "/MediaRenderer/RenderingControl/Control")
        #expect(setMuteRequest.soapAction == "\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\"")
        #expect(setMuteRequest.body.contains("<DesiredMute>1</DesiredMute>"))
    }

    @Test
    func setMuteOffSendsDesiredMuteZeroAndConfirmsState() async throws {
        RenderingControlURLProtocol.requests = []
        RenderingControlURLProtocol.currentMute = "0"
        let control = renderingControl()

        let muted = try await control.setMute(on: target(), to: false)

        #expect(!muted)
        let setMuteRequest = try #require(RenderingControlURLProtocol.requests.first)
        #expect(setMuteRequest.soapAction == "\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\"")
        #expect(setMuteRequest.body.contains("<DesiredMute>0</DesiredMute>"))
    }

    @Test
    func setGroupVolumeUsesGroupRenderingControlOnCoordinator() async throws {
        RenderingControlURLProtocol.requests = []
        RenderingControlURLProtocol.currentGroupVolume = "24"
        let control = renderingControl()

        let volume = try await control.setGroupVolume(on: target(), to: 25)

        #expect(volume == 24)
        let setVolumeRequest = try #require(RenderingControlURLProtocol.requests.first)
        #expect(setVolumeRequest.url?.host == "port.local")
        #expect(setVolumeRequest.url?.path == "/MediaRenderer/GroupRenderingControl/Control")
        #expect(setVolumeRequest.soapAction == "\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetGroupVolume\"")
        #expect(setVolumeRequest.body.contains("<DesiredVolume>25</DesiredVolume>"))
    }

    @Test
    func groupStatusReadsGroupVolumeAndMute() async throws {
        RenderingControlURLProtocol.requests = []
        RenderingControlURLProtocol.currentGroupVolume = "31"
        RenderingControlURLProtocol.currentGroupMute = "1"
        let control = renderingControl()

        let status = try await control.groupStatus(on: target())

        #expect(status.roomName == "Port")
        #expect(status.volume == 31)
        #expect(status.muted)
        #expect(status.outputFixed == false)
        #expect(RenderingControlURLProtocol.requests.map(\.soapAction).contains("\"urn:schemas-upnp-org:service:GroupRenderingControl:1#GetGroupVolume\""))
        #expect(RenderingControlURLProtocol.requests.map(\.soapAction).contains("\"urn:schemas-upnp-org:service:GroupRenderingControl:1#GetGroupMute\""))
    }

    private func renderingControl() -> SonosRenderingControl {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RenderingControlURLProtocol.self]
        return SonosRenderingControl(
            soapClient: SonosSOAPClient(urlSession: URLSession(configuration: configuration))
        )
    }

    private func target() -> ConnectSonosTarget {
        ConnectSonosTarget(roomName: "Port", host: "port.local", version: nil, deviceID: "RINCON_PORT")
    }
}

private struct RenderingControlRequest: Sendable {
    let url: URL?
    let soapAction: String?
    let body: String
}

private final class RenderingControlURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [RenderingControlRequest] = []
    nonisolated(unsafe) static var currentMute = "0"
    nonisolated(unsafe) static var currentGroupVolume = "20"
    nonisolated(unsafe) static var currentGroupMute = "0"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(from: request)
        Self.requests.append(
            RenderingControlRequest(
                url: request.url,
                soapAction: request.value(forHTTPHeaderField: "SOAPACTION"),
                body: body
            )
        )

        let responseBody: String
        if request.value(forHTTPHeaderField: "SOAPACTION")?.contains("#GetGroupVolume") == true {
            responseBody = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetGroupVolumeResponse xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><CurrentVolume>\(Self.currentGroupVolume)</CurrentVolume></u:GetGroupVolumeResponse></s:Body></s:Envelope>
            """
        } else if request.value(forHTTPHeaderField: "SOAPACTION")?.contains("#GetGroupMute") == true {
            responseBody = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetGroupMuteResponse xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><CurrentMute>\(Self.currentGroupMute)</CurrentMute></u:GetGroupMuteResponse></s:Body></s:Envelope>
            """
        } else if request.value(forHTTPHeaderField: "SOAPACTION")?.contains("#GetMute") == true {
            responseBody = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetMuteResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><CurrentMute>\(Self.currentMute)</CurrentMute></u:GetMuteResponse></s:Body></s:Envelope>
            """
        } else {
            responseBody = "<ok/>"
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
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
