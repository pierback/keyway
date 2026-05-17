public enum SonosGroupSuggestionNotificationIdentifier: Sendable {
    private static let suggestionPrefix = "group-suggestion-"
    private static let failurePrefix = "group-suggestion-failure-"

    public static func suggestionID(_ suggestionID: String) -> String {
        "\(suggestionPrefix)\(suggestionID)"
    }

    public static func failureID(_ suggestionID: String) -> String {
        "\(failurePrefix)\(suggestionID)"
    }

    public static func isSuggestionID(_ identifier: String) -> Bool {
        identifier.hasPrefix(suggestionPrefix) && !identifier.hasPrefix(failurePrefix)
    }

    public static func matchesSuggestionID(_ notificationIdentifier: String, ids: Set<String>) -> Bool {
        guard isSuggestionID(notificationIdentifier) else {
            return false
        }

        let suggestionID = String(notificationIdentifier.dropFirst(suggestionPrefix.count))
        let notificationSpeakerID = speakerID(in: suggestionID)
        return ids.contains(suggestionID)
            || ids.contains(notificationSpeakerID)
            || ids.contains { speakerID(in: $0) == notificationSpeakerID }
    }

    private static func speakerID(in suggestionID: String) -> String {
        guard let separator = suggestionID.firstIndex(of: "|") else {
            return suggestionID
        }

        return String(suggestionID[..<separator])
    }
}
