import Foundation

enum SonosDNSSDRecordParser {
    private static let sonosServiceMarker = "_sonos._tcp."
    private static let locationHostPattern = #"location=http://([^:/\s]+):1400/"#

    static func instances(fromBrowseOutput output: String) -> [String] {
        output
            .split(separator: "\n")
            .compactMap { instance(fromBrowseLine: String($0)) }
            .uniqued { $0 }
            .sorted()
    }

    static func instance(fromBrowseLine line: String, matchingRoomName targetRoomName: String) -> String? {
        guard let instance = instance(fromBrowseLine: line),
              let instanceRoomName = roomName(fromInstance: instance),
              SonosRoomName.matches(instanceRoomName, targetRoomName)
        else {
            return nil
        }

        return instance
    }

    static func instance(fromBrowseLine line: String) -> String? {
        let parts = line.components(separatedBy: sonosServiceMarker)
        guard parts.count > 1,
              let instance = parts.last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty,
              roomName(fromInstance: instance) != nil
        else {
            return nil
        }

        return instance
    }

    static func roomName(fromInstance instance: String) -> String? {
        let parts = instance.components(separatedBy: "@")
        guard parts.count >= 2,
              let roomName = parts[1...]
            .joined(separator: "@")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            return nil
        }

        return DNSSDName.unescaped(roomName)
    }

    static func speakerID(fromInstance instance: String) -> String? {
        instance
            .components(separatedBy: "@")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func host(fromResolveOutput output: String) -> String? {
        SonosRuntimeSupport.firstMatch(locationHostPattern, in: output)
    }

    static func resolveOutputContainsHost(_ output: String) -> Bool {
        host(fromResolveOutput: output) != nil
    }
}
