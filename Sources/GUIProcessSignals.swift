import Darwin

enum GUIProcessSignals {
    /// The GUI must outlive an automation launcher's output reader. A broken
    /// pipe or socket should fail its write with EPIPE, not terminate DeskLift.
    /// Install before the app delegate and its background work are created.
    /// CLI entry points deliberately do not call this policy.
    @discardableResult
    static func configure() -> Bool {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        return sigaction(SIGPIPE, &action, nil) == 0
    }
}
