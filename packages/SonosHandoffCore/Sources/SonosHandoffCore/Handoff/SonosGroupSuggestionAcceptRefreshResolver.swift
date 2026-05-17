public enum SonosGroupSuggestionAcceptClearReason: String, Equatable, Sendable {
    case noActivePlayback = "grouping_no_active_playback"
    case activeDeviceNotVisible = "grouping_active_device_not_visible"
}

public struct SonosGroupSuggestionAcceptRefreshPlan: Equatable, Sendable {
    public let discoveryRoomName: String
    public let selectedRoomName: String?
    public let menuRefreshRoomName: String
    public let spotifyPlaying: Bool
    public let clearReason: SonosGroupSuggestionAcceptClearReason?

    public init(
        discoveryRoomName: String,
        selectedRoomName: String?,
        menuRefreshRoomName: String,
        spotifyPlaying: Bool,
        clearReason: SonosGroupSuggestionAcceptClearReason?
    ) {
        self.discoveryRoomName = discoveryRoomName
        self.selectedRoomName = selectedRoomName
        self.menuRefreshRoomName = menuRefreshRoomName
        self.spotifyPlaying = spotifyPlaying
        self.clearReason = clearReason
    }
}

public struct SonosGroupSuggestionAcceptRefreshResolver: Sendable {
    public init() {}

    public func plan(
        activeRoomName: String?,
        outputSelectedRoomName: String?,
        fallbackRoomName: String
    ) -> SonosGroupSuggestionAcceptRefreshPlan {
        let fallbackRoomName = SonosRoomName.normalized(fallbackRoomName) ?? fallbackRoomName
        guard let activeRoomName = SonosRoomName.normalized(activeRoomName) else {
            return SonosGroupSuggestionAcceptRefreshPlan(
                discoveryRoomName: fallbackRoomName,
                selectedRoomName: nil,
                menuRefreshRoomName: fallbackRoomName,
                spotifyPlaying: false,
                clearReason: .noActivePlayback
            )
        }

        let selectedRoomName = SonosRoomName.normalized(outputSelectedRoomName)
        return SonosGroupSuggestionAcceptRefreshPlan(
            discoveryRoomName: activeRoomName,
            selectedRoomName: selectedRoomName,
            menuRefreshRoomName: selectedRoomName ?? activeRoomName,
            spotifyPlaying: true,
            clearReason: selectedRoomName == nil ? .activeDeviceNotVisible : nil
        )
    }
}
