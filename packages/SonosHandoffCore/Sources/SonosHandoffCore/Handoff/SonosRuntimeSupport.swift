import CryptoKit
import Foundation

enum SonosRuntimeSupport {
    static func isSpotifyAuthFailure(statusCode: Int, payload: [String: Any]?) -> Bool {
        guard statusCode == 400 || statusCode == 401 || statusCode == 403 else {
            return false
        }

        guard let error = payload?["error"] as? String else {
            return statusCode == 401 || statusCode == 403
        }

        return ["invalid_grant", "invalid_client", "invalid_token", "unauthorized_client"].contains(error)
    }

    static func formBody(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))

        return Data(parameters.map {
            let key = $0.key.addingPercentEncoding(withAllowedCharacters: allowed)!
            let value = $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!

            return "\(key)=\(value)"
        }.sorted().joined(separator: "&").utf8)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func loginID(fromDesktopTokenKey key: String) -> String? {
        guard let loginID = key.split(separator: "/").last.map(String.init), !loginID.isEmpty else {

            return nil
        }

        return loginID
    }

    static func xmlUnescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension Sequence {
    func uniqued<ID: Hashable>(by id: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        var values: [Element] = []
        for element in self where seen.insert(id(element)).inserted {
            values.append(element)
        }
        return values
    }
}
