import Foundation

struct SonosSOAPClient {
    private let urlSession: URLSession

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    func call(host: String, service: String, action: String, path: String, body: String) async throws -> String {
        let envelope = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
        """

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 1400
        components.path = path
        guard let url = components.url else {
            throw ConnectHandoffError(.unsupported, "Invalid Sonos host: \(host)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await urlSession.data(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw ConnectHandoffError(.unsupported, "Sonos \(action) failed.")
        }
        return responseBody
    }
}
