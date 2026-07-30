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

        var supervisor = MediaRemoteHelperSupervisorState()
        precondition(!supervisor.shouldRun)
        precondition(!supervisor.canLaunch(hasOwnedProcesses: false))

        supervisor.start()
        precondition(supervisor.shouldRun)
        precondition(supervisor.relaunchPending)
        precondition(!supervisor.canLaunch(hasOwnedProcesses: true))
        precondition(supervisor.canLaunch(hasOwnedProcesses: false))
        supervisor.didLaunch()
        precondition(!supervisor.relaunchPending)

        supervisor.requestRelaunch()
        precondition(supervisor.relaunchPending)
        supervisor.stop()
        precondition(!supervisor.shouldRun)
        precondition(!supervisor.relaunchPending)
        supervisor.requestRelaunch()
        precondition(!supervisor.relaunchPending)
        precondition(!supervisor.canLaunch(hasOwnedProcesses: false))

        print("mediaremote_helper_pair_state=ok")
    }
}
