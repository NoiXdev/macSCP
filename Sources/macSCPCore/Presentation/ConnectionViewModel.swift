import Foundation
import Observation

/// State and logic of the connection form.
/// The connector is injectable: production uses CitadelFileSystem.connect,
/// tests use a mock — the view model stays testable without a network.
@Observable
@MainActor
public final class ConnectionViewModel {
    /// The form field whose validation failed — the UI highlights it in red.
    public enum Field: Equatable, Sendable {
        case host
        case port
        case username
        case password
        case saveName
        case keyPath
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

    public enum State: Equatable {
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

    public typealias Connector = @Sendable (
        SSHConnectionConfig, @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) async throws -> any RemoteFileSystem

    /// State while waiting for the user's decision on an unknown host key
    /// (see `resolveHostKeyPrompt`).
    public struct HostKeyPrompt: Equatable {
        public let candidate: HostKeyCandidate
    }

    public var host: String = ""
    public var port: String = "22"
    public var username: String = ""
    public var password: String = ""
    public var authChoice: AuthChoice = .password
    public var keyPath: String = ""
    /// Save the session after a successful connect (store + keychain)?
    public var shouldSaveSession: Bool = false
    public var saveName: String = ""
    /// Group assignment shown by the picker — applies while saving a new
    /// session (`shouldSaveSession == true`) AND while editing a stored one.
    public var selectedGroupID: UUID?
    /// Three-way login switcher state (M10b/T3). The App layer reads this to
    /// decide whether to show the login-set picker or the manual
    /// username/password/key fields; it also fills `username`/`authChoice`/
    /// `keyPath`/`password` from the selected set right before connect/save
    /// (`ContentView.fillForm(_:from:)`), so those fields still carry the
    /// values the rest of this view model already knows how to validate and
    /// connect with — `.set` needs no separate connect/validate path here.
    public var loginMode: LoginMode = .manual
    /// The chosen login set in `.set` mode, `nil` while none is selected yet.
    public var selectedLoginSetID: UUID?
    /// Manual mode only: "Save as new login set" toggle (M10b/T3) — the App
    /// layer creates the set from the current fields before persisting the
    /// session, then attaches its id as `loginSetID`.
    public var saveAsNewLoginSet: Bool = false
    /// Name for the new set created by `saveAsNewLoginSet`; an empty value
    /// falls back to `SessionListViewModel.suggestedSetName(forUsername:)`.
    public var newLoginSetName: String = ""

    /// Jump host block (M10c/T3, mockup section 2): an optional intermediate
    /// hop the connection tunnels through. Off by default -- a brand-new
    /// form connects directly, exactly as before this feature existed.
    public var jumpEnabled: Bool = false
    public var jumpHost: String = ""
    public var jumpPort: String = "22"
    public var jumpUsername: String = ""
    /// Password (or key passphrase, in `.privateKey` mode) for the jump's
    /// OWN manual credentials -- same dual role as `password` above.
    public var jumpPassword: String = ""
    public var jumpKeyPath: String = ""
    public var jumpAuthChoice: AuthChoice = .password
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

    /// The jump's existing MANUAL keychain slot when editing a session that
    /// already had one (M10c/T3), remembered by `beginEditing` so
    /// `validateForEditSave()` can reuse the SAME `secretID` in
    /// `buildJumpSpec(existingSecretID:)` -- otherwise leaving `jumpPassword`
    /// empty ("leave unchanged") would resolve against a freshly generated,
    /// never-written slot instead of the one that actually holds the secret.
    /// `nil` for a brand-new jump, or when the session had no jump / a
    /// set-mode jump (no manual slot to preserve either way).
    private var existingJumpSecretID: UUID?

    public private(set) var state: State = .idle
    /// `.new` while the form creates a connection; `.edit` while it edits a
    /// stored session (see `beginEditing`/`endEditing`).
    public private(set) var mode: FormMode = .new
    /// While non-nil: the form UI shows the fingerprint card and waits for
    /// `resolveHostKeyPrompt`.
    public private(set) var hostKeyPrompt: HostKeyPrompt?

    private let connector: Connector
    /// Holds the continuation that the host-key decider places on `connect()`,
    /// until `resolveHostKeyPrompt` fulfills it. Stays private — the UI only
    /// knows `hostKeyPrompt` and `resolveHostKeyPrompt(trust:)`.
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Maps the form's `AuthChoice` to the persisted `StoredSession.AuthKind`
    /// (M10d/T3) -- the single place both the target's and the jump's
    /// choice-to-kind mapping go through, so a third auth kind only needs
    /// updating here instead of at every call site. Public (M10d/T4): the
    /// App layer's own three-way mappings (login-set prefill, "save as new
    /// login set", edit-session prefill) reuse this SAME mapping instead of
    /// re-deriving their own two-way `.privateKey ? : .password` ternary that
    /// would silently misdisplay `.agent` as `.password`.
    public static func storedAuthKind(for choice: AuthChoice) -> StoredSession.AuthKind {
        switch choice {
        case .password: return .password
        case .privateKey: return .privateKey
        case .agent: return .agent
        }
    }

    /// The reverse of `storedAuthKind(for:)` -- used by `beginEditing` to
    /// prefill the form's auth choice (target and jump) from a persisted
    /// `AuthKind`. Public (M10d/T4): same App-layer reuse rationale as
    /// `storedAuthKind(for:)` above.
    public static func authChoice(for kind: StoredSession.AuthKind) -> AuthChoice {
        switch kind {
        case .password: return .password
        case .privateKey: return .privateKey
        case .agent: return .agent
        }
    }

    /// Returns the connected file system or nil; errors land in `state`.
    /// Re-entrancy safe: calls made while `.connecting` are dropped, so a
    /// double-click doesn't open a second (orphaned) connection.
    public func connect() async -> (any RemoteFileSystem)? {
        guard state != .connecting else { return nil }
        defer { hostKeyPrompt = nil }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port)
            return nil
        }
        switch authChoice {
        case .password:
            guard !password.isEmpty else {
                state = .failed(message: CoreL10n.string("core.connect.passwordEmpty"), field: .password)
                return nil
            }
        case .privateKey:
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .failed(message: CoreL10n.string("core.connect.keyPathEmpty"), field: .keyPath)
                return nil
            }
        case .agent:
            break // Agent mode needs neither a password nor a key path.
        }
        if let jumpFailure = validateJump(requireSecret: true) {
            state = jumpFailure
            return nil
        }
        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName)
            return nil
        }
        do {
            let auth: SSHConnectionConfig.AuthMethod
            switch authChoice {
            case .password:
                auth = .password(password)
            case .privateKey:
                auth = .privateKey(
                    keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                    passphrase: password.isEmpty ? nil : password)
            case .agent:
                auth = .agent
            }
            let config = try SSHConnectionConfig(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: auth,
                jump: buildJumpConfig()
            )
            state = .connecting
            let fs = try await connector(config) { [weak self] candidate in
                await self?.presentHostKeyPrompt(for: candidate) ?? false
            }
            state = .idle
            return fs
        } catch {
            state = Self.failedState(
                for: error, jumpEnabled: jumpEnabled,
                jumpKeyPath: jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                jumpAuthChoice: jumpAuthChoice)
            return nil
        }
    }

    /// Decider side: publishes the prompt and suspends on a continuation
    /// until `resolveHostKeyPrompt` fulfills it.
    /// Cancellation-safe: if the connect() task is cancelled while the prompt
    /// is open, the continuation resolves with `false` (no leak, no hang);
    /// the connector sees a rejection.
    private func presentHostKeyPrompt(for candidate: HostKeyCandidate) async -> Bool {
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
        state = .failed(message: message, field: field)
    }

    /// Removes the plaintext password from the state (e.g. after disconnecting).
    public func clearPassword() {
        password = ""
    }

    /// User-initiated mode switch (picker): clears the secret so the
    /// password/passphrase doesn't carry over into the other mode.
    /// Programmatic restore (connectStored) sets authChoice directly —
    /// without clearing (review finding M3c Task 0).
    public func selectAuthChoice(_ choice: AuthChoice) {
        guard choice != authChoice else { return }
        authChoice = choice
        clearPassword()
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

    /// User-initiated switch of the jump's source picker (M-5 fix, final
    /// review): mirrors `selectAuthChoice`/`selectJumpAuthChoice` above --
    /// switching AWAY from `.session` clears `jumpPassword`/`jumpKeyPath`.
    /// `resolveSelectedJumpSession` (App layer) fills both with the
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
    public func beginEditing(_ stored: StoredSession) {
        host = stored.host
        port = String(stored.port)
        username = stored.username
        authChoice = Self.authChoice(for: stored.authKind)
        keyPath = stored.keyPath ?? ""
        saveName = stored.name
        selectedGroupID = stored.groupID
        password = ""
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
        host = ""
        port = "22"
        username = ""
        password = ""
        authChoice = .password
        keyPath = ""
        shouldSaveSession = false
        saveName = ""
        saveAsNewLoginSet = false
        newLoginSetName = ""
        state = .idle
    }

    /// Leaves edit mode WITHOUT touching the form fields. The app's tab
    /// teardown and every sidebar-navigation path (connect stored, import
    /// fill, disconnect) call this: a stale `.edit` target surviving those
    /// paths would make a later Save overwrite the wrong stored session,
    /// while the field values are owned by the caller (teardown/connect set
    /// them explicitly right after).
    /// Jump fields reset entirely here rather than only in `endEditing()`
    /// (M10c/T3, same sticky-toggle lesson M10b learned for `loginMode`/
    /// `selectedLoginSetID` above): `jumpEnabled` is itself a MODE switch,
    /// so a stale "on" from a previous edit must not survive into whatever
    /// the caller (teardown/connectStored/import) fills in next.
    public func exitEditMode() {
        mode = .new
        selectedGroupID = nil
        loginMode = .manual
        selectedLoginSetID = nil
        saveAsNewLoginSet = false
        newLoginSetName = ""
        clearJumpFields()
    }

    /// Resets every jump-related field to its blank "no jump" state: the
    /// jump toggle, its host/port/login fields, the source switcher, and the
    /// internal existing-secret bookkeeping. The single source of truth for
    /// "no jump block survives here" — used by `exitEditMode()`,
    /// `beginEditing()`'s no-jump branch, and (via `ContentView`'s
    /// `applyRawJumpFallback`) both of `connect(in:stored:)`'s early-return
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

    /// Validates the form for saving an edited session (password may be
    /// empty — unlike `connect()`) and, on success, returns the rebuilt
    /// `StoredSession` carrying the id from `mode`. On failure sets `state`
    /// to `.failed` with the same `core.connect.*` messages/fields as
    /// `connect()` and returns nil.
    public func validateForEditSave() -> StoredSession? {
        guard case .edit(let sessionID) = mode else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            state = .failed(message: CoreL10n.string("core.connect.emptyHost"), field: .host)
            return nil
        }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port)
            return nil
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            state = .failed(message: CoreL10n.string("core.connect.emptyUsername"), field: .username)
            return nil
        }
        let trimmedName = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            state = .failed(message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName)
            return nil
        }
        let trimmedKeyPath = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if authChoice == .privateKey {
            guard !trimmedKeyPath.isEmpty else {
                state = .failed(message: CoreL10n.string("core.connect.keyPathEmpty"), field: .keyPath)
                return nil
            }
        }
        // requireSecret: false (final review I-1) -- edit mode deliberately
        // leaves `jumpPassword` empty ("unchanged", see `beginEditing`);
        // requiring it here would make a session with a manual password jump
        // impossible to save without retyping the jump secret. Safe because
        // `onConnectEdited` (ContentView.swift) re-reads the persisted
        // session and resolves the jump secret from the keychain, mirroring
        // the target's own connect-vs-edit password asymmetry above.
        if let jumpFailure = validateJump(requireSecret: false) {
            state = jumpFailure
            return nil
        }
        state = .idle
        return StoredSession(
            id: sessionID,
            name: trimmedName,
            host: trimmedHost,
            port: portNumber,
            username: trimmedUsername,
            authKind: Self.storedAuthKind(for: authChoice),
            keyPath: authChoice == .privateKey ? trimmedKeyPath : nil,
            groupID: selectedGroupID,
            // Set mode (M10b/T3): the session references the selected set
            // instead of carrying its own credentials. `ContentView` fills
            // username/authChoice/keyPath from that set before this
            // validator runs, so the checks above still see valid data.
            loginSetID: loginMode == .set ? selectedLoginSetID : nil,
            jump: buildJumpSpec(existingSecretID: existingJumpSecretID))
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
    /// target's own `loginMode == .set` path, it trusts the App layer to
    /// have already filled `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/
    /// `jumpPassword` from that set (`ContentView`'s `fillForm`-style
    /// pattern) before calling into this validator; a DANGLING set
    /// reference is an App-layer concern (spec §4a/§4c), not this
    /// view model's -- it has no access to the actual `LoginSet` data.
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
    /// where required, so this never needs to fail -- true because this
    /// method's only caller is `connect()`, which always validates with
    /// `requireSecret: true` (see `validateJump`'s own doc comment).
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
            return .failed(message: CoreL10n.string("core.connect.emptyHost"), field: .host)
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return .failed(message: CoreL10n.string("core.connect.emptyUsername"), field: .username)
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return .failed(
                message: String(format: CoreL10n.string("core.connect.invalidPort %@"), String(port)),
                field: .port)
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
        // Jump auth failure (M10c/T1 review hand-off): highlights the JUMP
        // password field instead of the target's -- `.authenticationFailed`
        // above stays the target-only case.
        case RemoteFSError.jumpAuthenticationFailed:
            return .failed(message: CoreL10n.string("core.connect.jumpAuthFailed"), field: .jumpPassword)
        case RemoteFSError.authenticationFailed:
            return .failed(
                message: CoreL10n.string("core.connect.authFailed"),
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
                field: isJumpKey ? .jumpKeyPath : .keyPath)
        case SSHKeyError.passphraseRequired:
            return .failed(
                message: CoreL10n.string("core.connect.keyPassphraseRequired"),
                field: .password)
        case SSHKeyError.wrongPassphrase:
            return .failed(message: CoreL10n.string("core.connect.keyWrongPassphrase"), field: .password)
        case SSHKeyError.unsupportedFormat:
            return .failed(
                message: CoreL10n.string("core.connect.keyUnsupportedFormat"),
                field: .keyPath)
        case HostKeyError.mismatch(let host, let expected, let presented):
            return .failed(
                message: String(
                    format: CoreL10n.string("core.hostkey.mismatch %@ %@ %@"),
                    host, expected, presented),
                field: nil)
        case HostKeyError.rejectedByUser:
            return .failed(message: CoreL10n.string("core.hostkey.rejected"), field: nil)
        default:
            return .failed(
                message: String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error)),
                field: nil)
        }
    }
}
