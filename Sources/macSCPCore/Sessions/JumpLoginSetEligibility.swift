import Foundation

/// Which login sets are valid picks for the jump block's "use a stored login"
/// picker (M28/T6). A jump is an SSH hop — `LoginResolver.resolveJump` reads a
/// set-bound spec through its private `sshLogin(from:)`, which takes the set's
/// `username`, `authKind` and `keyPath`, and `ConnectionViewModel.
/// buildJumpConfig` turns those into an `SSHConnectionConfig.Jump`, a type
/// with a host, a port, a username and an `AuthMethod` and no notion of any
/// other backend. A set whose `kind` is not `.ssh` therefore describes
/// credentials nothing on that path can use. The target's own picker in
/// `ConnectionFormView.loginSetPicker(for:)` has filtered on `kind` since
/// M23/T7; this is the same rule for the jump's picker, which did not.
///
/// The order the caller passes in is preserved: the jump picker never sorted,
/// and `JumpSessionEligibility`'s sidebar-style sort is not carried over
/// merely because the two enums are neighbours.
///
/// This filter alone is not the fix. It only shapes what the picker offers
/// FROM NOW ON; a `jump.loginSetID` already pointing at a non-SSH set stays on
/// disk, and the deletion it could provoke is stopped by
/// `SessionListViewModel.jumpSetDemonstrablyCoversItsLogin`, which asks the
/// same `kind` question before it lets the old bastion slot go — the same
/// split `JumpSessionEligibility` documents for saved connections.
public enum JumpLoginSetEligibility {
    /// Whether ONE set may serve a jump. The picker filters with it; the App's
    /// fill-before-submit path asks it about the set it is about to copy
    /// credentials out of, where a binding that predates the filter (or that
    /// an import turned into another kind under the same id) arrives
    /// unfiltered.
    public static func isEligible(_ set: LoginSet) -> Bool {
        set.kind == .ssh
    }

    public static func eligible(in sets: [LoginSet]) -> [LoginSet] {
        sets.filter(isEligible)
    }
}
