import Citadel
import Foundation
import Observation

/// Whether a failed dial is worth repeating unattended (connection-liveness
/// plan, Task 7) — `ConnectionViewModel.lastFailureKind`'s type. Two cases,
/// because that is the whole question the reconnect policy asks: repeating
/// an attempt that stopped at a host-key decision or a missing key
/// passphrase would only raise the same question again, on a schedule, with
/// nobody necessarily watching.
///
/// Lives in Core, next to the form that produces it, rather than in the App
/// that reads it: the classification is over Core's own error types (see
/// `ConnectionViewModel.failureKind(for:)`), and an App-side reading of
/// `state`'s localized message or form field could not tell a mismatched
/// host key from an ordinary timeout.
public enum ConnectFailureKind: Equatable, Sendable {
    /// A person has to answer or supply something before another attempt
    /// can differ from this one. **The default**, and deliberately so: an
    /// unattended retry is the dangerous direction, so a failure has to
    /// EARN the right to be repeated rather than fall into it. Every
    /// refusal that happens before the dial is one of these by
    /// construction — the inputs are a pure function of the form and the
    /// stores, and nothing about them changes without a person doing
    /// something. (Something else may well change them: a login set
    /// repaired in another window, a keychain unlocked meanwhile. Both are
    /// a person acting, which is exactly the state this case is named for —
    /// and the surface's manual Reconnect is how they say so.)
    case needsPerson
    /// A dial that reached the wire and failed there — a timeout, a refused
    /// connection, a host still booting. The only case an unattended retry
    /// is for, and the only one anything has to opt into (see
    /// `ConnectionViewModel.failureKind(for:)`).
    case other
}

/// State and logic of the connection form.
/// The connector is injectable: production uses CitadelFileSystem.connect,
/// tests use a mock — the view model stays testable without a network.
@Observable
@MainActor
public final class ConnectionViewModel {
    /// Which form row to outline for a failure.
    ///
    /// Backend fields are addressed by their NAMESPACED `FieldValues` key
    /// (M23) rather than by a case each: the set of fields is data now, and an
    /// enum case per field would be exactly the per-protocol code this
    /// milestone removes — which is also why S3 and WebDAV rows never
    /// highlighted before, the App's key mapping hardcoded SSH's namespace.
    ///
    /// The remaining cases are FORM rules, not backend fields: the save name
    /// is form bookkeeping, and the jump block is a second login with no
    /// schema of its own.
    public enum Field: Equatable, Sendable {
        /// A backend field, e.g. `.schema("SSHField.host")`.
        case schema(String)
        case saveName
        /// Jump-host fields (M10c/T3) — highlighted while the jump block is
        /// enabled and one of its own values fails validation.
        case jumpHost
        case jumpPort
        case jumpUsername
        case jumpPassword
        case jumpKeyPath
        /// The jump-source session picker (M11a/T3) — highlighted when the
        /// jump is enabled, in "session" mode, and nothing is selected yet.
        case jumpSession
    }

    /// An SSH field as a `Field.schema` key (M23) — the namespaced form
    /// `SchemaFormView` matches its rows against. Spelled once here so
    /// `failedState`'s `ConfigError` mappings, the remaining SSH-only
    /// failure site, cannot drift from the key the schema actually stores
    /// the value under.
    static func sshField(_ field: SSHField) -> Field {
        .schema("\(SSHField.namespace).\(field.rawValue)")
    }

    /// An S3 field as a `Field.schema` key, derived exactly like
    /// `sshField` above — for the bucket-list outcomes below, which are the
    /// only S3 failures `failedState` attributes to a row.
    static func s3Field(_ field: S3Field) -> Field {
        .schema("\(S3Field.namespace).\(field.rawValue)")
    }

    /// `Sendable` spelled out, like every other nested type here that is
    /// handed around: both payloads are value types that already are, and
    /// under the Swift 6 language mode the enclosing `@MainActor` no longer
    /// carries down to a nested type to supply the conformance implicitly.
    /// Without it the App's tests could no longer pass a `State` to a test
    /// case, which is how the omission surfaced.
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case failed(message: String, field: Field?)
    }

    /// Auth choice in the form. In key mode, `password` serves as the
    /// passphrase; agent mode (M10d) needs neither password nor key path.
    public enum AuthChoice: String, CaseIterable, Sendable {
        case password
        case privateKey
        case agent
    }

    /// The form's three-way login switcher (M10b/T3, mockup section 3):
    /// `.set` picks a reusable `LoginSet` instead of entering credentials
    /// directly; `.manual` is today's behavior (username/password/key
    /// entered on the connection itself). Default `.manual` — a brand-new
    /// form starts exactly as it always has.
    public enum LoginMode: String, CaseIterable, Sendable {
        case set
        case manual
    }

    /// The jump block's own source switcher (M11a/T3): `.session` points the
    /// jump at a SAVED connection by reference (`jumpSessionID`) instead of
    /// its own manual/set credentials; `.manual` is today's behavior (the
    /// jump's own host/port + three-way login). Default `.manual` — an
    /// existing manual/set jump, or a brand-new one, behaves exactly as
    /// before this feature existed.
    public enum JumpSourceMode: String, CaseIterable, Sendable {
        case session
        case manual
    }

    /// Whether the form creates a brand-new connection or edits a stored
    /// session in place (M5f/T4). `edit` carries the session's id so
    /// `validateForEditSave()` can rebuild the same `StoredSession`.
    public enum FormMode: Equatable, Sendable {
        case new
        case edit(sessionID: UUID)
    }

    /// Generalized over `ConnectionKind` (M12/T3): the connector now takes a
    /// typed `ConnectionConfig` instead of an SSH-only config, so the same
    /// seam can route to S3 (or future backends) alongside SSH. The decider
    /// is still passed through unconditionally — SSH uses it for TOFU; a
    /// non-SSH backend simply ignores it.
    ///
    /// `HostKeyDecider` is `macSCPCore`'s own type, spelled plainly. It used
    /// to be aliased here as well, from back when it lived on this view
    /// model; the alias let a Core connection type keep being spelled
    /// through the presentation layer's namespace. Now that a decider is a
    /// nominal type of its own, the alias bought a second name for it and
    /// nothing else.
    public typealias Connector = @Sendable (
        ConnectionConfig, HostKeyDecider
    ) async throws -> any RemoteFileSystem

    /// State while waiting for the user's decision on an unknown host key
    /// (see `resolveHostKeyPrompt`).
    public struct HostKeyPrompt: Equatable {
        public let candidate: HostKeyCandidate
    }

    /// The `SSHConnectionConfig` behind the most recently SUCCESSFUL
    /// `connect()` — including the already-resolved jump, as the connector
    /// used it EXCEPT for its secrets (M11d/T2: the external-terminal
    /// launcher needs these same values to reproduce the connection in a
    /// disposable script; fix round 2 redacts the password/passphrase at
    /// assignment time, since the launcher reads neither and this property
    /// otherwise outlives the connection by hours, not the seconds an alert
    /// is open). `nil` until the first successful connect; a failed attempt
    /// leaves the previous value untouched, since a failed connect never
    /// changes what session (if any) is actually active.
    public private(set) var lastConnectedConfig: SSHConnectionConfig?

    /// Everything the form collected, keyed by the ACTIVE backend's fields
    /// (M22/T8). The single source of truth: every `host`/`port`/`s3Bucket`/…
    /// property below reads and writes through here rather than holding a
    /// second copy, so the generic renderer (which binds to this map) and the
    /// connect/save paths (which read the properties) cannot drift apart —
    /// the drift no compiler can catch is exactly what this milestone removes.
    public var values = BackendDescriptor.descriptor(for: .ssh).defaultValues

    // MARK: - SSH fields, read through `values`
    //
    // These stay as named properties because they are the vocabulary the App
    // layer, the CLI and ~40 tests already speak; what changed is that they
    // are now views ONTO `values` instead of storage beside it.

    public var host: String {
        get { values[SSHField.host] }
        set { values[SSHField.host] = newValue }
    }

    public var port: String {
        get { values[SSHField.port] }
        set { values[SSHField.port] = newValue }
    }

    /// WebDAV's user name is its OWN field, not the SSH one: the two forms
    /// render different schemas now, and the WebDAV row writes
    /// `WebDAVField.username`. Everything else keeps using SSH's — S3 has no
    /// user name at all, and since M23/T7 nothing writes one for it either
    /// (the prefill and save paths used to park the `"unused"` placeholder
    /// here).
    public var username: String {
        get { kind == .webdav ? values[WebDAVField.username] : values[SSHField.username] }
        set {
            if kind == .webdav {
                values[WebDAVField.username] = newValue
            } else {
                values[SSHField.username] = newValue
            }
        }
    }

    /// The form's one secret slot, mapped onto whichever field the active
    /// backend and auth kind actually mean by it. `ManagedKeyPassphrase.resolve`
    /// -- its only remaining external callers (`ConnectionFormView`,
    /// `ContentView`'s `fillForm(_:from:)`), both reached only under
    /// `authChoice == .privateKey` -- is the reason this stays SSH-flavored
    /// vocabulary rather than being renamed `secret`; every other call site
    /// already prefers `resolvedSecret`/`fillSecret(_:)` by name.
    ///
    /// Built directly on those two (M23/T7 fix round 2) rather than
    /// duplicating their `switch`-free traversal: `password`'s getter/setter
    /// used to hand-enumerate `ConnectionKind` (`.webdav` vs. `.ssh`/`.s3`),
    /// which is exactly the per-protocol branch this milestone removes
    /// elsewhere, and which would fail to compile for a fourth backend where
    /// `resolvedSecret`/`fillSecret` already do not.
    ///
    /// SSH declares password and passphrase as two DIFFERENT fields (only one
    /// of them is ever visible, per auth kind), so the getter (`resolvedSecret`)
    /// picks by auth kind while the setter (`fillSecret`) writes every secret
    /// field the active backend declares -- both, for SSH. Writing both is
    /// what keeps a programmatic fill — a login set's secret, a Keychain
    /// passphrase — from evaporating when the auth kind is switched
    /// afterwards, which is the asymmetry
    /// `userSwitchClearsSecretButProgrammaticSetDoesNot` pins.
    public var password: String {
        get { resolvedSecret }
        set { fillSecret(newValue) }
    }

    /// `AuthChoice` and `StoredSession.AuthKind` share their raw values, which
    /// is why the schema's picker options are addressed by the PERSISTED raw
    /// value and no mapping table sits in between (see `SSHFieldSchema`).
    public var authChoice: AuthChoice {
        get { AuthChoice(rawValue: values[SSHField.authKind]) ?? .password }
        set { values[SSHField.authKind] = newValue.rawValue }
    }

    public var keyPath: String {
        get { values[SSHField.keyPath] }
        set { values[SSHField.keyPath] = newValue }
    }

    /// Save the session after a successful connect (store + keychain)?
    public var shouldSaveSession: Bool = false
    public var saveName: String = ""
    /// Group assignment shown by the picker — applies while saving a new
    /// session (`shouldSaveSession == true`) AND while editing a stored one.
    public var selectedGroupID: UUID?
    /// Tags shown by the form's tag field (P3a/T5) — applies while saving a
    /// new session (`shouldSaveSession == true`) AND while editing a stored
    /// one, mirroring `selectedGroupID` just above. Unlike `selectedGroupID`
    /// this is not itself the normalized form: the field owns the text↔list
    /// conversion (comma-separated typing), and whatever ends up here is
    /// handed to `StoredSession.tags` as-is by the write paths that read it
    /// (`SessionListViewModel.save(tags:)`, `validateForEditSave()` below).
    /// That property's own setter applies `TagList.normalized`, so neither
    /// write path — nor a third one added later — has to remember the rule.
    public var tags: [String] = []
    /// Three-way login switcher state (M10b/T3). The App layer reads this to
    /// decide whether to show the login-set picker or the manual
    /// username/password/key fields; it also fills `username`/`authChoice`/
    /// `keyPath`/`password` from the selected set right before connect/save
    /// (`SessionListViewModel.resolveTargetLoginSet(form:)`, M29-P2), so
    /// those fields still carry the values the rest of this view model
    /// already knows how to validate and connect with — `.set` needs no
    /// separate connect/validate path here.
    public var loginMode: LoginMode = .manual
    /// The chosen login set in `.set` mode, `nil` while none is selected yet.
    public var selectedLoginSetID: UUID?
    /// Manual mode only: "Save as new login set" toggle (M10b/T3) — the App
    /// layer creates the set from the current fields before persisting the
    /// session, then attaches its id as `loginSetID`.
    public var saveAsNewLoginSet: Bool = false
    /// Name for the new set created by `saveAsNewLoginSet`; an empty value
    /// falls back to `SessionListViewModel.suggestedSetName(forLabel:)`.
    public var newLoginSetName: String = ""

    /// Fills the credential block from a resolved login set (M22/T9) — the
    /// values `LoginResolver.resolve` returns, in the active backend's own
    /// field vocabulary.
    ///
    /// Clears the backend's credential fields FIRST. A tab's form outlives
    /// any single connect, and a set that carries NO secret at all — an agent
    /// login (M10d) — resolves to values with no secret field in them, so a
    /// plain merge would leave the PREVIOUS fill's password sitting in the
    /// form. Only the credential block is touched: the connection fields
    /// (host, port, endpoint, server URL) are the session's, not the set's.
    public func applyResolvedCredentials(_ resolved: FieldValues) {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        for field in descriptor.credentialSchema.fields {
            values.setRaw("\(descriptor.fieldNamespace).\(field.id)", to: "")
        }
        values.merge(resolved)
    }

    /// Fills the active backend's own secret field(s) with a secret resolved
    /// OUTSIDE the form — the Keychain slot a stored session's connect path
    /// reads (M23/T7), where the three fill branches each named their own field
    /// by hand and `password` was the wrong one for S3.
    ///
    /// Writes EVERY secret field the active backend declares, which for SSH is
    /// both the password and the passphrase: the same rule `password`'s setter
    /// applies, for the same reason — a programmatic fill must not evaporate
    /// when the auth kind is switched afterwards
    /// (`userSwitchClearsSecretButProgrammaticSetDoesNot`). S3's secret access
    /// key and WebDAV's password are one field each.
    public func fillSecret(_ secret: String) {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let namespace = descriptor.fieldNamespace
        for field in descriptor.connectionSchema.fields + descriptor.credentialSchema.fields
        where field.isSecret {
            values.setRaw("\(namespace).\(field.id)", to: secret)
        }
    }

    /// Jump host block (M10c/T3, mockup section 2): an optional intermediate
    /// hop the connection tunnels through. Off by default -- a brand-new
    /// form connects directly, exactly as before this feature existed.
    ///
    /// The toggle itself is form bookkeeping rather than a backend field, so
    /// it stays stored here; the jump's own host/port/login below live in
    /// `values` under the schema's `jump` group, addressed with the PAIR
    /// subscript so they cannot collide with the target's same-named fields.
    public var jumpEnabled: Bool = false

    public var jumpHost: String {
        get { values[SSHField.jump, SSHJumpField.host] }
        set { values[SSHField.jump, SSHJumpField.host] = newValue }
    }

    public var jumpPort: String {
        get { values[SSHField.jump, SSHJumpField.port] }
        set { values[SSHField.jump, SSHJumpField.port] = newValue }
    }

    public var jumpUsername: String {
        get { values[SSHField.jump, SSHJumpField.username] }
        set { values[SSHField.jump, SSHJumpField.username] = newValue }
    }

    /// Password (or key passphrase, in `.privateKey` mode) for the jump's
    /// OWN manual credentials -- same dual role as `password` above. One
    /// field, not two: a nested login has no credential schema of its own to
    /// split it across (see `SSHFieldSchema.jumpLeaves`).
    public var jumpPassword: String {
        get { values[SSHField.jump, SSHJumpField.password] }
        set { values[SSHField.jump, SSHJumpField.password] = newValue }
    }

    public var jumpKeyPath: String {
        get { values[SSHField.jump, SSHJumpField.keyPath] }
        set { values[SSHField.jump, SSHJumpField.keyPath] = newValue }
    }

    public var jumpAuthChoice: AuthChoice {
        get { AuthChoice(rawValue: values[SSHField.jump, SSHJumpField.authKind]) ?? .password }
        set { values[SSHField.jump, SSHJumpField.authKind] = newValue.rawValue }
    }
    /// The jump's own three-way login switcher (M10c/T3): the SAME building
    /// blocks the target uses (`loginMode`/`selectedLoginSetID`), reused for
    /// the jump's login instead of duplicating the mechanism. Unlike the
    /// target, the jump offers no "save as new login set" -- YAGNI (spec §3).
    public var jumpLoginMode: LoginMode = .manual
    public var jumpSelectedLoginSetID: UUID?
    /// Jump-source switcher state (M11a/T3): `.session` picks a saved
    /// connection as the jump host by reference instead of typing its
    /// host/port/login again; `.manual` is the block above, unchanged.
    /// Default `.manual` — see `JumpSourceMode`'s own doc comment.
    public var jumpSourceMode: JumpSourceMode = .manual
    /// The saved connection referenced in `.session` mode, `nil` while none
    /// is selected yet (M11a/T3).
    public var jumpSessionID: UUID?

    /// The protocol this form builds a connection for (M12/T7a). Default
    /// `.ssh` — a brand-new form behaves exactly as before this feature
    /// existed. The App layer's type switcher flips this;
    /// `connect()`/`validateForEditSave()`/`beginEditing()` all branch on it.
    ///
    /// Changing it resets `values` to the new backend's defaults (M22/T8).
    /// The namespaced storage already makes an S3 endpoint unable to leak
    /// into a WebDAV form, but the user must not be shown a stale one either
    /// — and the reset replaces the per-protocol field clearing `beginEditing`
    /// and `exitEditMode` used to spell out by hand.
    ///
    /// Guarded on an ACTUAL change: `exitEditMode()` assigns `.ssh`
    /// unconditionally and is documented to keep the field values for its
    /// callers, which an unguarded reset would wipe.
    ///
    /// The jump block goes with it (M23/T7). Its host/port/login live in
    /// `values` and are wiped by the reset above, but `jumpEnabled` and the
    /// source/set bookkeeping are stored beside it — and `jumpEnabled` is
    /// itself a MODE switch, the same sticky-toggle lesson `clearJumpFields()`
    /// documents. Only the SSH form renders the block, so a jump left on and
    /// then switched to S3 was invisible while still making `buildJumpSpec()`
    /// hand a hollow spec (empty host, freshly generated `secretID`) to a
    /// save path that no longer branches on `kind` to discard it.
    ///
    /// The TARGET's login switcher goes with it too (M23/T7 fix round 1), and
    /// that one is worse than the jump: a login set belongs to exactly one
    /// kind, the picker filters its options by kind
    /// (`ConnectionFormView.loginSetPicker`), and at the time the submit gate
    /// only checked that SOMETHING is selected. So an SSH set picked before a
    /// switch to S3 went invisible rather than being cleared, and saved a
    /// `.s3` session bound to an SSH set — which `LoginResolver.resolve` then
    /// rejects with `kindMismatch` on every later connect, i.e. a session
    /// that can never be opened again. The submit gate itself only started
    /// catching a stale selection with
    /// `SessionListViewModel.resolveTargetLoginSet`'s `kind` guard
    /// (M29-P2) — this reset here
    /// remains the earlier line of defense, clearing the selection before
    /// that guard is ever reached.
    ///
    /// `saveAsNewLoginSet`/`newLoginSetName` deliberately do NOT reset here.
    /// They are an intent ("also save this login"), not a reference to
    /// something of the old kind: `maybeCreateNewLoginSet` builds the set from
    /// the ACTIVE descriptor and the freshly reset `values`, so the toggle
    /// simply produces a set of the new kind. The rows also stay visible in
    /// manual mode for every backend, so a surviving tick is something the user
    /// can see and undo — the opposite of the invisible selection above.
    public var kind: ConnectionKind = .ssh {
        didSet {
            guard oldValue != kind else { return }
            values = BackendDescriptor.descriptor(for: kind).defaultValues
            clearJumpFields()
            loginMode = .manual
            selectedLoginSetID = nil
        }
    }

    // S3 and WebDAV field pass-throughs used to live here. Since M22 made the
    // form data-driven, production reads and writes `values` directly and
    // none of them has a caller left in `MacSCPApp`/`MacSCPCLI` (confirmed by
    // deleting all nine and rebuilding both executable targets clean — only
    // test files failed to compile). They still exist as
    // `ConnectionViewModelTests`-only convenience accessors; see
    // `Tests/macSCPCoreTests/ConnectionViewModelTestAccessors.swift`.

    /// The jump's existing MANUAL keychain slot when editing a session that
    /// already had one (M10c/T3), remembered by `beginEditing` so
    /// `validateForEditSave()` can reuse the SAME `secretID` in
    /// `buildJumpSpec(existingSecretID:)` -- otherwise leaving `jumpPassword`
    /// empty ("leave unchanged") would resolve against a freshly generated,
    /// never-written slot instead of the one that actually holds the secret.
    /// `nil` for a brand-new jump, or when the session had no jump / a
    /// set-mode jump (no manual slot to preserve either way).
    private var existingJumpSecretID: UUID?

    /// The session `beginEditing` was handed, kept so `validateForEditSave`
    /// can MUTATE it rather than rebuild it (M23).
    ///
    /// Rebuilding is what the three old bodies did, and it is why a
    /// set-backed S3 session lost its login-set binding on every unrelated
    /// edit between M15 and M22: a field the form does not render is a field a
    /// rebuild drops. Cleared by `exitEditMode`, so a stale original cannot
    /// outlive its edit.
    private var editingOriginal: StoredSession?

    public private(set) var state: State = .idle
    /// `.new` while the form creates a connection; `.edit` while it edits a
    /// stored session (see `beginEditing`/`endEditing`).
    public private(set) var mode: FormMode = .new
    /// While non-nil: the form UI shows the fingerprint card and waits for
    /// `resolveHostKeyPrompt`.
    public private(set) var hostKeyPrompt: HostKeyPrompt?

    /// Why the most recent dial failed, at the only coarseness a caller
    /// deciding whether to try again needs (connection-liveness plan, Task
    /// 7): would an identical second attempt differ from this one at all, or
    /// does a person have to answer or supply something first?
    ///
    /// `nil` only while `state` is not `.failed`. Two writers, counted while
    /// writing this sentence, both in this type: `connect()` clears it as
    /// its first act (an attempt that has just started has earned no
    /// verdict), and `fail(_:kind:)` sets it — and `fail(_:kind:)` is the
    /// ONLY way `state` is ever made `.failed` anywhere in this type, which
    /// is what makes "every failure carries a verdict" structural rather
    /// than a rule seven call sites have to remember.
    /// `ConnectionViewModelSourceGuardTests` scans for a `.failed` written
    /// any other way.
    ///
    /// `fail(_:kind:)` writes this BEFORE `state`, so nothing observing
    /// `state` can read a verdict belonging to the attempt before.
    ///
    /// Round 2, after review: the first version classified only what the
    /// dial THREW, so every pre-dial refusal — a dangling login set, a
    /// stored secret that is gone — left this `nil`, read as retryable, and
    /// `.automatic` looped on a question only a person could answer. The
    /// default is now the other way round.
    ///
    /// Deliberately NOT derived from `state`'s `field:` at the reading end:
    /// `.failed` carries a localized message and a form field, neither of
    /// which is a stable thing to branch on — the message is translated
    /// text, and a mismatched host key (a hard stop with no field at all)
    /// would be indistinguishable from an ordinary network failure.
    public private(set) var lastFailureKind: ConnectFailureKind?
    /// Why the most recent DIAL failed, as the one fixed sentence this
    /// project stores for that error (session overview plan, Task 2).
    ///
    /// `nil` unless an attempt actually reached the wire and threw. A
    /// pre-dial refusal — a form validation, a schema violation, a login set
    /// that no longer resolves — leaves it `nil`, and that is what the
    /// property is FOR: the App writes a `connectFailed` audit row only when
    /// there was a connect to fail, and `nil` is how it can tell. The kind
    /// beside it cannot answer that question — `.needsPerson` is the default
    /// for every refusal as well as for a host-key stop.
    ///
    /// `DialSupport.reason(for:)`'s sentence and never the error's own text:
    /// see that function's doc comment for what an arbitrary error's
    /// description carries, and why the two URL-shaped backends make it a
    /// credential hazard rather than only a noisy one. The error itself
    /// never leaves this type, which is why the sentence is computed here,
    /// where it is caught, rather than published as an `Error` for the App
    /// to render.
    ///
    /// Written in `connect()` alone — cleared at the head of every attempt
    /// and set in its `catch`. Deliberately NOT inside `fail(_:kind:)`:
    /// `ConnectionViewModelSourceGuardTests.theOneFailureWriterSetsTheVerdictFirst`
    /// reads the five normalized lines that follow that function's
    /// signature, and a sixth line in its body would push `state = newState`
    /// out of the window that guard reads.
    public private(set) var lastFailureReason: String?

    /// Identifies whichever `connect()` call is currently allowed to write
    /// to this instance (connection-liveness plan, Task 6 fix round 1).
    ///
    /// Forcing `state` back to `.idle` on Cancel (`cancelConnecting()`)
    /// does not, by itself, stop the abandoned dial `connect()` is still
    /// awaiting — cancelling that dial is best-effort only (see
    /// `cancelConnecting()`'s own doc comment). Without this token, a
    /// SECOND `connect()` call started after Cancel shares every one of
    /// this instance's mutable slots (`state`, `hostKeyPrompt`,
    /// `hostKeyContinuation`, `lastConnectedConfig`) with the first,
    /// abandoned one — measured, not hypothetical: the abandoned attempt's
    /// own `defer { hostKeyPrompt = nil }` erased the SECOND attempt's live
    /// trust card, the abandoned attempt's own late call into
    /// `presentHostKeyPrompt` replaced the second attempt's card with a
    /// DIFFERENT host's fingerprint (attribution), and the second attempt's
    /// own host-key continuation was silently overwritten and never
    /// resumed (availability) — see the Task 6 fix-round report for the
    /// full trace.
    ///
    /// Reassigned at the top of every `connect()` call and, since fix
    /// round 2, UNCONDITIONALLY by `cancelConnecting()` — not only while
    /// `state == .connecting` (see that method's own doc comment for the
    /// window fix round 1 left open by gating the move on `state`, which
    /// `connect()`'s own success path leaves BEFORE the caller finishes
    /// its own remaining work). Every write `connect()` performs from THAT
    /// point on — publishing a host-key prompt, and the terminal `state`/
    /// `lastConnectedConfig` writes after the dial returns — is guarded by
    /// comparing the attempt's own captured token against this property at
    /// the moment of the write, not just at the moment the attempt started;
    /// an attempt that was current when it began but got superseded while
    /// suspended writes nothing.
    ///
    /// `internal`, not `private` (fix round 3, review-mandated regression
    /// test): every OTHER effect of this property is observable only
    /// through a write it gates, and fix round 2's specific change — moving
    /// this UNCONDITIONALLY in `cancelConnecting()` rather than only while
    /// `state == .connecting` — has no such gated write to observe FROM
    /// Core alone once `connect()` has already returned (there is no
    /// lingering suspended call left to refuse anything from at that
    /// point). `ConnectionViewModelTests.cancelConnectingMovesTheTokenEvenOutsideConnecting`
    /// reads this directly to pin the one-line reordering itself, the
    /// thing an indirect, effects-only test cannot reach. Still invisible
    /// outside this module — `@testable import` is what `internal` opens,
    /// not a wider audience than `private` denied.
    var currentAttempt = UUID()

    /// The stored session the current attempt is dialing, or `nil` when it
    /// is ad-hoc — typed into the form and never saved, so there is nothing
    /// stored a surface could offer to open an editor on.
    ///
    /// Bound to the ATTEMPT, not to whoever asked for one (two-open-
    /// questions design, M3): it is assigned in the same breath as
    /// `currentAttempt`, which is to say AFTER `connect()`'s refusal of a
    /// second call. A refused call returns before that line, never becomes
    /// an attempt, and therefore cannot hand its origin to the attempt that
    /// actually is running.
    ///
    /// That ordering is the whole point. The App layer used to keep this
    /// fact on the tab (`SessionTab.dialingStoredSessionID`, removed by the
    /// same task), written before the dial and cleared when the state left
    /// `.connecting`. A refused call changes no state, so it left a value
    /// nothing cleared, and the next attempt to fail — an ad-hoc one from
    /// the form — was labelled with a stored session it had never chosen.
    /// Assigning here does not clean that up; it makes it unwritable.
    ///
    /// Two writers, counted here. `connect(origin:)` assigns it with the
    /// attempt, which is what lets it be read WHILE a dial is in flight —
    /// the reading that catches a refused call trying to contribute one.
    /// `fail(_:kind:origin:)` assigns it again as part of publishing a
    /// `.failed` state, so that every failure names its own origin instead
    /// of inheriting whatever the last attempt left: the paths that reach
    /// `.failed` without dialing at all (`showFailure`, the two save
    /// validators) are not attempts, and say so by passing nothing.
    ///
    /// Read from the App layer, which is why this is `public` where
    /// `currentAttempt` is not: the failed-connect surface asks what the
    /// attempt that failed was dialing.
    public private(set) var attemptOrigin: UUID?

    private let connector: Connector
    /// Holds the continuation that the host-key decider places on `connect()`,
    /// until `resolveHostKeyPrompt` fulfills it. Stays private — the UI only
    /// knows `hostKeyPrompt` and `resolveHostKeyPrompt(trust:)`.
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Maps the form's `AuthChoice` to the persisted `StoredSession.AuthKind`
    /// (M10d/T3) -- the one place the JUMP's choice-to-kind mapping goes
    /// through, so a third auth kind only needs updating here instead of at
    /// every jump call site. The target's own choice reaches the store
    /// through `SSHFieldSchema` instead. Public (M10d/T4), though
    /// the App layer currently has no external caller of its own: it
    /// round-trips the raw `AuthKind` value through `SSHFieldSchema` instead
    /// of going through this mapping.
    public static func storedAuthKind(for choice: AuthChoice) -> StoredSession.AuthKind {
        switch choice {
        case .password: return .password
        case .privateKey: return .privateKey
        case .agent: return .agent
        }
    }

    /// The reverse of `storedAuthKind(for:)` -- used by `beginEditing` to
    /// prefill the jump's auth choice from a persisted `AuthKind`. Public
    /// (M10d/T4): `ContentView`'s jump-prefill paths call this across the
    /// module boundary. `SessionListViewModel+Submit` calls it too, but that
    /// file lives in this module and needs no access beyond `internal`.
    public static func authChoice(for kind: StoredSession.AuthKind) -> AuthChoice {
        switch kind {
        case .password: return .password
        case .privateKey: return .privateKey
        case .agent: return .agent
        }
    }

    /// What `connect()` resolves before it dials anything, or the failure it
    /// would report for a form that does not resolve.
    ///
    /// A dedicated result rather than an optional config: the failure arm
    /// carries the very `State` `connect()` publishes, so the ONE place that
    /// decides which message and which highlighted field a failed resolution
    /// means stays this view model — a caller that renders it differently
    /// still renders the same answer.
    public enum ConfigResolution: Equatable {
        case resolved(ConnectionConfig)
        case failed(State)
    }

    /// Everything `connect()` does BEFORE it dials, and nothing else: the
    /// form rules, the jump validation, `descriptor.makeConfig`, and the jump
    /// hop attached on top.
    ///
    /// One body for every protocol since M23. What used to be three
    /// hand-written validators is `descriptor.firstViolation`, which walks the
    /// VISIBLE fields — so SSH's "a password is required, but only under
    /// password auth, and never under agent auth" is the schema's
    /// `visibleWhen` rather than a `switch` here. Two things stay
    /// hand-written, because they are form rules rather than backend fields:
    /// the save name, and the jump block.
    ///
    /// Exists because callers other than the dial need exactly these steps
    /// and must NOT take the fourth. Counted while writing this sentence,
    /// there are three in all: `connect()`; the App's "Open in External
    /// Terminal" entry (`ContentView.openExternalTerminalFromSidebar`, wired
    /// by P3c/T2), which hands the resolved config to a launcher for a
    /// session macSCP itself never connects to; and `validateForNewSave()`,
    /// which asks whether a running connection may be written as a session
    /// and dials nothing either. Writing those steps a second time is what
    /// the equivalence guard in
    /// `ConnectionConfigResolutionTests` exists to prevent: it compares what
    /// `connect()` dials against what this returns, and goes red if
    /// `connect()` ever resolves anything on its own again. Measured, so it
    /// is not sold as more than it is — it does NOT pin the behaviour of the
    /// function below, since `connect()` delegates and a change made here
    /// moves both sides at once; the guard's per-case assertions (the hop's
    /// host and port, each failure's message and field) do that.
    ///
    /// PUBLISHES NOTHING. A failure comes back as the state `connect()`
    /// assigns for it, and the caller decides where it belongs: `connect()`
    /// puts it in `state`, which the connection form renders, while a
    /// context-menu caller — with no form on screen — can raise an alert
    /// instead. Publishing here would also let a resolution overwrite the
    /// `state` an in-flight `connect()` owns.
    ///
    /// RETAINS NOTHING. The resolved config carries the plaintext secret and
    /// is returned, never stored. `lastConnectedConfig` is written by a
    /// SUCCESSFUL `connect()` alone, and it stores `redactingSecrets()`, so
    /// no plaintext password outlives the dial that produced it; a second
    /// property holding an UNREDACTED resolved config would be a place no
    /// clearing reaches.
    ///
    /// Answers ONE question — can this connection be resolved — and therefore
    /// does NOT check the save name. That check belongs to whichever caller
    /// actually writes a session, and each of them makes it ahead of this
    /// call: `connect()` when `shouldSaveSession` is set, and
    /// `validateForNewSave()` always, since writing is all it does. It is a
    /// rule of the form's SAVE, and a form legitimately carries
    /// `shouldSaveSession == true` with a blank name while the user is still
    /// typing an ad-hoc "save & connect". Refusing the caller that saves
    /// nothing (the external-terminal route) for a missing save name would
    /// be a refusal for a reason unrelated to what it is doing.
    public func resolveConfigWithoutDialing() -> ConfigResolution {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        if let violation = descriptor.firstViolation(in: values, requireSecrets: true) {
            return .failed(.failed(
                message: CoreL10n.string(violation.messageKey),
                field: .schema(violation.fieldKey)))
        }
        // Unconditional, not `if kind == .ssh`: `validateJump` returns nil
        // whenever the toggle is off, and the toggle is cleared by
        // `exitEditMode` whenever `kind` changes. A guard here would be a
        // protocol branch that decides nothing.
        if let jumpFailure = validateJump(requireSecret: true) {
            return .failed(jumpFailure)
        }

        let config: ConnectionConfig
        do {
            config = try descriptor.makeConfig(values, resolvedSecret)
        } catch {
            return .failed(Self.failedState(for: error))
        }
        // The hop belongs to the RESOLUTION, not to the dial: what comes back
        // here is what `connect()` hands the connector AND what it records as
        // `lastConnectedConfig`, which the external-terminal launcher turns
        // into an `ssh -J` command line (M11d/T2) — returning the pre-jump
        // config would make "Open in External Terminal" dial a bastion-only
        // target directly.
        //
        // The throw is a hard stop rather than a fallback: a jump
        // `SSHConnectionConfig.init` rejects must fail the whole resolution
        // instead of yielding a hop-less config, or a session that may only
        // be reached through its bastion would be dialled directly with
        // nothing reported (M23/T5 fix round 1).
        do {
            return .resolved(try attachingJump(to: config))
        } catch {
            return .failed(jumpAwareFailedState(for: error))
        }
    }

    /// Returns the connected file system or nil; errors land in `state`.
    /// Re-entrancy safe: calls made while `.connecting` are dropped, so a
    /// double-click doesn't open a second (orphaned) connection.
    ///
    /// Everything up to and including the resolved config comes from
    /// `resolveConfigWithoutDialing()`, the one resolution its three callers
    /// share (P3c/T1). What is left here is the save name — a rule of every
    /// caller that writes a session, which since the tab-context-menu plan
    /// means this one and `validateForNewSave()` — plus the dial: publishing
    /// the resolution's failure into `state`, the `.connecting` transition,
    /// the host-key decider, and the record of what was actually connected.
    ///
    /// Attempt-scoped since Task 6 fix round 1 (`myAttempt`, captured once
    /// at the top and compared against `currentAttempt` at every write from
    /// the dial onward — see `currentAttempt`'s own doc comment for why):
    /// nothing before `state = .connecting` needs the same guard, because
    /// nothing before it suspends — `resolveConfigWithoutDialing()` is
    /// synchronous, so no OTHER call to this actor-isolated method can run
    /// between this attempt claiming `currentAttempt` and reaching that
    /// line.
    ///
    /// `origin` is the stored session this dial came from, and it is
    /// recorded on `attemptOrigin` together with the attempt (M3). The
    /// default is `nil` because `nil` is not a stand-in for something real
    /// here — it IS the answer for a dial the user typed into the form and
    /// never saved, which is what every caller that omits it is doing. A
    /// caller that forgets to pass a stored session's id gets an ad-hoc
    /// attempt, which is a visibly poorer surface rather than a silently
    /// wrong one: the failure would offer no way to edit the session, where
    /// the bug this argument exists to fix offered a way to edit the wrong
    /// one.
    public func connect(origin: UUID? = nil) async -> (any RemoteFileSystem)? {
        guard state != .connecting else { return nil }
        // Every attempt starts without a verdict — see `lastFailureKind`'s
        // own doc comment for the two writers that keep it honest — and
        // without a reason, so neither a previous failure's sentence nor one
        // belonging to an attempt that then SUCCEEDED can be read as this
        // attempt's.
        lastFailureKind = nil
        lastFailureReason = nil
        let myAttempt = UUID()
        currentAttempt = myAttempt
        // Assigned WITH the attempt, and after the refusal above — see
        // `attemptOrigin`'s own doc comment for why the order is the fix
        // rather than an incidental detail of it.
        attemptOrigin = origin
        defer {
            // Only clear the prompt if IT belongs to this attempt — an
            // abandoned attempt reaching this `defer` after being
            // superseded must not erase a newer attempt's still-pending
            // trust card.
            if currentAttempt == myAttempt { hostKeyPrompt = nil }
        }

        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail(.failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName),
                 origin: origin)
            return nil
        }

        let dialed: ConnectionConfig
        switch resolveConfigWithoutDialing() {
        case .failed(let failure):
            fail(failure, origin: origin)
            return nil
        case .resolved(let config):
            dialed = config
        }

        state = .connecting
        do {
            // The decider is handed to EVERY backend by the `Connector`
            // typealias; only SSH consults it (TOFU). S3 and WebDAV receive a
            // decider they never ask -- WebDAV's own certificate decision
            // belongs to whoever builds the `connector` (the App passes
            // `certificateBridge.ask`, the CLI refuses every unknown one).
            let fs = try await connector(dialed, .asking { [weak self] candidate in
                await self?.presentHostKeyPrompt(for: candidate, attempt: myAttempt) ?? false
            })
            // Attempt-scoped write (see `currentAttempt`'s own doc
            // comment): a superseded attempt's own successful dial must not
            // publish `.idle`/`lastConnectedConfig`, and must not hand its
            // `fs` back to its own caller as if it were still wanted.
            guard currentAttempt == myAttempt else { return nil }
            state = .idle
            // The DIALED config, hop included: `lastConnectedConfig` is what
            // the external-terminal launcher reproduces the connection from.
            // Stored with its secrets redacted -- that path reads none (see
            // `SSHConnectionConfig.redactingSecrets()`'s own doc comment),
            // and reproducing the connection means `ssh` prompting for the
            // password itself, not macSCP replaying a saved one.
            if case .ssh(let ssh) = dialed { lastConnectedConfig = ssh.redactingSecrets() }
            return fs
        } catch {
            // Same attempt-scoped write as the success path above.
            guard currentAttempt == myAttempt else { return nil }
            // The fixed sentence for this error, computed where the error
            // is — the only place it exists. See `lastFailureReason`.
            lastFailureReason = DialSupport.reason(for: error)
            // The one call that passes a `kind`, and so the only one that
            // can reach `.other`: this is the only failure in this type
            // that got as far as the wire.
            fail(
                jumpAwareFailedState(for: error), kind: Self.failureKind(for: error),
                origin: origin)
            return nil
        }
    }

    /// The ONLY way `state` becomes `.failed` in this type — see
    /// `lastFailureKind`'s own doc comment for why that is structural
    /// rather than a convention, and `ConnectionViewModelSourceGuardTests`
    /// for the scan that keeps it so.
    ///
    /// `.needsPerson` is the default because every caller but one is a
    /// refusal decided BEFORE anything reached the wire: a form validation,
    /// a schema violation, a login set that no longer resolves. None of
    /// those can answer differently on a retry unless a person does
    /// something first — see `ConnectFailureKind.needsPerson`. Only
    /// `connect()`'s `catch` passes a `kind` at all, and only it can pass
    /// `.other`.
    ///
    /// `origin` defaults to `nil` for the same reason `kind` defaults to
    /// `.needsPerson`, and it is the same set of callers: everything that
    /// reaches here without dialing — a save-name validation, a schema
    /// violation, a login set the App layer could not resolve — is not an
    /// attempt and has no stored session of its own to name. Only
    /// `connect()` passes one, and it passes the origin of the attempt it
    /// is failing.
    ///
    /// Stating the origin HERE, rather than letting the last attempt's
    /// value stand, is what stops a failure that is not an attempt from
    /// borrowing the label of the attempt before it: `attemptOrigin` is
    /// assigned at the head of `connect()` and outlives that attempt, so a
    /// later `showFailure` on the same form would otherwise publish a
    /// `.failed` state pointing at a session the user is no longer trying
    /// to reach. Measured on the `fillForm`-refusal path, which is exactly
    /// that sequence.
    ///
    /// Kept on ONE line deliberately: `ConnectionViewModelSourceGuardTests
    /// .theOneFailureWriterSetsTheVerdictFirst` anchors on this signature
    /// and reads the few lines after it, and wrapping the parameters put
    /// `state = newState` outside its window. It said so loudly rather than
    /// passing — which is the behaviour that made keeping the line the
    /// cheaper answer than widening the guard around it.
    private func fail(_ newState: State, kind: ConnectFailureKind = .needsPerson, origin: UUID? = nil) {
        lastFailureKind = kind
        attemptOrigin = origin
        state = newState
    }

    /// Classifies a thrown dial error for `lastFailureKind`.
    ///
    /// `.needsPerson` covers exactly what the connection-liveness design
    /// spec names as the stop condition for background retrying: a host-key
    /// decision (`HostKeyError`, and `ServerCertificateError`, its
    /// WebDAV/S3 analogue — a mismatch is a hard stop nobody can retry
    /// past, a rejection was a person's answer, and an unreadable trust
    /// store means the question cannot even be asked) and a key passphrase
    /// macSCP does not have (`SSHKeyError.passphraseRequired` /
    /// `.wrongPassphrase`).
    ///
    /// Every other `SSHKeyError` case (`fileNotFound`, `unsupportedFormat`,
    /// and, since Task 1 of the key-formats plan, `typeNotLoadable` and
    /// `pemNotSupported`) is deliberately `.other`, even though no second
    /// attempt will fix any of them either: the spec's rule is about the
    /// two conditions above, and treating this as a general "would retrying
    /// help" oracle would make it a growing list of guesses instead of one
    /// stated rule. Nothing is lost either way — the surface that reads
    /// this still offers a manual retry in every case.
    static func failureKind(for error: Error) -> ConnectFailureKind {
        switch error {
        case is HostKeyError, is ServerCertificateError:
            return .needsPerson
        case SSHKeyError.passphraseRequired, SSHKeyError.wrongPassphrase:
            return .needsPerson
        default:
            return .other
        }
    }

    /// Abandons the current connect attempt (connection-liveness plan,
    /// Task 6). `currentAttempt` moves UNCONDITIONALLY — fix round 2,
    /// after a review measured a window fix round 1 left open: `state`
    /// alone does not describe whether an attempt is still "live" once
    /// `connect()` has already returned to its App-layer caller.
    /// `ConnectionViewModel.connect()`'s success path sets `state = .idle`
    /// and returns the file system BEFORE the caller does its own
    /// remaining work (`fs.homeDirectoryPath()`, then handing the result to
    /// `ContentView.startSession`) — during that window `state` is `.idle`,
    /// not `.connecting`, so a `cancelConnecting()` gated on `state ==
    /// .connecting` (fix round 1's shape) would do NOTHING: the token
    /// would stay put, and the caller's own eventual `startSession` call
    /// would have no way to learn a cancel happened in Core at all. Moving
    /// the token first, unconditionally, is what makes `cancelConnecting()`
    /// always mean "whatever attempt was running, it is no longer this
    /// one" regardless of which line of `connect()` that attempt happens
    /// to be on right now — the App layer's own gate on this same fact
    /// (`SessionTab.reconnectAttempt`, checked immediately before
    /// `startSession` at both call sites) is what actually closes the
    /// window this paragraph describes; this unconditional move is Core's
    /// own half of the same rule, kept true regardless of what the App
    /// layer does with it.
    ///
    /// The `state == .connecting` guard below now gates only the REST of
    /// this method — forcing `state` back to `.idle` and releasing a
    /// host-key prompt — which only make sense while a dial is actually in
    /// progress. Forcing `state` directly (rather than relying on the
    /// wrapping `Task`'s cancellation to eventually be noticed) is not a
    /// style choice — `ConnectionViewModelTests
    /// .secondConnectWhileConnectingIsRejected` (same file) already proves
    /// the `connector` this type is built with can hang past any amount of
    /// cancellation on the CALLING `Task`: nothing on the plain-dial path
    /// polls `Task.isCancelled`, so a `Task.cancel()` on whatever wraps
    /// `connect()` does not, by itself, make that `await` return. (The one
    /// exception is the host-key-prompt wait inside `presentHostKeyPrompt`,
    /// which IS built on `withTaskCancellationHandler` — see
    /// `cancelWhileHostKeyPromptPendingResolvesConnect`.) Forcing `state`
    /// is therefore the only way an App-level Cancel control can hand the
    /// form back before a dead host's dial times out on its own (bounded by
    /// `connectTimeoutSeconds`, but still up to that long).
    ///
    /// Clearing `hostKeyPrompt` and resolving `hostKeyContinuation` here —
    /// rather than leaving that to `connect()`'s own `defer` — matters for
    /// the case where Cancel runs WHILE a trust card is up: the `defer`'s
    /// own guard (`if currentAttempt == myAttempt`) would otherwise refuse
    /// to touch it, since by the time that `defer` runs `currentAttempt`
    /// has already moved past this abandoned attempt — leaving an orphaned
    /// card on screen with a live continuation nobody but this method can
    /// still resolve. In today's App layer this path is not reachable
    /// through the Cancel button itself (`ConnectionSurfacePlan` never
    /// offers Cancel while a host-key prompt is pending), but Core does not
    /// rely on a caller's UI gating for its own correctness.
    ///
    /// A repeated call (a fast double-click on Cancel, or a Cancel that
    /// arrives after the dial already settled on its own) is harmless: the
    /// token simply moves again, which cannot un-supersede anything, and
    /// the `state == .connecting` guard still protects the rest of the
    /// method from stomping a state some OTHER path already published.
    ///
    /// The abandoned dial may still resolve afterward, successfully or
    /// not, in the true background; this method does not and cannot stop
    /// it (the same best-effort-only trade the App layer's
    /// `LivenessProbeRace` documents for the liveness probe's own `stat`
    /// call) — what fix round 1 changed is that the abandoned dial's
    /// EVENTUAL writes INSIDE `connect()` are refused at the source; what
    /// fix round 2 adds is that this now holds regardless of which line of
    /// `connect()` the abandoned attempt is sitting on when Cancel runs.
    public func cancelConnecting() {
        currentAttempt = UUID()
        guard state == .connecting else { return }
        state = .idle
        hostKeyPrompt = nil
        resolveHostKeyPrompt(trust: false)
    }

    /// `failedState` carrying the jump context the form currently holds.
    ///
    /// Used by both jump-aware failure sites -- attaching the hop, and the dial
    /// itself. The four-argument form is what maps `invalidJumpPort`,
    /// `emptyJumpKeyPath`, `invalidJumpHost` and `invalidJumpUsername` onto the
    /// jump rows, and what lets `channelSetupRejected`, the `AgentError` cases
    /// and `SSHKeyError.fileNotFound` tell the jump hop from the target one.
    private func jumpAwareFailedState(for error: Error) -> State {
        Self.failedState(
            for: error, jumpEnabled: jumpEnabled,
            jumpKeyPath: jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            jumpAuthChoice: jumpAuthChoice)
    }

    /// The secret the active backend's visible secret field currently holds.
    ///
    /// A QUERY, not a stored property: SSH means the passphrase under
    /// private-key auth, the password under password auth, and NOTHING under
    /// agent auth — where reading a Keychain slot that was never written is
    /// exactly the M10d bug. `visibleSecretField` answers all three.
    ///
    /// Public since M23/T7 so the App's ONE save call site can name the secret
    /// to persist without a `kind` branch of its own: the S3 save branch read
    /// `s3SecretAccessKey`, the WebDAV one `password`, and each was a second
    /// truth about which field this backend means by "the secret".
    public var resolvedSecret: String {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let namespace = descriptor.fieldNamespace
        let field = descriptor.connectionSchema
            .visibleSecretField(in: values, namespace: namespace)
            ?? descriptor.credentialSchema
                .visibleSecretField(in: values, namespace: namespace)
        guard let field else { return "" }
        return values.raw["\(namespace).\(field.id)"] ?? ""
    }

    /// Attaches the jump hop to a freshly built config.
    ///
    /// Separate from `makeConfig` on purpose and pinned by
    /// `SSHFieldSchema.makeConfigLeavesTheJumpToTheCaller`: a jump host has a
    /// SECOND secret in its own Keychain slot, and a factory taking one secret
    /// structurally cannot resolve it. Doing this here is what keeps a
    /// bastion-only session from quietly dialling its target directly.
    ///
    /// Non-SSH configs pass through untouched — no other protocol has a hop.
    ///
    /// THROWS rather than falling back to `config`. `validateJump` checks only
    /// presence — host non-empty, port parses as an `Int`, username non-empty
    /// in manual mode, and in SESSION mode not even that — while the
    /// initializer below additionally enforces the `isValidJumpHost` /
    /// `isValidJumpUsername` whitelists, the `1...65535` port range and a
    /// non-empty jump key path. Those are reachable, not theoretical: a jump
    /// port of `70000` passes `validateJump` and is rejected here.
    ///
    /// Swallowing the throw would hand back the hop-LESS config and dial the
    /// target directly, succeeding silently, for exactly the session that must
    /// not be reached any way but through its bastion. It would also make
    /// `failedState`'s `invalidJumpPort` / `emptyJumpKeyPath` /
    /// `invalidJumpHost` / `invalidJumpUsername` arms dead code.
    ///
    /// The whitelist is deliberately NOT duplicated into `validateJump`:
    /// `SSHConnectionConfig.init` is the one source of jump validation, and a
    /// second copy would be a second truth about one rule.
    private func attachingJump(to config: ConnectionConfig) throws -> ConnectionConfig {
        guard case .ssh(let ssh) = config, let jump = buildJumpConfig() else { return config }
        return .ssh(try SSHConnectionConfig(
            host: ssh.host, port: ssh.port, username: ssh.username,
            auth: ssh.auth, jump: jump))
    }

    /// Decider side: publishes the prompt and suspends on a continuation
    /// until `resolveHostKeyPrompt` fulfills it.
    /// Cancellation-safe: if the connect() task is cancelled while the prompt
    /// is open, the continuation resolves with `false` (no leak, no hang);
    /// the connector sees a rejection.
    ///
    /// `attempt` is `connect()`'s own `myAttempt`, checked BEFORE this
    /// method touches `hostKeyPrompt`/`hostKeyContinuation` at all (fix
    /// round 1, connection-liveness plan Task 6): a `connect()` call whose
    /// attempt has already been superseded — by Cancel or by a newer
    /// `connect()` call — refuses right here, before publishing a card for
    /// the wrong host over a still-pending one and before registering a
    /// continuation nobody will ever resume. See `currentAttempt`'s own doc
    /// comment for the measured failure this closes.
    private func presentHostKeyPrompt(for candidate: HostKeyCandidate, attempt: UUID) async -> Bool {
        guard attempt == currentAttempt else { return false }
        hostKeyPrompt = HostKeyPrompt(candidate: candidate)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                hostKeyContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveHostKeyPrompt(trust: false)
            }
        }
    }

    /// Called by the UI once the user answers the fingerprint card.
    /// Duplicate calls (e.g. a fast double-click) are ignored — the
    /// continuation may only be fulfilled once.
    public func resolveHostKeyPrompt(trust: Bool) {
        guard let continuation = hostKeyContinuation else { return }
        hostKeyContinuation = nil
        continuation.resume(returning: trust)
    }

    /// Surfaces a failure found by the App layer (M10b/T3: a stored
    /// session's `loginSetID` no longer resolves to a set) through the same
    /// `.failed` state `connect()`/`validateForEditSave()` use — the form
    /// gets the identical red-highlight/alert treatment without a second
    /// error-reporting mechanism.
    public func showFailure(message: String, field: Field? = nil) {
        // `.needsPerson`, by `fail(_:kind:)`'s default: an App-layer
        // refusal reaches this method precisely because something needs the
        // user's attention — a login set that no longer resolves, a jump
        // whose source session is gone — and the next unattended attempt
        // would ask the identical question. See `lastFailureKind`'s doc
        // comment for the review that measured these looping.
        fail(.failed(message: message, field: field))
    }

    /// Removes the plaintext password from the state (e.g. after disconnecting).
    ///
    /// Clears every secret slot of EVERY backend's login, not just the one the
    /// current `kind`/auth kind happens to read (M22/T8): a secret typed under
    /// one auth kind and abandoned by switching to another would otherwise sit
    /// in `values` unreachable but still in memory.
    ///
    /// Walks `ConnectionKind.allCases` and each descriptor's own declared
    /// secret fields (M23/T7 fix round 2) instead of naming SSH's password and
    /// passphrase, S3's secret access key and WebDAV's password by hand -- the
    /// same declarative traversal `fillSecret(_:)` above uses, generalized
    /// over every backend instead of just the active one. A hand-written list
    /// is exactly the enumeration a fourth backend would silently fall outside
    /// of: nothing here would fail to compile, and its secret would simply
    /// keep sitting in memory across a disconnect with no test to catch it.
    ///
    /// `SSHField.jump`'s password is deliberately NOT cleared here, and is
    /// unreachable by this traversal in the first place: it is a nested GROUP
    /// leaf, not a top-level field, so no top-level `field.isSecret` check
    /// ever sees it (`ConnectionFieldSchema.visibleSecretField`'s own doc
    /// comment: "secrets never nest"). It is also a SECOND login, with its own
    /// Keychain entry (`JumpSpec.secretID`) and its own auth switcher.
    /// `selectAuthChoice(_:)` calls this whenever the user flips the TARGET's
    /// auth picker — clearing the jump's slot from there would silently
    /// discard a bastion password the user already typed, on a picker flip
    /// that has nothing to do with the jump. The jump's own clearing paths
    /// (`selectJumpAuthChoice`, `selectJumpSourceMode`, `clearJumpFields`)
    /// cover it, and `clearJumpFields()` is what disconnect-time teardown
    /// reaches through.
    public func clearPassword() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            let namespace = descriptor.fieldNamespace
            for field in descriptor.connectionSchema.fields + descriptor.credentialSchema.fields
            where field.isSecret {
                values.setRaw("\(namespace).\(field.id)", to: "")
            }
        }
    }

    /// Full disconnect-time scrub (review finding, M11d fix round 1): clears
    /// the form's own plaintext password AND the retained
    /// `lastConnectedConfig`. Since fix round 2, `lastConnectedConfig` itself
    /// no longer carries a plaintext secret -- it is written already redacted
    /// (`SSHConnectionConfig.redactingSecrets()`) -- so clearing it here is no
    /// longer what keeps a password out of memory; that job is done at
    /// assignment, in `connect()`. What clearing it still buys: the
    /// non-secret fields (host, username, jump destination) are worth
    /// forgetting on disconnect too, and doing it here keeps the invariant
    /// local to this method rather than relying on every caller to remember
    /// it. `ContentView.teardown(_:)` calls this instead of `clearPassword()`
    /// directly, since `SessionTab.connectionViewModel` survives for the
    /// tab's whole lifetime and would otherwise keep a stale
    /// `lastConnectedConfig` sitting around across every later
    /// disconnect/reconnect in that tab. The other `clearPassword()` call
    /// sites (`selectAuthChoice` above, `ContentView.fillFromImported`) run
    /// only on a form that's already disconnected -- no live
    /// `lastConnectedConfig` there beyond what teardown already cleared --
    /// so they keep using the narrower `clearPassword()`.
    public func clearRetainedSecrets() {
        clearPassword()
        lastConnectedConfig = nil
    }

    /// User-initiated mode switch (picker): clears the secret so the
    /// password/passphrase doesn't carry over into the other mode.
    /// Programmatic restore (`connect(in:stored:)`) sets authChoice directly —
    /// without clearing (review finding M3c Task 0).
    public func selectAuthChoice(_ choice: AuthChoice) {
        guard choice != authChoice else { return }
        authChoice = choice
        clearPassword()
    }

    /// User-initiated flip of S3's "Start at the bucket list" toggle
    /// (2026-09-02, Task 4) — a COMMAND, not a value change, for the same
    /// reason `selectAuthChoice` above is one: turning it ON discards the
    /// bucket the user typed, because a bucket-list session carries no
    /// bucket out of the form (`S3FieldSchema.bucketToCarry`) and the field
    /// is hidden from that moment on.
    ///
    /// Without this the loss still happened — on SAVE, silently, minutes
    /// later, to a field the user could no longer see. Doing it at the flip
    /// puts the loss where its cause is.
    ///
    /// Turning it OFF clears nothing: the bucket is already empty, and the
    /// row the user is about to type into must not be touched. Called from
    /// `ConnectionFormView.interceptEdit`, which runs BEFORE the write, so
    /// the guard below still sees the old value — which is what makes a
    /// re-render's identical write a no-op rather than a wipe.
    public func selectBucketListMode(_ startsAtBucketList: Bool) {
        guard startsAtBucketList != values[bool: S3Field.startsAtBucketList] else { return }
        values[bool: S3Field.startsAtBucketList] = startsAtBucketList
        if startsAtBucketList {
            values[S3Field.bucket] = ""
        }
    }

    /// User-initiated mode switch (picker) for the JUMP's own auth choice
    /// (final review M-2): mirrors `selectAuthChoice` above -- clears
    /// `jumpPassword` so it doesn't carry over into the other mode instead
    /// of being silently reused as the wrong secret/passphrase.
    public func selectJumpAuthChoice(_ choice: AuthChoice) {
        guard choice != jumpAuthChoice else { return }
        jumpAuthChoice = choice
        jumpPassword = ""
    }

    /// User-initiated switch of the jump's login-MODE picker (M28 final
    /// review, Critical): the third of the jump's three switchers to get a
    /// clearing path, after `selectJumpAuthChoice` above and
    /// `selectJumpSourceMode` below -- and it needs one for exactly the reason
    /// `selectJumpSourceMode`'s doc comment gives for its own.
    ///
    /// In `.set` mode the jump's manual-looking fields are not typed by the
    /// user: the caller fills `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/
    /// `jumpPassword` from the selected login set before every submit
    /// (`SessionListViewModel.resolveJumpLoginSet`'s own `fillJumpForm`,
    /// M29-P2), because `validateJump`'s `.set` branch
    /// only checks that something is SELECTED and `buildJumpConfig` builds
    /// from those fields regardless of the mode. A submit that then fails
    /// validation leaves the form filled -- `endEditing()` does not run on
    /// that path -- so without this the SET's secret would sit pre-filled in
    /// the manual SecureField, ready for `buildJumpSpec`'s `.manual` arm to
    /// pair it with a fresh `secretID` and `updateSession` to write it into
    /// THIS session's own jump slot: a secret the user never typed and does
    /// not own.
    ///
    /// Clears on any actual change, like `selectJumpAuthChoice` and unlike
    /// `selectJumpSourceMode` (which clears only when leaving `.session`):
    /// the values filled from a set are as wrong for a manual jump as a
    /// manual password is for a set-bound one, whose secret lives under the
    /// SET's id and whose spec `updateSession` refuses to write a
    /// `jumpSecret` for at all (it writes only when `loginSetID` and
    /// `sessionID` are both nil). `jumpUsername` stays -- it is
    /// displayed, editable and not a credential, the same reason
    /// `selectJumpSourceMode` leaves it alone.
    ///
    /// Programmatic restore (`beginEditing`, `ContentView`'s connect fill and
    /// its raw jump fallback) assigns `jumpLoginMode` directly and must keep
    /// doing so -- same pattern as `selectAuthChoice`'s own doc comment.
    public func selectJumpLoginMode(_ mode: LoginMode) {
        guard mode != jumpLoginMode else { return }
        jumpLoginMode = mode
        jumpPassword = ""
        jumpKeyPath = ""
    }

    /// User-initiated switch of the jump's source picker (M-5 fix, final
    /// review): mirrors `selectAuthChoice`/`selectJumpAuthChoice` above --
    /// switching AWAY from `.session` clears `jumpPassword`/`jumpKeyPath`.
    /// `SessionListViewModel.resolveJumpSession` (M29-P2) fills both with the
    /// REFERENCED session's own resolved secret/key path right before a
    /// connect attempt; if that connect then fails and the user flips Source
    /// to Manual, the bastion's secret would otherwise sit pre-filled in the
    /// manual SecureField -- ready to be persisted into THIS session's own
    /// jump slot on the next save, a secret the user never typed and doesn't
    /// own. Programmatic restore (`beginEditing`) sets `jumpSourceMode`
    /// directly without going through here, same pattern as
    /// `selectAuthChoice`'s own doc comment.
    public func selectJumpSourceMode(_ mode: JumpSourceMode) {
        guard mode != jumpSourceMode else { return }
        let wasSession = jumpSourceMode == .session
        jumpSourceMode = mode
        if wasSession {
            jumpPassword = ""
            jumpKeyPath = ""
        }
    }

    /// Fills the form from a stored session for in-place editing. The secret
    /// is deliberately NEVER loaded from the keychain — `password` stays
    /// empty; an empty password at save time means "leave unchanged" (see
    /// `validateForEditSave`/`ContentView.onSaveEdited`).
    ///
    /// One reset plus one fill, for every protocol (M23/T7) — the read
    /// counterpart to `validateForEditSave`'s single `descriptor.apply`.
    public func beginEditing(_ stored: StoredSession) {
        editingOriginal = stored
        kind = stored.kind
        // Starting from the descriptor's edit baseline is what the
        // hand-written S3 and WebDAV `else` branches used to do field by
        // field: a previous S3 edit's bucket must not survive into this
        // (possibly SSH) session's form, because `kind` is itself a mode
        // switch. The `kind` setter's own reset above cannot carry this
        // alone -- it is guarded on an ACTUAL change, so two consecutive
        // edits of the same kind would keep the previous one's values.
        //
        // `editBaseline`, NOT `defaultValues`: this is the edit form, and
        // S3's default region is a new-form-only assumption
        // (`BackendDescriptor.editBaseline`'s doc comment) -- using
        // `defaultValues` here would let that assumed region survive into a
        // session whose S3 block is missing, and `validateForEditSave` would
        // then silently write it back out as if it had been the user's own.
        //
        // `sessionValues` returns the EMPTY bag for an `.s3`/`.webdav` session
        // whose stored block is missing (`session.s3`/`session.webdav` is
        // genuinely optional there), so merging it onto the baseline leaves a
        // blank form for those two -- the right answer for inconsistent data,
        // and better than the old `?? ""` fallbacks that silently produced a
        // half-filled one. Since M26 `.ssh` has the same gap, not a different
        // one: `SSHFieldSchema.values(from:)` guards on a missing
        // `session.ssh` and returns that same empty `FieldValues()` --
        // `StoredSession`'s inventing `host`/`port`/`username`/`authKind`
        // accessors that used to paper over this are gone. Merging the empty
        // bag here produces a blank SSH form the same way the other two
        // backends do, not by a separate route as before M26. `sessionValues`
        // also never copies `host`/`username` for a non-SSH session, which is
        // where the `"unused"` placeholder a legacy S3/WebDAV session still
        // carries used to enter the form.
        let descriptor = BackendDescriptor.descriptor(for: kind)
        values = descriptor.editBaseline
        values.merge(descriptor.sessionValues(stored))
        // The secret is deliberately NEVER loaded from the keychain: an empty
        // secret at save time means "leave unchanged" (see
        // `validateForEditSave`). `editBaseline` above already left every
        // secret field blank, so this is the assertion, not the action.
        password = ""
        saveName = stored.name
        selectedGroupID = stored.groupID
        tags = stored.tags
        // A referenced login set (M10b/T3) puts the form straight into Set
        // mode with that set preselected; a manual session goes to Manual
        // exactly as before — see the doc comment on `loginMode`.
        loginMode = stored.loginSetID != nil ? .set : .manual
        selectedLoginSetID = stored.loginSetID
        saveAsNewLoginSet = false
        newLoginSetName = ""
        // Jump host (M10c/T3): a remembered `JumpSpec` puts the block
        // straight into its own Set/Manual mode with that state prefilled --
        // mirrors the target's own loginSetID handling above. The jump's
        // password is likewise NEVER loaded from the keychain (same "empty
        // means unchanged" rule); `existingJumpSecretID` is remembered so
        // `validateForEditSave()` can reuse the SAME manual slot instead of
        // orphaning it under a freshly generated one.
        if let jump = stored.jump {
            jumpEnabled = true
            jumpHost = jump.host
            jumpPort = String(jump.port)
            jumpUsername = jump.username
            jumpAuthChoice = Self.authChoice(for: jump.authKind)
            jumpKeyPath = jump.keyPath ?? ""
            jumpPassword = ""
            jumpLoginMode = jump.loginSetID != nil ? .set : .manual
            jumpSelectedLoginSetID = jump.loginSetID
            existingJumpSecretID = jump.loginSetID == nil ? jump.secretID : nil
            // Session-mode prefill (M11a/T3): a referenced connection puts
            // the source switcher straight into `.session` with that
            // connection preselected, mirroring the target's own
            // `loginSetID` handling above -- takes priority over the
            // manual/set fields just prefilled, which stay as an inert data
            // carrier while `sessionID` is non-nil (see `JumpSpec.sessionID`'s
            // doc comment).
            jumpSourceMode = jump.sessionID != nil ? .session : .manual
            jumpSessionID = jump.sessionID
        } else {
            clearJumpFields()
        }
        mode = .edit(sessionID: stored.id)
        state = .idle
    }

    /// Leaves edit mode and resets the form to the same blank state the
    /// app's per-tab teardown leaves it in for a new connection. Built on
    /// `exitEditMode()` (mode + group reset) plus the full field reset —
    /// the two used to duplicate the mode handling (M6a).
    public func endEditing() {
        exitEditMode()
        // One reset instead of six assignments (M22/T8): `exitEditMode()` has
        // just put `kind` back to `.ssh`, so the descriptor's defaults are the
        // blank SSH form — host/username/secret empty, port 22, auth
        // `password` — plus a blank jump block.
        values = BackendDescriptor.descriptor(for: kind).defaultValues
        shouldSaveSession = false
        saveName = ""
        tags = []
        saveAsNewLoginSet = false
        newLoginSetName = ""
        state = .idle
    }

    /// Leaves edit mode WITHOUT touching the form fields. Three paths call
    /// this: the app's tab teardown, the sidebar's import fill
    /// (`fillFromImported`), and `endEditing()` above, which adds the full
    /// field reset for the form's Save/Cancel and the sidebar's "New
    /// connection" -- a reconnect reaches it only through that teardown. A
    /// stale `.edit` target surviving them would make a later Save overwrite
    /// the wrong stored session, while the field values are owned by
    /// whatever fills the form next.
    /// Jump fields reset entirely here rather than only in `endEditing()`
    /// (M10c/T3, same sticky-toggle lesson M10b learned for `loginMode`/
    /// `selectedLoginSetID` above): `jumpEnabled` is itself a MODE switch,
    /// so a stale "on" from a previous edit must not survive into whatever
    /// gets filled in next.
    ///
    /// `kind`/S3/WebDAV fields reset here too (M12/T7a, M21/T9, same
    /// lesson): `kind` is itself a MODE switch, so a stale `.s3`/`.webdav`
    /// from a previous edit must not survive into whatever gets filled in
    /// next -- a teardown, an import, or the next form the user opens.
    public func exitEditMode() {
        mode = .new
        editingOriginal = nil
        selectedGroupID = nil
        loginMode = .manual
        selectedLoginSetID = nil
        saveAsNewLoginSet = false
        newLoginSetName = ""
        clearJumpFields()
        // Setting `kind` resets `values` to the SSH defaults whenever it
        // actually changes (M22/T8), which is what the per-protocol field
        // clearing spelled out by hand here used to do. An unchanged `.ssh`
        // deliberately keeps its fields — see this method's own contract.
        kind = .ssh
    }

    /// Resets every jump-related field to its blank "no jump" state: the
    /// jump toggle, its host/port/login fields, the source switcher, and the
    /// internal existing-secret bookkeeping. The single source of truth for
    /// "no jump block survives here" — used by `exitEditMode()`,
    /// `beginEditing()`'s no-jump branch, the `kind` switch's own `didSet`,
    /// `ContentView.fillForm`'s own no-jump branch, and (via that file's
    /// `applyRawJumpFallback`) three of `fillForm`'s seven early-return
    /// failure paths, so a jump block typed for one session's form can never
    /// leak into another's.
    ///
    /// `jumpSourceMode`/`jumpSessionID` reset here too (M11a/T3, the same
    /// sticky-toggle lesson M10b learned for `loginMode`/
    /// `selectedLoginSetID`): the source switcher is itself a MODE switch, so
    /// a stale `.session` from a previous edit must not survive into
    /// whatever the caller fills in next.
    public func clearJumpFields() {
        jumpEnabled = false
        jumpHost = ""
        jumpPort = "22"
        jumpUsername = ""
        jumpAuthChoice = .password
        jumpKeyPath = ""
        jumpPassword = ""
        jumpLoginMode = .manual
        jumpSelectedLoginSetID = nil
        existingJumpSecretID = nil
        jumpSourceMode = .manual
        jumpSessionID = nil
    }

    /// Validates the form for saving a NEW session **without dialing**, and
    /// publishes a `.failed` state when it cannot be saved.
    ///
    /// Why this exists: saving a new session used to be reachable only
    /// through `connect()`. The rules live here (the save name) and in
    /// `resolveConfigWithoutDialing()` (the schema and the jump), but the
    /// only caller that ran them was the dial, so "save this connection"
    /// and "open this connection" were one act. A user with a connection
    /// already running who wants it remembered had no way to say so without
    /// opening a second one.
    ///
    /// The rules are exactly `connect()`'s, split the same way: the save
    /// name is a rule of THIS submission (see
    /// `resolveConfigWithoutDialing()`'s own doc comment for why it
    /// deliberately does not check it), everything else comes from the
    /// shared resolution — so a form that saves without dialing cannot
    /// accept something the dial would have refused, and vice versa.
    ///
    /// The resolved config is DISCARDED. This function answers "may this be
    /// written", not "what would be dialed": returning the config would put
    /// a plaintext secret in a caller's hands for no purpose, and
    /// `SessionSecretPolicy` reads the form directly at write time anyway.
    ///
    /// Edit mode has its own validator (`validateForEditSave()`) with a
    /// different secret rule — empty means "leave the stored one alone" —
    /// so this refuses outright rather than quietly doing the wrong one.
    public func validateForNewSave() -> Bool {
        guard case .new = mode else { return false }
        guard !saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(.failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName))
            return false
        }
        if case .failed(let failure) = resolveConfigWithoutDialing() {
            fail(failure)
            return false
        }
        state = .idle
        return true
    }

    /// Validates the form for saving an edited session and returns the updated
    /// `StoredSession`, or nil after publishing a `.failed` state.
    ///
    /// One body for every protocol since M23, and the place the `"unused"`
    /// placeholders died: the session is MUTATED through
    /// `descriptor.apply` rather than rebuilt, so a backend with no host and
    /// no user name simply leaves those fields alone instead of parking a
    /// literal there.
    ///
    /// The secret is deliberately NOT required here (`requireSecrets: false`),
    /// unlike `connect()`: edit mode leaves it blank to mean "keep the stored
    /// one", and requiring it would make every saved password session
    /// impossible to edit without retyping its password.
    public func validateForEditSave() -> StoredSession? {
        // `editingOriginal` is provably non-nil here, not merely unrelied-
        // upon: `mode` is `private(set)`, `beginEditing` is the only place
        // that sets `.edit`, and it sets `editingOriginal` first with nothing
        // between. A separate fallback that rebuilt a session for this
        // (unreachable) case used to live here; it silently produced a
        // half-built session and is worse than the nil return this guard
        // gives instead.
        guard case .edit = mode, var session = editingOriginal else { return nil }

        let trimmedName = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            fail(.failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName))
            return nil
        }
        let descriptor = BackendDescriptor.descriptor(for: kind)
        // M30: leaving Set mode is the one moment where an empty secret field
        // does NOT mean "leave the stored one unchanged". The stored one
        // belongs to a configuration the user is walking away from, so letting
        // it stand silently reactivates it on the next connect. Demanding the
        // secret here makes the write path overwrite that slot, which is why
        // this fix deletes nothing -- every earlier attempt deleted on BINDING
        // instead and was reverted for destroying the only copy of a
        // credential.
        //
        // Read from `editingOriginal`, not from the local `session` copy: that
        // copy is mutated further down, and reordering those mutations would
        // otherwise change this answer without touching this line.
        let leftLoginSet = editingOriginal?.loginSetID != nil && loginMode == .manual
        if let violation = descriptor.firstViolation(in: values, requireSecrets: leftLoginSet) {
            fail(.failed(
                message: CoreL10n.string(violation.messageKey),
                field: .schema(violation.fieldKey)))
            return nil
        }
        // M30: the jump's own half of the rule above. Its `loginSetID` and
        // its `secretID` slot mirror the session's, so it has the same way
        // back into a stale credential. A session-mode jump cannot reach this
        // at all -- `validateJump` returns early for it, and such a jump owns
        // no secret. Outside that transition the requirement stays false, for
        // the reason `validateJump`'s own doc comment gives.
        let jumpLeftLoginSet = editingOriginal?.jump?.loginSetID != nil && jumpLoginMode == .manual
        if let jumpFailure = validateJump(requireSecret: jumpLeftLoginSet) {
            fail(jumpFailure)
            return nil
        }

        // Mutating the ORIGINAL (bound by the guard above) is what carries
        // group, login-set binding and the other backends' blocks forward.
        session.name = trimmedName
        session.kind = kind
        // Clearing the whole SSH block replaces the `host`/`username` reset
        // this needed before M23/T8: SSH's fields live in `ssh` now, so a
        // non-SSH session simply has none to blank, and a stale host left
        // behind by switching `kind` away from SSH during this very edit goes
        // with the block. SSH's own `apply` recreates it below.
        if kind != .ssh {
            session.ssh = nil
        }
        session.groupID = selectedGroupID
        session.loginSetID = loginMode == .set ? selectedLoginSetID : nil
        session.tags = tags
        descriptor.apply(values, &session)
        // AFTER `apply`, which is what creates the SSH block. A jump is an SSH
        // concept and lives inside it, so a non-SSH session correctly keeps
        // none rather than storing a hop nothing dials.
        session.ssh?.jump = buildJumpSpec(existingSecretID: existingJumpSecretID)

        state = .idle
        return session
    }

    /// Validates the optional jump block (M10c/T3, spec §3) when
    /// `jumpEnabled`: host non-empty, port numeric, and per `jumpLoginMode`
    /// either a selected login set or manual username + password/key-path
    /// (matching `jumpAuthChoice`) -- the exact same shape `connect()`
    /// enforces for the target's own fields, just for the jump's. Returns
    /// the `.failed` state to publish, or `nil` when the jump is off or
    /// fully valid. Shared between `connect()` and `validateForEditSave()`
    /// so both surfaces enforce identical rules.
    ///
    /// Set mode only checks that a set is actually SELECTED here -- like the
    /// target's own `loginMode == .set` path, it trusts the caller to have
    /// already filled `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/
    /// `jumpPassword` from that set
    /// (`SessionListViewModel.resolveJumpLoginSet`'s fill-before-submit
    /// pattern, M29-P2) before calling into this validator; a DANGLING set
    /// reference is that caller's concern (spec §4a/§4c), not this view
    /// model's -- it has no access to the actual `LoginSet` data.
    ///
    /// `requireSecret` (final review I-1): `connect()` passes `true` -- a
    /// live connection needs an actual password/passphrase in hand.
    /// `validateForEditSave()` passes `false`, because edit mode deliberately
    /// leaves `jumpPassword` empty to mean "unchanged" (see `beginEditing`);
    /// requiring it there would make a session with a manual password jump
    /// impossible to save without retyping the jump secret. Mirrors the
    /// asymmetry `connect()`/`validateForEditSave()` already have for the
    /// TARGET's own password (the latter never checks `password` at all).
    ///
    /// Session mode (M11a/T3, spec §3) branches FIRST and returns early: the
    /// only requirement is a selection (`jumpSessionID != nil`); every
    /// manual check below (host/port/login) is skipped entirely, since the
    /// jump's own host/port/login fields are inert data carriers in this
    /// mode — the App layer resolves the reference and fills them from the
    /// referenced session right before `connect()`/save (spec §4a/§4c), and
    /// the eligibility/chain rules are enforced by the resolver at that
    /// point, not here.
    private func validateJump(requireSecret: Bool) -> State? {
        guard jumpEnabled else { return nil }
        if jumpSourceMode == .session {
            guard jumpSessionID != nil else {
                return .failed(
                    message: CoreL10n.string("core.connect.jumpSessionRequired"), field: .jumpSession)
            }
            return nil
        }
        guard !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(message: CoreL10n.string("core.connect.jumpHostEmpty"), field: .jumpHost)
        }
        guard Int(jumpPort.trimmingCharacters(in: .whitespaces)) != nil else {
            return .failed(message: CoreL10n.string("core.connect.jumpPortNumeric"), field: .jumpPort)
        }
        switch jumpLoginMode {
        case .set:
            guard jumpSelectedLoginSetID != nil else {
                // No Field case exists for the picker (final review M-3);
                // `.jumpHost` would misleadingly outline the host field.
                return .failed(message: CoreL10n.string("core.connect.jumpSetRequired"), field: nil)
            }
        case .manual:
            guard !jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(message: CoreL10n.string("core.connect.jumpUsernameEmpty"), field: .jumpUsername)
            }
            switch jumpAuthChoice {
            case .password:
                if requireSecret {
                    guard !jumpPassword.isEmpty else {
                        return .failed(
                            message: CoreL10n.string("core.connect.jumpPasswordEmpty"), field: .jumpPassword)
                    }
                }
            case .privateKey:
                guard !jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failed(
                        message: CoreL10n.string("core.connect.jumpKeyPathEmpty"), field: .jumpKeyPath)
                }
            case .agent:
                break // Agent mode needs neither a secret nor a key path, regardless of requireSecret.
            }
        }
        return nil
    }

    /// Builds `SSHConnectionConfig.Jump` for `connect()` from the jump's
    /// manual-looking fields, or `nil` when the jump toggle is off. Built
    /// unconditionally from `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/
    /// `jumpPassword` regardless of `jumpLoginMode` -- exactly like the
    /// target's own `auth` above ignores `loginMode`, trusting the App layer
    /// to have already filled those fields from the selected set in Set
    /// mode. `validateJump()` has already guaranteed these are non-empty
    /// where required, so this never needs to fail -- true because its
    /// direct caller `attachingJump(to:)` is reached only through
    /// `resolveConfigWithoutDialing()`, which always validates with
    /// `requireSecret: true` no matter which of its callers invoked it (see
    /// `validateJump`'s own doc comment).
    private func buildJumpConfig() -> SSHConnectionConfig.Jump? {
        guard jumpEnabled else { return nil }
        let auth: SSHConnectionConfig.AuthMethod
        switch jumpAuthChoice {
        case .password:
            auth = .password(jumpPassword)
        case .privateKey:
            auth = .privateKey(
                keyPath: jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                passphrase: jumpPassword.isEmpty ? nil : jumpPassword)
        case .agent:
            auth = .agent
        }
        return SSHConnectionConfig.Jump(
            host: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(jumpPort.trimmingCharacters(in: .whitespaces)) ?? 22,
            username: jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth)
    }

    /// Builds the jump's `StoredSession.JumpSpec` for `validateForEditSave()`,
    /// or `nil` when the jump toggle is off. Public so `ContentView`'s
    /// NEW-session save path (`SessionListViewModel.save(jump:jumpSecret:)`)
    /// can build the identical spec this validator builds internally for the
    /// EDIT-save path (`updateSession(_:newSecret:jumpSecret:)`), instead of
    /// duplicating the field-mapping logic in the App layer.
    ///
    /// Set mode carries only `loginSetID` (no manual credentials -- the set
    /// owns them, same as the target's own `loginSetID` branch above); manual
    /// mode carries the manual-looking jump fields. `existingSecretID`, when
    /// non-nil, is reused for a still-manual jump so an empty `jumpPassword`
    /// ("leave unchanged") keeps resolving to the SAME keychain slot instead
    /// of orphaning it under a freshly generated one -- `validateForEditSave`
    /// passes its own remembered `existingJumpSecretID`; a brand-new
    /// session's save path passes `nil` (there is no previous secret to
    /// preserve).
    ///
    /// Session mode (M11a/T3, spec §3): `sessionID` is stamped onto whichever
    /// shape the switch below produces -- the manual/set fields it also
    /// carries are ignored by the resolver once `sessionID` is non-nil (see
    /// `LoginResolver.resolveJump(...sessions:...)`), so they're left exactly
    /// as computed, unchanged, purely as an inert data carrier (spec §1);
    /// which branch fires doesn't matter for correctness, only which fields
    /// end up along for the ride -- EXCEPT `loginSetID`, which the `.set`
    /// branch below forces to `nil` whenever `sessionID` is non-nil (F-1 fix,
    /// final review): a stale login-set selection surviving a switch to
    /// session mode must never coexist with `sessionID`, or
    /// `sessionsUsing(setID:)` and `deleteLoginSet` would both mistake this
    /// jump for a login-set reference.
    public func buildJumpSpec(existingSecretID: UUID? = nil) -> StoredSession.JumpSpec? {
        guard jumpEnabled else { return nil }
        let trimmedHost = jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portNumber = Int(jumpPort.trimmingCharacters(in: .whitespaces)) ?? 22
        let authKind = Self.storedAuthKind(for: jumpAuthChoice)
        let trimmedUsername = jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKeyPath = jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let referencedSessionID = jumpSourceMode == .session ? jumpSessionID : nil
        // Session mode (F-1 fix, final review): `loginSetID` must be nil
        // whenever `sessionID` is non-nil -- carrying a stale login-set
        // selection alongside a session reference would inflate
        // `sessionsUsing(setID:)`'s usage count and let `deleteLoginSet`
        // write a secret into this jump's otherwise-unused `secretID` slot
        // (see both call sites' own hardening below). Mirrors the
        // restoration path (`beginEditing`, spec §4), which never lets the
        // two coexist either.
        switch jumpLoginMode {
        case .set:
            return StoredSession.JumpSpec(
                host: trimmedHost, port: portNumber, username: trimmedUsername,
                authKind: authKind,
                keyPath: jumpAuthChoice == .privateKey ? trimmedKeyPath : nil,
                loginSetID: referencedSessionID == nil ? jumpSelectedLoginSetID : nil,
                sessionID: referencedSessionID)
        case .manual:
            return StoredSession.JumpSpec(
                host: trimmedHost, port: portNumber, username: trimmedUsername,
                authKind: authKind,
                keyPath: jumpAuthChoice == .privateKey ? trimmedKeyPath : nil,
                loginSetID: nil,
                secretID: existingSecretID ?? UUID(),
                sessionID: referencedSessionID)
        }
    }

    static func failedState(
        for error: Error, jumpEnabled: Bool = false, jumpKeyPath: String = "",
        jumpAuthChoice: AuthChoice = .password
    ) -> State {
        switch error {
        case SSHConnectionConfig.ConfigError.emptyHost:
            return .failed(message: CoreL10n.string("core.connect.emptyHost"), field: Self.sshField(.host))
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return .failed(message: CoreL10n.string("core.connect.emptyUsername"), field: Self.sshField(.username))
        // Host/username whitelist ConfigErrors (M11d final review, C-1):
        // defense in depth mirroring the jump-side whitelist below -- a UI
        // submission should never reach these either, but `SSHConnectionConfig`'s
        // init re-checks unconditionally.
        case SSHConnectionConfig.ConfigError.invalidHost:
            return .failed(message: CoreL10n.string("core.connect.hostInvalid"), field: Self.sshField(.host))
        case SSHConnectionConfig.ConfigError.invalidUsername:
            return .failed(message: CoreL10n.string("core.connect.usernameInvalid"), field: Self.sshField(.username))
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.invalidPort %@"), String(port)),
                field: Self.sshField(.port))
        case SSHConnectionConfig.ConfigError.emptyKeyPath:
            return .failed(message: CoreL10n.string("core.connect.keyPathEmpty"), field: Self.sshField(.keyPath))
        // Jump ConfigErrors (M10c/T3): defense-in-depth mirrors of
        // `validateJump()` above -- a UI submission never reaches these
        // (the form already validated), but `SSHConnectionConfig`'s own init
        // re-checks unconditionally, so every one of its errors needs a
        // mapping here too.
        case SSHConnectionConfig.ConfigError.emptyJumpHost:
            return .failed(message: CoreL10n.string("core.connect.jumpHostEmpty"), field: .jumpHost)
        case SSHConnectionConfig.ConfigError.emptyJumpUsername:
            return .failed(message: CoreL10n.string("core.connect.jumpUsernameEmpty"), field: .jumpUsername)
        case SSHConnectionConfig.ConfigError.invalidJumpPort(let port):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.invalidJumpPort %@"), String(port)),
                field: .jumpPort)
        case SSHConnectionConfig.ConfigError.emptyJumpKeyPath:
            return .failed(message: CoreL10n.string("core.connect.jumpKeyPathEmpty"), field: .jumpKeyPath)
        // Jump host/username whitelist ConfigErrors (M11d final review,
        // C-1): `ssh -J` turns a jump host into an implicit `ProxyCommand`
        // it executes via `/bin/sh -c` WITHOUT validating it for shell
        // metacharacters, so a comma-only guard was not enough -- rejected
        // at the one source of Jump validation, same as every other jump
        // field above.
        case SSHConnectionConfig.ConfigError.invalidJumpHost:
            return .failed(message: CoreL10n.string("core.connect.jumpHostInvalid"), field: .jumpHost)
        case SSHConnectionConfig.ConfigError.invalidJumpUsername:
            return .failed(message: CoreL10n.string("core.connect.jumpUsernameInvalid"), field: .jumpUsername)
        // Jump auth failure (M10c/T1 review hand-off): highlights the JUMP
        // password field instead of the target's -- `.authenticationFailed`
        // above stays the target-only case.
        case RemoteFSError.jumpAuthenticationFailed:
            return .failed(message: CoreL10n.string("core.connect.jumpAuthFailed"), field: .jumpPassword)
        case RemoteFSError.authenticationFailed:
            return .failed(
                message: CoreL10n.string("core.connect.authFailed"),
                field: nil)
        // The two S3 bucket-list outcomes (2026-09-02), both reachable ONLY
        // with `startsAtBucketList` on.
        //
        // `.bucketListEmpty` is connect-time only — `connect` is its single
        // thrower. `.bucketListForbidden` is NOT (Task 3 review, M-3):
        // `listBuckets` runs again whenever `/` is listed and on a `stat` of
        // a bucket, so a revoked policy can raise it mid-session, where
        // `RemoteBrowserViewModel.message(for:path:)` renders it instead of
        // this function.
        //
        // `.bucketListForbidden` is deliberately NOT `authFailed` above: the
        // credentials are good and one permission is missing, so the fix is
        // the toggle — which is the row this highlights. `.bucketListEmpty`
        // blames no row, because nothing in the form is wrong: the account
        // has no buckets.
        case RemoteFSError.bucketListForbidden:
            return .failed(
                message: CoreL10n.string("core.connect.s3BucketListForbidden"),
                field: Self.s3Field(.startsAtBucketList))
        case RemoteFSError.bucketListEmpty:
            return .failed(
                message: CoreL10n.string("core.connect.s3BucketListEmpty"),
                field: nil)
        // Jump host refusing TCP forwarding (M10c/T1 review hand-off,
        // finding 2): Citadel/NIOSSH surfaces this as a plain
        // `connectionFailed(reason:)` whose text contains
        // "channelSetupRejected" -- caught here, ONLY while a jump is
        // configured, so a matching reason on a direct (no-jump) connection
        // still falls through to the generic message below.
        case RemoteFSError.connectionFailed(let reason)
            where jumpEnabled && reason.contains("channelSetupRejected"):
            return .failed(message: CoreL10n.string("core.connect.jumpTunnelRejected"), field: nil)
        case RemoteFSError.connectionFailed(let reason):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.connectionFailed %@"), reason),
                field: nil)
        // Agent errors (M10d/T4): `.socketUnavailable`/`.noIdentities` are
        // their OWN honest, localized conditions (spec §2/§5) -- never
        // stringified into the generic connectionFailed text below. Neither
        // case carries a hop tag (`mapStageAware` deliberately returns the
        // SAME `AgentError` type for a jump-hop failure as for a target-hop
        // one -- see its doc comment), so the field is attributed from the
        // form's OWN state instead of the error: a jump configured for
        // `.agent` auth establishes and lists its agent identities BEFORE
        // the target ever does (`CitadelFileSystem.connect`'s jump-first
        // ordering), so whenever the jump itself uses `.agent` this error
        // can only have come from there. `.jumpUsername` (not
        // `.jumpPassword`/`.jumpKeyPath`) is the row that stays VISIBLE in
        // agent mode -- highlighting a hidden secret row would give the
        // user no feedback at all.
        case AgentError.socketUnavailable:
            return .failed(
                message: CoreL10n.string("core.connect.agentSocketUnavailable"),
                field: (jumpEnabled && jumpAuthChoice == .agent) ? .jumpUsername : nil)
        case AgentError.noIdentities:
            return .failed(
                message: CoreL10n.string("core.connect.agentNoIdentities"),
                field: (jumpEnabled && jumpAuthChoice == .agent) ? .jumpUsername : nil)
        case AgentError.noUsableIdentities:
            return .failed(
                message: CoreL10n.string("core.connect.agentNoUsableIdentities"),
                field: (jumpEnabled && jumpAuthChoice == .agent) ? .jumpUsername : nil)
        // `.refused` (agent said no to every offered identity) and
        // `.protocolError` (transport/parsing misbehaved) aren't honest
        // "fix your setup" conditions the way the two cases above are --
        // they fall back to the same generic connect-failure text every
        // other unclassified error uses, reason interpolated (spec/brief
        // point 3). `field: nil` throughout: unlike the two cases above,
        // these can equally originate from either hop, and there's no
        // ordering guarantee to lean on.
        case AgentError.refused:
            return .failed(
                message: String(
                    format: CoreL10n.string("core.connect.connectionFailed %@"),
                    String(describing: AgentError.refused)),
                field: nil)
        case AgentError.protocolError(let reason):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.connectionFailed %@"), reason),
                field: nil)
        case SSHKeyError.fileNotFound(let path):
            // Jump key vs. target key (M10c/T1 review hand-off, finding 1):
            // both surface as the same bare `fileNotFound(path:)` -- compare
            // the path against the jump's OWN key path to tell which one
            // actually failed to load, so the form highlights the right row.
            let isJumpKey = jumpEnabled && !jumpKeyPath.isEmpty && path == jumpKeyPath
            return .failed(
                message: String(format: CoreL10n.string("core.connect.keyNotFound %@"), path),
                field: isJumpKey ? .jumpKeyPath : Self.sshField(.keyPath))
        case SSHKeyError.passphraseRequired:
            return .failed(
                message: CoreL10n.string("core.connect.keyPassphraseRequired"),
                // `passphrase`, not `password`: both key-passphrase errors can
                // only arise under private-key auth, and the passphrase row is
                // the secret row VISIBLE there. The App used to derive this
                // from `authChoice` inside `failedFieldID`; the key says it now.
                field: Self.sshField(.passphrase))
        case SSHKeyError.wrongPassphrase:
            return .failed(message: CoreL10n.string("core.connect.keyWrongPassphrase"), field: Self.sshField(.passphrase))
        // `typeNotLoadable`/`pemNotSupported` (Task 1) carry only an algorithm
        // name or nothing at all -- no `path`, unlike `fileNotFound` above --
        // so the jump/target hop can't be told apart the way `fileNotFound`
        // does (comparing the error's own path against `jumpKeyPath`). Nor
        // does the `AgentError.socketUnavailable`/`.noIdentities` trick above
        // apply: those two attribute purely from `jumpAuthChoice` because a
        // dead agent socket or an empty identity list is a fact about the ONE
        // shared agent, true for every hop alike, so whichever hop tries it
        // first (the jump, per `CitadelFileSystem.connect`'s jump-first
        // ordering, if the jump itself uses `.agent`) is guaranteed to be the
        // one that hits it. A bad key FILE is the opposite: a per-hop fact.
        // If both hops used `.privateKey` and it was the target's file whose
        // type is not loadable while the jump's own file loaded fine,
        // attributing by `jumpAuthChoice` alone would blame the jump. That is
        // exactly the shape `AgentError.refused`/`.protocolError` are kept
        // OUT of the jump-attributed cases for, by the comment above:
        // "these can equally originate from either hop, and there's no
        // ordering guarantee to lean on." These two follow that precedent --
        // with one difference: `.refused`/`.protocolError` use `field: nil`,
        // while these two still use `.keyPath`. The row it outlines is the
        // TARGET's key path, the common single-hop case where there is no
        // jump host to misattribute to in the first place. The imprecision
        // this comment describes is narrower than a wrong field, not zero:
        // with a jump host whose OWN key file is the unloadable one, this
        // error can still originate at the jump hop while the target's row is
        // the one that gets outlined.
        case SSHKeyError.typeNotLoadable(let algorithm):
            // No RSA note any more. It existed because an RSA key FILE could
            // not be loaded at all and the user's only remaining route was the
            // agent, where an RSA identity does collide on wire tag against
            // Go-based servers (`AgentBackedPrivateKey.swift:92-115`). Since
            // the loader loads RSA files directly, RSA never reaches this case,
            // and a note about the agent route on an error the agent route
            // cannot produce was advice pointing at nothing.
            return .failed(
                message: String(
                    format: CoreL10n.string("core.connect.keyTypeNotLoadable %@"), algorithm),
                field: Self.sshField(.keyPath))
        case SSHKeyError.pemNotSupported:
            return .failed(
                message: CoreL10n.string("core.connect.keyPEMNotSupported"),
                field: Self.sshField(.keyPath))
        case SSHKeyError.unsupportedFormat:
            return .failed(
                message: CoreL10n.string("core.connect.keyUnsupportedFormat"),
                field: Self.sshField(.keyPath))
        case HostKeyError.mismatch(let host, let expected, let presented):
            return .failed(
                message: String(
                    format: CoreL10n.string("core.hostkey.mismatch %@ %@ %@"),
                    host, expected, presented),
                field: nil)
        case HostKeyError.rejectedByUser:
            return .failed(message: CoreL10n.string("core.hostkey.rejected"), field: nil)
        // Server-certificate TOFU (M21/T10): mirrors the two `HostKeyError`
        // cases immediately above, case for case. `.mismatch` is a hard stop
        // that already never reached the App's certificate decider
        // (`WebDAVSessionDelegate.decideCertificate` refuses before
        // consulting it) -- this is only the message the user sees once the
        // refusal has already happened, never a question. `.rejectedByUser`
        // is the plain "you clicked Cancel" case. `.trustStoreUnreadable`
        // has no `HostKeyError` analogue (the known-hosts store has always
        // failed closed silently); it gets its own honest text rather than
        // falling into the generic `default:` unexpected-error case below.
        case ServerCertificateError.mismatch(let host, let expected, let presented):
            return .failed(
                message: String(
                    format: CoreL10n.string("core.certificate.mismatch %@ %@ %@"),
                    host, expected, presented),
                field: nil)
        case ServerCertificateError.rejectedByUser:
            return .failed(message: CoreL10n.string("core.certificate.rejected"), field: nil)
        case ServerCertificateError.trustStoreUnreadable:
            return .failed(message: CoreL10n.string("core.certificate.trustStoreUnreadable"), field: nil)
        default:
            return .failed(
                message: String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error)),
                field: nil)
        }
    }
}
