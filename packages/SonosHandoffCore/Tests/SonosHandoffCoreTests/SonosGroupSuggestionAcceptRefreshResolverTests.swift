import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionAcceptRefreshResolverTests {
    private let resolver = SonosGroupSuggestionAcceptRefreshResolver()

    @Test
    func clearsSelectionWhenPlaybackDisappearedAfterAcceptingSuggestion() {
        let plan = resolver.plan(
            activeRoomName: nil,
            outputSelectedRoomName: "Kitchen",
            fallbackRoomName: " Kitchen "
        )

        #expect(plan == SonosGroupSuggestionAcceptRefreshPlan(
            discoveryRoomName: "Kitchen",
            selectedRoomName: nil,
            menuRefreshRoomName: "Kitchen",
            spotifyPlaying: false,
            clearReason: .noActivePlayback
        ))
    }

    @Test
    func clearsSelectionWhenActiveSpotifyDeviceIsNotVisibleInSonosOutputs() {
        let plan = resolver.plan(
            activeRoomName: "Office",
            outputSelectedRoomName: nil,
            fallbackRoomName: "Kitchen"
        )

        #expect(plan == SonosGroupSuggestionAcceptRefreshPlan(
            discoveryRoomName: "Office",
            selectedRoomName: nil,
            menuRefreshRoomName: "Office",
            spotifyPlaying: true,
            clearReason: .activeDeviceNotVisible
        ))
    }

    @Test
    func keepsSelectedGroupWhenActiveSpotifyDeviceIsVisibleAfterGrouping() {
        let plan = resolver.plan(
            activeRoomName: "Kitchen",
            outputSelectedRoomName: " Kitchen + Port ",
            fallbackRoomName: "Office"
        )

        #expect(plan == SonosGroupSuggestionAcceptRefreshPlan(
            discoveryRoomName: "Kitchen",
            selectedRoomName: "Kitchen + Port",
            menuRefreshRoomName: "Kitchen + Port",
            spotifyPlaying: true,
            clearReason: nil
        ))
    }
}
