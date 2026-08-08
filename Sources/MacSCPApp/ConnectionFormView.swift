import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    /// Groups offered by the group picker (edit mode, and new mode once
    /// `shouldSaveSession` is on) — passed in by `ContentView` from
    /// `SessionListViewModel.groups`.
    var groups: [StoredGroup] = []
    /// Full view model (M10b/T3), not just an array like `groups` above:
    /// the three-way login block needs `loginSets` for its picker AND
    /// `suggestedSetName(forLabel:)` for the "save as new set" name
    /// prompt AND — since "Manage logins…" opens the SAME sheet locally
    /// (mockup section 4C, TOFU-footnote pattern) — a live reference so
    /// edits made there are immediately visible everywhere else this
    /// instance is shared (the sidebar, this very picker), unlike
    /// `KnownHostsSheet`'s throwaway store instance.
    let sessionList: SessionListViewModel
    /// Called right before `connect()`/`validateForEditSave()` whenever the
    /// form is in Set mode (M10b/T3) for the TARGET login, or the jump is
    /// enabled and ALSO in Set mode (M10c/T3): fills username/authChoice/
    /// keyPath/password (target) and/or jumpUsername/jumpAuthChoice/
    /// jumpKeyPath/jumpPassword (jump) from their respective selected login
    /// sets, so the existing validators below see current, non-stale data —
    /// no separate Set-mode validation path needed in `ConnectionViewModel`.
    /// Returns `false` when a selected set no longer resolves (dangling
    /// reference — spec §4a): the caller has already surfaced that failure
    /// via `viewModel.showFailure`, and the button handlers below must NOT
    /// proceed to connect/validate in that case.
    var resolveLoginSetForSubmit: () -> Bool = { true }
    /// Edit mode "Save": persists the edited session (see `newSecret`'s
    /// empty-means-unchanged rule below), then leaves edit mode.
    var onSaveEdited: (StoredSession, String?) -> Void = { _, _ in }
    /// Edit mode "Back": discards the edit and returns to the browser/idle
    /// state without touching the stored session.
    var onCancelEdit: () -> Void = {}
    /// Edit mode "Save & connect": called after `onSaveEdited` with the
    /// validated session — `ContentView` reconnects via `connectStored`,
    /// which reloads the secret from the keychain (covers "empty password
    /// means unchanged" automatically).
    var onConnectEdited: (StoredSession) -> Void = { _ in }
    /// `async` (M9d): the caller resolves the remote home directory before
    /// building the browser session, so it needs to `await` inside here.
    let onConnected: (any RemoteFileSystem) async -> Void

    @State private var showKeyImporter = false
    /// Same as `showKeyImporter` but for the jump's own key file (M10c/T3) —
    /// a separate flag because the two `fileImporter`s write to different
    /// fields (`viewModel.keyPath` vs. `viewModel.jumpKeyPath`).
    @State private var showJumpKeyImporter = false
    /// True while `onConnected` runs after a successful connect (M9d final
    /// review): the connect closure is async now (home-directory lookup), so
    /// the view model's `.idle` state alone would re-enable the Connect
    /// button while `tab.session` is still nil — a second click in that
    /// window would open and LEAK a second SSH connection.
    @State private var isHandingOff = false
    /// Failure message currently shown as an alert. Deliberately separate
    /// from `viewModel.state` so dismissing the alert keeps the `.failed`
    /// state (and with it the red field highlight) intact.
    @State private var alertMessage: String?
    /// Drives the TOFU prompt's "Manage known hosts…" footnote (M10a/T2).
    /// Local `@State` sheet with its own `KnownHostsStore` instance, rather
    /// than a callback bubbled up to `ContentView` — `ConnectionFormView`
    /// already knows the store's fixed directory (same one the connector in
    /// `ContentView.makeTab` uses), so a callback would only add an extra
    /// closure parameter threaded through `SessionTab`/`ContentView` for no
    /// behavioral gain. The trust prompt underneath is unaffected either
    /// way — it's driven by `viewModel.hostKeyPrompt`, not by this sheet.
    @State private var showKnownHostsSheet = false
    /// Drives the login-sets management sheet's "Manage logins…" link
    /// (M10b/T3, mockup section 4C) — opened LOCALLY from the Set-mode
    /// picker, same pattern as `showKnownHostsSheet` above.
    @State private var showLoginSetsSheet = false
    /// Drives the SSH-keys management sheet's "Manage keys…" link (M18/T5) —
    /// replaces the M17 `SettingsLink` to the Settings tab with a locally
    /// opened sheet, same pattern as `showLoginSetsSheet` above.
    @State private var showSSHKeysSheet = false

    private var isConnecting: Bool { viewModel.state == .connecting }

    private var isEditMode: Bool {
        if case .edit = viewModel.mode { return true }
        return false
    }

    /// True while Set mode has nothing selected yet — the three connect/save
    /// actions stay disabled instead of the removed username/password
    /// checks, which don't apply once those fields are hidden (spec §5).
    private var loginSetModeIncomplete: Bool {
        viewModel.loginMode == .set && viewModel.selectedLoginSetID == nil
    }

    /// Same as `loginSetModeIncomplete`, for the jump's own login switcher
    /// (M10c/T3) — the jump's Set mode with nothing picked yet also keeps
    /// Connect/Save disabled, not just the target's. `jumpSourceMode !=
    /// .session` guards against a dangling `jumpSelectedLoginSetID` left over
    /// from a Manual+Set pick before the user switched Source to "Saved
    /// connection" (F-1 fix, final review): the Set picker isn't even
    /// rendered in session mode, so it must not be able to disable
    /// Connect/Save with no visible cause.
    private var jumpLoginSetModeIncomplete: Bool {
        viewModel.jumpEnabled && viewModel.jumpSourceMode != .session
            && viewModel.jumpLoginMode == .set && viewModel.jumpSelectedLoginSetID == nil
    }

    /// Same idea, for the jump's source switcher (M11a/T3) — session mode
    /// with nothing picked yet also keeps Connect/Save disabled, mirroring
    /// `jumpLoginSetModeIncomplete` above. Belt-and-suspenders: `connect()`/
    /// `validateForEditSave()` already reject this with `.jumpSession`
    /// (Core VM), this only pre-empts the click.
    private var jumpSessionModeIncomplete: Bool {
        viewModel.jumpEnabled && viewModel.jumpSourceMode == .session && viewModel.jumpSessionID == nil
    }

    /// The field whose validation failed most recently — gets the red outline.
    private var failedField: ConnectionViewModel.Field? {
        if case .failed(_, let field) = viewModel.state { return field }
        return nil
    }

    /// The namespaced key `SchemaFormView` matches its rows against.
    ///
    /// A pass-through since M23: the view model reports the failing field by
    /// its own key, so this no longer translates an enum case into an
    /// SSH-namespaced string — which is why S3 and WebDAV rows highlight now
    /// and did not before. The passphrase-versus-password special case is gone
    /// too: the validator walks the VISIBLE fields, so it names whichever
    /// secret row is actually on screen.
    ///
    /// The cases this returns nil for are NOT unhighlighted: the session-name
    /// row and the whole jump block are drawn by hand below and carry their
    /// own `.errorHighlight`.
    private var failedFieldID: String? {
        guard case .schema(let key) = failedField else { return nil }
        return key
    }

    /// Fields the generic renderer must skip because this view draws them —
    /// see `sshJumpSection` for why the jump is the one and only member, and
    /// what would let it join the others.
    ///
    /// The LIST lives in Core (M22/T9) so a Core test can guard it: matched by
    /// string against top-level ids, a stale entry here silently removes a row
    /// from the form and nothing fails.
    private static let customRenderedFields = BackendDescriptor.customRenderedFieldIDs

    /// The stored key of the managed-key picker, watched below.
    private static let managedKeyKey =
        "\(SSHField.namespace).\(SSHField.managedKeyID.rawValue)"

    /// The stored key of the auth-kind picker, intercepted below.
    private static let authKindKey =
        "\(SSHField.namespace).\(SSHField.authKind.rawValue)"

    /// Sends the auth-kind picker's write through `selectAuthChoice` instead
    /// of letting it land in `values` (M22/T8 fix round 1).
    ///
    /// Switching the auth kind is a COMMAND, not a value change: the view
    /// model clears the secret so the password typed for `.password` does not
    /// reappear prefilled in the passphrase row — from where "Save as session"
    /// or "Save as new login set" would write the user's account password into
    /// the Keychain as a key passphrase. The hand-written picker routed
    /// through this; binding the generic picker straight to the field silently
    /// bypassed it and left `selectAuthChoice` with no production caller at
    /// all.
    ///
    /// Returns false for every other field, which is then written normally.
    /// A value that names no auth kind — the "—" row — is deliberately NOT
    /// treated as a switch; it is written raw, exactly as before.
    private func interceptEdit(_ key: String, _ newValue: String) -> Bool {
        guard key == Self.authKindKey,
              let choice = ConnectionViewModel.AuthChoice(rawValue: newValue)
        else { return false }
        viewModel.selectAuthChoice(choice)
        return true
    }

    // MARK: - Jump source: saved connection (M11a/T3)

    /// The session currently being edited, or `nil` for a brand-new
    /// connection — passed to `JumpSessionEligibility.eligible(for:in:)` so
    /// the picker can never offer the session as its own jump host.
    private var editingSessionID: UUID? {
        if case .edit(let sessionID) = viewModel.mode { return sessionID }
        return nil
    }

    /// The picker's offered sessions (spec §3): excludes the session being
    /// edited (self-reference) and any session that itself has a jump
    /// (chains — one hop is the rule), sorted like the sidebar.
    private var eligibleJumpSessions: [StoredSession] {
        JumpSessionEligibility.eligible(for: editingSessionID, in: sessionList.sessions)
    }

    /// The read-only summary row below the picker (spec §3): either the
    /// resolved target (`host:port · user · auth`), or a localized error
    /// when the reference can't be resolved. `nil` while nothing is
    /// selected yet — the row simply doesn't render.
    private enum JumpSessionSummary {
        case resolved(String)
        case error(String)
    }

    /// Resolves `viewModel.jumpSessionID` through the SAME
    /// `SessionListViewModel.resolvedJump(for:)` the connect wiring uses
    /// (`ContentView`), via a throwaway `StoredSession` whose only
    /// meaningful content is the jump spec's `sessionID` — nothing else
    /// about this synthetic session is ever read or persisted. `id` mirrors
    /// the session actually being edited (so self-reference/chain detection
    /// works exactly as it would after saving), or a fresh id for a
    /// brand-new connection, which can never self-reference.
    private var jumpSessionSummary: JumpSessionSummary? {
        guard let sessionID = viewModel.jumpSessionID else { return nil }
        let spec = StoredSession.JumpSpec(host: "", username: "", sessionID: sessionID)
        let synthetic = StoredSession(
            id: editingSessionID ?? UUID(), name: "",
            ssh: StoredSSHConfig(host: "", username: "", jump: spec))
        do {
            guard let resolved = try sessionList.resolvedJump(for: synthetic) else { return nil }
            return .resolved(
                "\(resolved.host):\(resolved.port) · \(resolved.login.username) · "
                    + shortAuthLabel(resolved.login.authKind))
        } catch LoginResolveError.missingSet {
            // The referenced session's OWN login set is dangling — same
            // wording the target/jump login-set pickers already use for
            // this exact condition (`resolveSelectedLoginSet`/
            // `resolveSelectedJumpLoginSet` in ContentView).
            return .error(L10n.string(
                "loginSets.missingSet",
                "The stored login for this connection was not found. Choose a login or enter credentials."))
        } catch LoginResolveError.jumpChainNotSupported {
            return .error(L10n.string(
                "form.jump.session.chainNotSupported",
                "The selected jump host connects through another jump host; chains are not supported."))
        } catch LoginResolveError.jumpSessionNotSSH {
            // Must NOT fall into the generic `catch` below: that text says
            // the connection "no longer exists", which would be untrue here
            // -- the referenced session exists, it just isn't SSH.
            return .error(L10n.string(
                "form.jump.session.notSSH",
                "Only SSH connections can be used as a jump host."))
        } catch {
            // `.missingJumpSession` and any other unclassified failure both
            // read as "the reference is gone" to the user — the same
            // fallback text either way.
            return .error(L10n.string(
                "form.jump.session.missing",
                "The connection used as jump host no longer exists."))
        }
    }

    /// Auth short-form used by the summary row (spec §3: "wie im
    /// Login-Sets-Sheet") — reuses the SAME three badge keys
    /// `LoginSetsSheet.badgeStyle(for:)` already localizes, rather than
    /// duplicating three more strings for the identical PASS/KEY/AGENT text.
    private func shortAuthLabel(_ kind: StoredSession.AuthKind) -> String {
        switch kind {
        case .password: return L10n.string("loginSets.badge.pass", "PASS")
        case .privateKey: return L10n.string("loginSets.badge.key", "KEY")
        case .agent: return L10n.string("loginSets.badge.agent", "AGENT")
        }
    }

    @ViewBuilder
    private func jumpSessionSummaryView(_ summary: JumpSessionSummary) -> some View {
        switch summary {
        case .resolved(let text):
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
        case .error(let message):
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // While the host-key prompt is pending, the form is hidden
            // entirely — the trust decision is the only thing on screen.
            if let prompt = viewModel.hostKeyPrompt {
                hostKeyPromptView(prompt)
            } else {
                formContent
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                viewModel.keyPath = url.path(percentEncoded: false)
            }
        }
        .fileImporter(isPresented: $showJumpKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                viewModel.jumpKeyPath = url.path(percentEncoded: false)
            }
        }
        .alert(
            L10n.string("connection.error.title", "Connection failed"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        // Opened from the TOFU prompt's footnote below — kept at the outer
        // `body` level (like the alert above) so it presents over whichever
        // sub-view (`hostKeyPromptView` or `formContent`) is currently shown,
        // and so the prompt underneath stays mounted and functional while
        // the sheet is up.
        .sheet(isPresented: $showKnownHostsSheet) {
            KnownHostsSheet(store: KnownHostsStore(directory: SessionStore.defaultDirectory))
        }
        // "Manage logins…" (M10b/T3, mockup section 4C): opens the SAME
        // sheet locally, sharing `sessionList` (not a fresh store instance
        // like `showKnownHostsSheet` above) so an edit/delete/merge made
        // here is immediately reflected in the Set-mode picker and the
        // sidebar, which read the same observable object.
        .sheet(isPresented: $showLoginSetsSheet) {
            LoginSetsSheet(sessionList: sessionList)
        }
        // "Manage keys…" (M18/T5): opens the SSH-keys sheet locally, same
        // reasoning as `showLoginSetsSheet` above — replaces the M17
        // `SettingsLink` to the now-removed-in-Task-6 Settings tab.
        .sheet(isPresented: $showSSHKeysSheet) {
            SSHKeysSheet()
        }
        // Surfaces a `.failed` state set from OUTSIDE this view's own button
        // handlers (M10b/T3: `ContentView.connect(in:stored:)` calls
        // `viewModel.showFailure` when a stored session's login set is
        // missing) through the same alert the Connect/Save buttons already
        // populate inline — one mechanism for both origins.
        .onChange(of: viewModel.state) { _, newState in
            if case .failed(let message, _) = newState {
                alertMessage = message
            }
        }
        // Picking a managed key fills the key path (M17/T5). The schema can
        // declare the picker but not its EFFECT: the option ids are key ids,
        // while everything downstream — connect, save, `SSHCommandBuilder` —
        // reads `keyPath`. Without this the picker would look like it worked
        // and change nothing. Choosing the "—" row clears the id and
        // deliberately leaves the typed path alone.
        .onChange(of: viewModel.values.raw[Self.managedKeyKey] ?? "") { _, newID in
            guard !newID.isEmpty,
                  let key = Self.connectableManagedKeys()
                      .first(where: { $0.id.uuidString == newID })
            else { return }
            viewModel.keyPath = Self.managedKeyPath(for: key)
        }
    }

    @ViewBuilder
    private var formContent: some View {
            Text(isEditMode
                ? L10n.string("connection.editTitle", "Edit session")
                : L10n.string("connection.title", "New connection"))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                // Type switcher (M12/T7b): the only row shown regardless of
                // `viewModel.kind` — it's what flips the rest of the form
                // between the SSH sections below (unchanged from before this
                // feature) and the schema-driven S3 section.
                let typeLabel = L10n.string("connection.type.label", "Connection type")
                FormRow(label: typeLabel) {
                    Picker(typeLabel, selection: $viewModel.kind) {
                        ForEach(ConnectionKind.allCases, id: \.self) { kind in
                            let descriptor = BackendDescriptor.descriptor(for: kind)
                            Text(L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault))
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Connection type is fixed after creation — editing a
                    // session never changes its protocol.
                    .disabled(isEditMode)
                }

                backendSection

                if !isEditMode {
                    FormRow(label: "") {
                        Toggle(
                            L10n.string("connection.saveToggle", "Save as session"),
                            isOn: $viewModel.shouldSaveSession)
                    }
                }

                if isEditMode || viewModel.shouldSaveSession {
                    let saveNameLabel = L10n.string("connection.field.saveName", "Session name")
                    FormRow(label: saveNameLabel) {
                        TextField(
                            saveNameLabel, text: $viewModel.saveName,
                            prompt: Text(L10n.string("connection.field.saveName.placeholder", "e.g. hetzner-web"))
                        )
                    }
                    .errorHighlight(failedField == .saveName)

                    let groupLabel = L10n.string("connection.field.group", "Group")
                    FormRow(label: groupLabel) {
                        Picker(
                            groupLabel,
                            selection: $viewModel.selectedGroupID
                        ) {
                            Text(L10n.string("sidebar.noGroup", "No group")).tag(UUID?.none)
                            ForEach(groups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isConnecting)

            HStack {
                Spacer()
                if isConnecting || isHandingOff {
                    ProgressView()
                        .controlSize(.small)
                }
                if isEditMode {
                    Button(L10n.string("common.back", "Back")) {
                        onCancelEdit()
                    }
                    .buttonStyle(.polished)
                    Button(L10n.string("common.save", "Save")) {
                        guard resolveLoginSetForSubmit() else { return }
                        if let session = viewModel.validateForEditSave() {
                            onSaveEdited(session, editedSecret)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    .buttonStyle(.polished)
                    .disabled(loginSetModeIncomplete || jumpLoginSetModeIncomplete || jumpSessionModeIncomplete)
                    Button(L10n.string("connection.saveAndConnect", "Save & connect")) {
                        guard resolveLoginSetForSubmit() else { return }
                        if let session = viewModel.validateForEditSave() {
                            onSaveEdited(session, editedSecret)
                            onConnectEdited(session)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.polishedProminent)
                    .disabled(loginSetModeIncomplete || jumpLoginSetModeIncomplete || jumpSessionModeIncomplete)
                } else {
                    Button(L10n.string("connection.connect", "Connect")) {
                        guard resolveLoginSetForSubmit() else { return }
                        // M17: if this key is a managed key with a stored
                        // passphrase and none was typed, resolve it from the
                        // Keychain so the user need not re-enter it.
                        if viewModel.authChoice == .privateKey {
                            viewModel.password = ManagedKeyPassphrase.resolve(
                                keyPath: viewModel.keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                typed: viewModel.password,
                                store: ManagedKeyStore(directory: SessionStore.defaultDirectory),
                                secrets: KeychainSecretStore())
                        }
                        Task {
                            if let fs = await viewModel.connect() {
                                isHandingOff = true
                                await onConnected(fs)
                                isHandingOff = false
                            } else if case .failed(let message, _) = viewModel.state {
                                alertMessage = message
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting || isHandingOff || loginSetModeIncomplete || jumpLoginSetModeIncomplete || jumpSessionModeIncomplete)
                    .buttonStyle(.polishedProminent)
                }
            }
    }

    /// The secret the edit-mode Save path should write, or `nil` for "leave
    /// the stored one alone".
    ///
    /// Whichever field the backend's credential schema shows RIGHT NOW — the
    /// same question `LoginResolver.credentials`,
    /// `LoginSetEditorView.secret` and `ContentView.maybeCreateNewLoginSet`
    /// already ask `visibleSecretField`. A hardcoded
    /// `kind == .s3 ? s3SecretAccessKey : password` answered it until M22's
    /// final review: a fourth backend with its own secret field would leave
    /// `viewModel.password` empty, `nil` would go out, and the secret the
    /// user just typed would be silently discarded — exactly the failure the
    /// S3 special case was added to prevent.
    ///
    /// No visible secret row (an SSH agent login) resolves to `nil` too,
    /// which is the same "nothing to write" the empty-field case means.
    private var editedSecret: String? {
        let descriptor = BackendDescriptor.descriptor(for: viewModel.kind)
        guard let field = descriptor.credentialSchema.visibleSecretField(
            in: viewModel.values, namespace: descriptor.fieldNamespace)
        else { return nil }
        let secret = viewModel.values.raw["\(descriptor.fieldNamespace).\(field.id)"] ?? ""
        return secret.isEmpty ? nil : secret
    }

    /// The connection form for whichever backend is selected (M22/T8): the
    /// blocks Core declares, in Core's order, plus the two things no schema
    /// can express yet.
    ///
    /// The ORDER is `BackendDescriptor.formBlocks` — connection schema, login
    /// switcher, then either the credential schema or the login-set picker
    /// that substitutes it. Hand-placing those per backend is exactly what let
    /// S3's credential block go missing silently, and no App test could have
    /// caught it because there is no App test target.
    @ViewBuilder
    private var backendSection: some View {
        let descriptor = BackendDescriptor.descriptor(for: viewModel.kind)
        ForEach(
            Array(descriptor.formBlocks(
                usingLoginSet: viewModel.loginMode == .set).enumerated()),
            id: \.offset
        ) { _, block in
            formBlock(block, kind: descriptor.kind, namespace: descriptor.fieldNamespace)
        }
        // Immediately after the credential block — the last one Core emits, and
        // the one carrying the key-path row these two buttons fill.
        if viewModel.kind == .ssh { sshKeyFileRow }
        // Every backend (M22/T9): `ContentView.maybeCreateNewLoginSet` now
        // asks the descriptor to build the set, so it carries the form's own
        // kind instead of `LoginSet.init`'s `.ssh` default — the latent bug
        // that kept this control S3-and-SSH-only.
        if viewModel.loginMode == .manual {
            saveAsNewLoginSetRows
        }
        if viewModel.kind == .ssh { sshJumpSection }
    }

    /// Browse-for-a-key-file and "Manage keys…", the two affordances that sit
    /// beside the schema-rendered `keyPath` row (M17/T5, M18/T5).
    ///
    /// A row of its own rather than part of the generic renderer: both open
    /// App-only UI (an `NSOpenPanel` and a sheet) that no schema vocabulary
    /// describes. Shown under exactly the condition that makes the key path
    /// visible — private-key auth, and Manual mode, since a chosen login set
    /// brings its own key path.
    @ViewBuilder
    private var sshKeyFileRow: some View {
        if viewModel.loginMode == .manual && viewModel.authChoice == .privateKey {
            FormRow(label: "") {
                HStack(spacing: 10) {
                    // "…" is a pure symbol (ellipsis "browse" affordance), not
                    // natural-language text — identical in every locale, so it
                    // stays a literal rather than a catalog key.
                    Button("…") { showKeyImporter = true }
                        .buttonStyle(.polished)
                        .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                    Button(L10n.string("keys.picker.manage", "Manage keys…")) {
                        showSSHKeysSheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkTertiary)
                }
            }
        }
    }

    /// The jump host block (M10c/T3, M11a/T3), still drawn by hand.
    ///
    /// The schema declares the jump as a `.group`, and `SchemaFormView` is
    /// told to skip it (see `SchemaFormView.skipping`): the source switcher,
    /// the picker over eligible saved connections, the resolved-target summary
    /// and the jump's own login-set mode have no expression in today's
    /// vocabulary — `FieldCondition` has no conjunction, `OptionSource` has no
    /// "saved sessions" case. Rendering the group generically would drop all
    /// four, including the `.jumpSession` error highlight. The fields it binds
    /// to are the SAME `values` entries the group declares, so the two halves
    /// cannot drift.
    @ViewBuilder
    private var sshJumpSection: some View {
                let portLabel = L10n.string("connection.field.port", "Port")
                let loginModeLabel = L10n.string("form.loginMode.label", "Login")
                // Jump host block (M10c/T3, mockup section 2): a toggle below
                // the target's own auth block; enabled, it reuses the SAME
                // three-way login building blocks above (Set picker with
                // "Manage logins…", or Manual username/auth/password/key),
                // just bound to the jump's own fields instead of the
                // target's — minus "Save as new login set" (spec §3: YAGNI
                // for the jump).
                let jumpLabel = L10n.string("form.jump.label", "Jump host")
                FormRow(label: jumpLabel) {
                    Toggle(
                        L10n.string("form.jump.toggle", "Connect through an intermediate host (ProxyJump)"),
                        isOn: $viewModel.jumpEnabled)
                }

                if viewModel.jumpEnabled {
                    // Jump source switcher (M11a/T3, spec §3): sits above the
                    // host row, deciding whether the block below shows the
                    // saved-connection picker + read-only summary, or the
                    // full manual block unchanged from before this feature.
                    let jumpSourceLabel = L10n.string("form.jump.source.label", "Source")
                    FormRow(label: jumpSourceLabel) {
                        Picker(jumpSourceLabel, selection: Binding(
                            get: { viewModel.jumpSourceMode },
                            set: { viewModel.selectJumpSourceMode($0) }
                        )) {
                            Text(L10n.string("form.jump.source.session", "Saved connection"))
                                .tag(ConnectionViewModel.JumpSourceMode.session)
                            Text(L10n.string("form.loginMode.manual", "Manual"))
                                .tag(ConnectionViewModel.JumpSourceMode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if viewModel.jumpSourceMode == .session {
                        FormRow(label: "") {
                            Picker(jumpSourceLabel, selection: $viewModel.jumpSessionID) {
                                Text(L10n.string("form.jump.session.select", "Select a connection"))
                                    .tag(UUID?.none)
                                ForEach(eligibleJumpSessions) { session in
                                    Text(session.name).tag(UUID?.some(session.id))
                                }
                            }
                            .labelsHidden()
                        }
                        .errorHighlight(failedField == .jumpSession)

                        if let summary = jumpSessionSummary {
                            FormRow(label: "") {
                                jumpSessionSummaryView(summary)
                            }
                        }
                    } else {
                        FormRow(label: "") {
                            TextField(
                                jumpLabel, text: $viewModel.jumpHost,
                                prompt: Text(L10n.string("form.jump.host.placeholder", "bastion.example.com")))
                        }
                        .errorHighlight(failedField == .jumpHost)

                        FormRow(label: "") {
                            TextField(portLabel, text: $viewModel.jumpPort, prompt: Text(verbatim: ""))
                        }
                        .errorHighlight(failedField == .jumpPort)

                        FormRow(label: loginModeLabel) {
                            Picker(loginModeLabel, selection: $viewModel.jumpLoginMode) {
                                Text(L10n.string("form.loginMode.set", "Login set"))
                                    .tag(ConnectionViewModel.LoginMode.set)
                                Text(L10n.string("form.loginMode.manual", "Manual"))
                                    .tag(ConnectionViewModel.LoginMode.manual)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        if viewModel.jumpLoginMode == .set {
                            FormRow(label: "") {
                                HStack(spacing: 10) {
                                    Picker(loginModeLabel, selection: $viewModel.jumpSelectedLoginSetID) {
                                        Text(L10n.string("form.selectLogin", "Select a login")).tag(UUID?.none)
                                        ForEach(sessionList.loginSets) { set in
                                            Text("\(set.name) — \(set.username)").tag(UUID?.some(set.id))
                                        }
                                    }
                                    .labelsHidden()
                                    Button(L10n.string("form.manageLogins", "Manage logins…")) {
                                        showLoginSetsSheet = true
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.inkTertiary)
                                }
                            }
                        } else {
                            let jumpUsernameLabel = L10n.string("connection.field.username", "Username")
                            FormRow(label: jumpUsernameLabel) {
                                TextField(jumpUsernameLabel, text: $viewModel.jumpUsername, prompt: Text(verbatim: ""))
                            }
                            .errorHighlight(failedField == .jumpUsername)

                            let jumpAuthMethodLabel = L10n.string("connection.field.authMethod", "Authentication")
                            FormRow(label: jumpAuthMethodLabel) {
                                Picker(jumpAuthMethodLabel, selection: Binding(
                                    get: { viewModel.jumpAuthChoice },
                                    set: { viewModel.selectJumpAuthChoice($0) }
                                )) {
                                    Text(L10n.string("connection.auth.password", "Password"))
                                        .tag(ConnectionViewModel.AuthChoice.password)
                                    Text(L10n.string("connection.auth.privateKey", "SSH key"))
                                        .tag(ConnectionViewModel.AuthChoice.privateKey)
                                    Text(L10n.string("connection.auth.agent", "Agent"))
                                        .tag(ConnectionViewModel.AuthChoice.agent)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }

                            if viewModel.jumpAuthChoice == .password {
                                let jumpPasswordLabel = L10n.string("connection.auth.password", "Password")
                                FormRow(label: jumpPasswordLabel) {
                                    SecureField(
                                        jumpPasswordLabel, text: $viewModel.jumpPassword,
                                        prompt: isEditMode
                                            ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                            : Text(verbatim: ""))
                                }
                                .errorHighlight(failedField == .jumpPassword)
                            } else if viewModel.jumpAuthChoice == .privateKey {
                                let jumpKeyPathLabel = L10n.string("connection.field.keyPath", "Key path")
                                FormRow(label: jumpKeyPathLabel) {
                                    HStack(spacing: 6) {
                                        TextField(
                                            jumpKeyPathLabel, text: $viewModel.jumpKeyPath,
                                            prompt: Text(L10n.string(
                                                "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519")))
                                        Button("…") { showJumpKeyImporter = true }
                                            .buttonStyle(.polished)
                                            .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                                    }
                                }
                                .errorHighlight(failedField == .jumpKeyPath)

                                let jumpPassphraseLabel = L10n.string(
                                    "connection.field.passphrase", "Passphrase (optional)")
                                FormRow(label: jumpPassphraseLabel) {
                                    SecureField(
                                        jumpPassphraseLabel, text: $viewModel.jumpPassword,
                                        prompt: isEditMode
                                            ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                            : Text(verbatim: ""))
                                }
                                .errorHighlight(failedField == .jumpPassword)
                            }
                            // .agent (M10d/T4): same as the target block above —
                            // no secret/key row for the jump's own agent auth.
                        }
                    }
                }

    }

    /// Turns a schema-declared `OptionSource` into the options a picker shows
    /// (M22). The ONE thing the App contributes to the generic renderer:
    /// managed keys live in a store Core cannot see, so the schema names the
    /// source and this resolves it. Two cases, one switch, one place -- not
    /// the per-backend dispatcher M22 is removing.
    ///
    /// Login sets are NOT one of them: choosing a set substitutes the whole
    /// credential schema, which `FormBlock.loginSetPicker` places below.
    private func resolveOptions(_ source: OptionSource) -> [FieldOption] {
        switch source {
        case .fixed(let options):
            // Declared in the schema, catalog keys and all -- nothing to look up.
            return options
        case .managedKeys:
            // Same filter the hand-written SSH key picker uses: only ed25519
            // keys with a resolvable file are offerable.
            return Self.connectableManagedKeys().map { key in
                FieldOption(
                    id: key.id.uuidString, labelKey: "",
                    labelDefault: "\(key.name) — \(Self.shortFingerprint(key.fingerprint))")
            }
        }
    }

    /// Renders one `FormBlock` (M22/T7). The ORDER comes from Core
    /// (`BackendDescriptor.formBlocks`), not from this file: hand-placing the
    /// blocks per backend is exactly what let S3's credential block go missing
    /// silently, and no App test could have caught it because there is no App
    /// test target. Dropping a schema now means editing Core, where
    /// `FormBlockTests` fails.
    ///
    /// Binds straight to `viewModel.values` (M22/T8): the transitional
    /// `s3Values`/`webdavValues` adapters that mapped typed view-model
    /// properties into a `FieldValues` are gone with the typed storage they
    /// adapted.
    @ViewBuilder
    private func formBlock(
        _ block: FormBlock, kind: ConnectionKind, namespace: String
    ) -> some View {
        switch block {
        case .schema(let schema):
            SchemaFormView(
                schemas: [schema], values: $viewModel.values, namespace: namespace,
                isEditMode: isEditMode, resolve: resolveOptions,
                failedFieldID: failedFieldID, skipping: Self.customRenderedFields,
                interceptEdit: interceptEdit)
        case .loginModeSwitcher:
            loginModeSwitcher
        case .loginSetPicker:
            loginSetPicker(for: kind)
        }
    }

    /// The Manual / login-set switcher (M15), placed by
    /// `FormBlock.loginModeSwitcher`.
    private var loginModeSwitcher: some View {
        let loginModeLabel = L10n.string("form.loginMode.label", "Login")
        return FormRow(label: loginModeLabel) {
            Picker(loginModeLabel, selection: $viewModel.loginMode) {
                Text(L10n.string("form.loginMode.set", "Login set"))
                    .tag(ConnectionViewModel.LoginMode.set)
                Text(L10n.string("form.loginMode.manual", "Manual"))
                    .tag(ConnectionViewModel.LoginMode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// The kind-filtered login-set picker that substitutes the credential
    /// schema in Set mode, placed by `FormBlock.loginSetPicker`.
    private func loginSetPicker(for kind: ConnectionKind) -> some View {
        let loginModeLabel = L10n.string("form.loginMode.label", "Login")
        return FormRow(label: "") {
            HStack(spacing: 10) {
                Picker(loginModeLabel, selection: $viewModel.selectedLoginSetID) {
                    Text(L10n.string("form.selectLogin", "Select a login")).tag(UUID?.none)
                    ForEach(sessionList.loginSets.filter { $0.kind == kind }) { set in
                        Text(Self.loginSetLabel(set)).tag(UUID?.some(set.id))
                    }
                }
                .labelsHidden()
                Button(L10n.string("form.manageLogins", "Manage logins…")) {
                    showLoginSetsSheet = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
            }
        }
    }

    /// "name — identity", where the identity is whichever one the set carries:
    /// S3 sets hold an access key and an empty user name, everything else the
    /// reverse. Reading the optional first needs no branch on `kind`.
    private static func loginSetLabel(_ set: LoginSet) -> String {
        "\(set.name) — \(set.accessKeyID ?? set.username)"
    }

    /// "Save as new login set" (M15). Deliberately NOT a `FormBlock`: it is
    /// session bookkeeping rather than a schema. Shown for every backend since
    /// M22/T9 -- see `backendSection` for what had to be fixed first.
    @ViewBuilder
    private var saveAsNewLoginSetRows: some View {
        FormRow(label: "") {
            Toggle(
                L10n.string("form.saveAsSet", "Save as new login set"),
                isOn: $viewModel.saveAsNewLoginSet)
        }
        if viewModel.saveAsNewLoginSet {
            let setNameLabel = L10n.string("form.saveAsSet.name", "Login set name")
            FormRow(label: setNameLabel) {
                TextField(
                    setNameLabel, text: $viewModel.newLoginSetName,
                    prompt: Text(sessionList.suggestedSetName(forLabel: viewModel.username)))
            }
        }
    }

    /// Full-pane trust decision for an unknown host key (M3c). Presentation
    /// only — the TOFU semantics (explicit consent, mismatch never reaches
    /// this prompt) live in the validator and stay untouched.
    @ViewBuilder
    private func hostKeyPromptView(_ prompt: ConnectionViewModel.HostKeyPrompt) -> some View {
            Text(String(format: L10n.string(
                "connection.hostkey.first", "First connection to %@"), prompt.candidate.host))
                .font(.title2.bold())
            Text(String(format: L10n.string(
                "connection.hostkey.fingerprintLabel", "Fingerprint (%@):"), prompt.candidate.keyType))
                .font(.callout)
            Text(prompt.candidate.fingerprintSHA256)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(L10n.string("common.back", "Back")) {
                    viewModel.resolveHostKeyPrompt(trust: false)
                }
                .buttonStyle(.polished)
                Button(L10n.string("connection.hostkey.trust", "Trust & connect")) {
                    viewModel.resolveHostKeyPrompt(trust: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.polishedProminent)
            }
            // Discreet footnote (M10a/T2, mockup section 4): quick access to
            // inspect what is already trusted without abandoning the pending
            // prompt. (This prompt only exists on the UNKNOWN-key path — a
            // rotated key is a mismatch hard stop and never reaches it.)
            Button(L10n.string("tofu.manageKnownHosts", "Manage known hosts…")) {
                showKnownHostsSheet = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(DesignTokens.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private extension ConnectionFormView {
    /// Managed ed25519 keys available to fill `keyPath` from (M17/T5).
    /// Filters on `KeyType.isConnectable` — `SSHPrivateKeyLoader` can only
    /// load ed25519, so rsa/ecdsa keys never appear in the picker menu.
    static func connectableManagedKeys() -> [ManagedKey] {
        let store = ManagedKeyStore(directory: SessionStore.defaultDirectory)
        // A key whose stored `fileName` does not address a file inside the
        // key directory has no usable path, so it is not offerable either.
        return (try? store.all())?
            .filter { $0.type.isConnectable && store.privateKeyURL(for: $0) != nil } ?? []
    }

    /// The private-key file path a managed key resolves to, in the shape
    /// `keyPath` expects (absolute, not percent-encoded). Empty — i.e. "no
    /// key" — for a key whose stored `fileName` does not address a file
    /// inside the key directory; `connectableManagedKeys` already keeps
    /// those out of the picker.
    static func managedKeyPath(for key: ManagedKey) -> String {
        ManagedKeyStore(directory: SessionStore.defaultDirectory)
            .privateKeyURL(for: key)?.path(percentEncoded: false) ?? ""
    }

    /// The first ~12 characters after the `SHA256:` prefix, for a compact
    /// menu row label (`ManagedKey.fingerprint` is the full base64 digest).
    static func shortFingerprint(_ fingerprint: String) -> String {
        guard let range = fingerprint.range(of: "SHA256:") else { return fingerprint }
        return String(fingerprint[range.upperBound...].prefix(12))
    }
}

/// Mockup form row (M5k): fixed 110pt right-aligned label column in
/// inkSecondary, 10pt gap to the field. The visible label lives here;
/// the wrapped controls keep their own label parameters for accessibility —
/// which is why the visible label is hidden from VoiceOver (M6a): without
/// that, every row is announced twice. The label also dims with the row's
/// enabled state, matching the system Form behavior the grid replaced.
///
/// Internal rather than private (M22/T7): `SchemaFormView` renders its rows
/// with the same 110pt column and `firstTextBaseline` rhythm every form in
/// the app follows, and reimplementing them there would drift.
struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .opacity(isEnabled ? 1 : 0.5)
                .frame(width: 110, alignment: .trailing)
                .accessibilityHidden(true)
            content
        }
    }
}

extension View {
    /// Red outline for the form row whose validation failed. The stroke
    /// wraps label AND field, sitting 10pt horizontally / 5pt vertically
    /// outside the row's bounds so the content keeps breathing room.
    func errorHighlight(_ active: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.red, lineWidth: active ? 1.5 : 0)
                .padding(.horizontal, -10)
                .padding(.vertical, -5)
        )
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
