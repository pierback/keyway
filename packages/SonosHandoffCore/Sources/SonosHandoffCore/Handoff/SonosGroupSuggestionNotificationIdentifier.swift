public enum SonosGroupSuggestionNotificationIdentifier: Sendable {
    private static let suggestionPrefix = "group-suggestion-"
    private static let failurePrefix = "group-suggestion-failure-"

    public static func suggestionID(_ suggestionID: String) -> String {
        "\(suggestionPrefix)\(speakerID(in: suggestionID))"
    }

    public static func failureID(_ suggestionID: String) -> String {
        "\(failurePrefix)\(speakerID(in: suggestionID))"
    }

    public static func allIDs(_ id: String) -> [String] {
        [
            suggestionID(id),
            failureID(id),
        ]
    }

    public static func allIDs(_ suggestionIDs: Set<String>) -> [String] {
        suggestionIDs
            .flatMap(allIDs)
            .uniqued { $0 }
    }

    private static func speakerID(in suggestionID: String) -> String {
        guard let separator = suggestionID.firstIndex(of: "|") else {
            return suggestionID
        }

        return String(suggestionID[..<separator])
    }
}
