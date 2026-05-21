import Foundation

struct SonosSpotifyMetadata: Sendable {
    let version: String
    let deviceID: String
}

struct SonosSpotifyZeroconfClient: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func info(host: String) async throws -> SonosSpotifyMetadata {
        let payload = try await request(host: host, parameters: ["action": "getInfo"])
        guard
            let version = payload["version"] as? String,
            let deviceID = payload["deviceID"] as? String
        else {
            throw ConnectHandoffError(.targetNotVisible, "Incomplete Sonos getInfo response.")
        }

        return SonosSpotifyMetadata(version: version, deviceID: deviceID)
    }

    func request(host: String, parameters: [String: String]) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 1400
        components.path = "/spotifyzc"

        let isGetInfo = parameters["action"] == "getInfo"

        if isGetInfo {
            components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw ConnectHandoffError(.unsupported, "Invalid Sonos host.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = isGetInfo ? "GET" : "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        if !isGetInfo {
            request.httpBody = SonosRuntimeSupport.formBody(parameters)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode),
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ConnectHandoffError(.unsupported, "Invalid zeroconf response.")
        }

        return payload
    }
}
