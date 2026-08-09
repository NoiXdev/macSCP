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

    /// Resolves the form's JUMP login set before a submit: fills the jump's
    /// four manual-looking credential fields from the set, or refuses.
    ///
    /// Returns `nil` (no-op) when the jump is off, when its login is manual,
    /// and while nothing is selected — Connect/Save are already disabled for
    /// that last case, so this is the defensive half rather than the only
    /// guard. Also `nil` when the jump's SOURCE is a saved connection:
    /// `resolveJumpSession` below owns that path, and a leftover dangling
    /// `jumpSelectedLoginSetID` from a Manual+Set pick made before the source
    /// was switched must not refuse a submit over a control session mode does
    /// not even render.
    ///
    /// **The eligibility check stays ABOVE the fill, and that order is the
    /// security property** (M28 final review, Critical): `isEligible` is asked
    /// first, so a non-SSH set's Keychain slot — a share's or a bucket's
    /// password — is never read into the jump's password field, and no later
    /// login-mode switch or save can carry it onto a bastion. Reversing the
    /// two lines would still refuse the submit and still be a credential leak.
    ///
    /// The check has to be made here at all because this path never consults
    /// `LoginResolver.resolveJump`, which makes the same refusal for a STORED
    /// binding: the fill below reads the set's slot itself and hands the
    /// values to `ConnectionViewModel.validateJump`, whose `.set` branch only
    /// checks that something is selected. Nor does the picker's own filter
    /// cover it — `ConnectionViewModel.beginEditing` restores
    /// `jumpSelectedLoginSetID` straight from the stored jump without
    /// resolving anything, so a binding that predates the filter reaches this
    /// fill unfiltered.
    public func resolveJumpLoginSet(form: ConnectionViewModel) -> SubmitRefusal? {
        guard form.jumpEnabled, form.jumpSourceMode != .session,
              form.jumpLoginMode == .set, let id = form.jumpSelectedLoginSetID
        else {
            return nil
        }
        guard let set = loginSets.first(where: { $0.id == id }) else {
            return .jumpSetMissing
        }
        guard JumpLoginSetEligibility.isEligible(set) else { return .jumpSetNotSSH }
        fillJumpForm(form, from: set)
        return nil
    }

    /// Copies a login set into the jump block's own fields — the jump's
    /// counterpart to the target's `applyResolvedCredentials`, filling
    /// `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/`jumpPassword` rather
    /// than the target's namespace.
    ///
    /// Callable only from `resolveJumpLoginSet` above, which is what
    /// establishes that the set may serve a jump at all: this body reads the
    /// set's Keychain slot unconditionally for a non-agent set, whatever
    /// `kind` says — the same split `LoginResolver.sshLogin(from:)` documents
    /// for its own two callers.
    ///
    /// The secret is read through a synthetic `StoredSession` carrying the
    /// SET's id: `password(for:)` addresses the Keychain by `id` alone, and
    /// `saveLoginSet` writes the set's secret under exactly that id, so no
    /// separate lookup API is needed. An agent set is skipped entirely rather
    /// than probed — it has no slot, because `saveLoginSet` deletes one.
    private func fillJumpForm(_ form: ConnectionViewModel, from set: LoginSet) {
        form.jumpUsername = set.username
        form.jumpAuthChoice = ConnectionViewModel.authChoice(for: set.authKind)
        form.jumpKeyPath = set.keyPath ?? ""
        guard set.authKind != .agent else {
            form.jumpPassword = ""
            return
        }
        let synthetic = StoredSession(id: set.id, name: set.name)
        form.jumpPassword = password(for: synthetic) ?? ""
    }

    /// Resolves the form's referenced JUMP CONNECTION before a submit: fills
    /// the jump's host, port and login from that resolution, or refuses.
    /// Same fill-before-submit shape as `resolveJumpLoginSet` above, sourced
    /// from a saved connection instead of a login set.
    ///
    /// Returns `nil` (no-op) when the jump is off, when its source is the
    /// manual block, and while nothing is selected. The four refusals are the
    /// resolver's own typed errors, classified rather than invented here; the
    /// `catch`-all covers a dangling login set on the REFERENCED connection
    /// (`.missingSet`) and any other resolution failure, which is why its case
    /// is named for the condition rather than for one error.
    ///
    /// No eligibility guard of its own sits above this fill: unlike the set
    /// half, this path reads no Keychain slot itself — `resolvedJump(for:)`
    /// does, and it refuses a non-SSH reference (`.jumpSessionNotSSH`) before
    /// reading anything.
    public func resolveJumpSession(form: ConnectionViewModel) -> SubmitRefusal? {
        guard form.jumpEnabled, form.jumpSourceMode == .session,
              let sessionID = form.jumpSessionID
        else {
            return nil
        }
        // The form's own session when editing, so the resolver can recognise a
        // self-reference; an unused fresh id for a connection that has none.
        let referencingID: UUID
        if case .edit(let id) = form.mode { referencingID = id } else { referencingID = UUID() }
        let spec = StoredSession.JumpSpec(host: "", username: "", sessionID: sessionID)
        let synthetic = StoredSession(
            id: referencingID, name: "",
            ssh: StoredSSHConfig(host: "", username: "", jump: spec))
        do {
            guard let resolved = try resolvedJump(for: synthetic) else { return nil }
            form.jumpHost = resolved.host
            form.jumpPort = String(resolved.port)
            form.jumpUsername = resolved.login.username
            form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolved.login.authKind)
            form.jumpKeyPath = resolved.login.keyPath ?? ""
            form.jumpPassword = resolved.login.secret ?? ""
            return nil
        } catch LoginResolveError.missingJumpSession {
            return .jumpSessionMissing
        } catch LoginResolveError.jumpChainNotSupported {
            return .jumpChainNotSupported
        } catch LoginResolveError.jumpSessionNotSSH {
            return .jumpSessionNotSSH
        } catch {
            return .jumpSessionLoginUnresolvable
        }
    }
}
