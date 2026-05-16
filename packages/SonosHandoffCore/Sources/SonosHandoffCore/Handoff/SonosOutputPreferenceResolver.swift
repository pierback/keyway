import Foundation

public struct SonosOutputPreferenceResolver: Sendable {
    public static let fallbackRoomName = "Port"

    public init() {}

    public func target(alias: String, in config: AppConfig) -> SavedTarget? {
        config.targets.first { target in
            aliasesMatch(target.alias, alias)
        }
    }

    public func preferredRoomNames(in config: AppConfig?) -> [String] {
        guard let config else {
            return [Self.fallbackRoomName]
        }

        var roomNames: [String] = []
        if let portRoomName = target(alias: "port", in: config)?.spotifyDeviceName {
            roomNames.append(portRoomName)
        }
        if let firstRoomName = config.targets.first?.spotifyDeviceName {
            roomNames.append(firstRoomName)
        }
        roomNames.append(Self.fallbackRoomName)

        return roomNames.uniqued { roomName in
            SonosRoomName.normalized(roomName)?.lowercased() ?? ""
        }
        .compactMap(SonosRoomName.normalized)
    }

    public func preferredRoomName(selectedRoomName: String?, config: AppConfig?) -> String {
        if let selectedRoomName = SonosRoomName.normalized(selectedRoomName) {
            return selectedRoomName
        }

        return preferredRoomNames(in: config).first ?? Self.fallbackRoomName
    }

    private func aliasesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
