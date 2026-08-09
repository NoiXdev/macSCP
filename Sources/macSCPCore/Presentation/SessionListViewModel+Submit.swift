import Foundation

extension SessionListViewModel {
    /// Resolves the form's TARGET login set before a submit: fills the
    /// credential fields from the set, or refuses.
    ///
    /// Returns `nil` outside Set mode and while nothing is selected — the
    /// submit buttons are already disabled for the latter, so this is the
    /// defensive half rather than the only guard.
    ///
    /// The `kind` check is new in M29-P2. Without it a set belonging to
    /// another protocol was accepted and its values written under that
    /// protocol's own field namespace, which the form never reads — harmless
    /// by coincidence rather than by rule: what actually keeps the two apart
    /// is each backend's own `namespace` string (e.g. `SSHField.namespace`),
    /// hand-written per backend and never checked for collisions against the
    /// others.
    public func resolveTargetLoginSet(form: ConnectionViewModel) -> SubmitRefusal? {
        guard form.loginMode == .set, let id = form.selectedLoginSetID else { return nil }
        guard let set = loginSets.first(where: { $0.id == id }) else {
            return .targetSetMissing
        }
        guard set.kind == form.kind else { return .targetSetKindMismatch }
        form.applyResolvedCredentials(credentials(of: set))
        return nil
    }
}
