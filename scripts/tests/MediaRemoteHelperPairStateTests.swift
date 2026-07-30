@main
enum MediaRemoteHelperPairStateTests {
    static func main() {
        var state = MediaRemoteHelperPairState()

        precondition(!state.isReady)
        precondition(!state.markReady(.snapshot))
        precondition(!state.isReady)
        precondition(!state.markReady(.snapshot))
        precondition(state.markReady(.command))
        precondition(state.isReady)
        precondition(!state.markReady(.command))

        state.reset()
        precondition(!state.isReady)
        precondition(!state.markReady(.command))
        precondition(state.markReady(.snapshot))
        precondition(state.isReady)

        print("mediaremote_helper_pair_state=ok")
    }
}
