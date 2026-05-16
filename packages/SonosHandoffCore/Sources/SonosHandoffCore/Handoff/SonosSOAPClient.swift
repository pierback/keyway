import Foundation

struct SonosSOAPClient {
    private let urlSession: URLSession

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func call(host: String, service: String, action: String, path: String, body: String) async throws -> String {
        let envelope = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
        """
        var request = URLRequest(url: URL(string: "http://\(host):1400\(path)")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await urlSession.data(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw ConnectHandoffError(.unsupported, "Sonos \(action) failed: \(responseBody)")
        }
        return responseBody
    }
}
