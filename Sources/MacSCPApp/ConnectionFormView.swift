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
    /// `suggestedSetName(forUsername:)` for the "save as new set" name
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
    /// The provider-preset picker's current selection (M12/T7b) — purely a
    /// UI convenience for `applyS3Preset(_:)` below, not a source of truth:
    /// the actual S3 fields live on `viewModel` and stay independently
    /// editable after a preset fills them. Defaults to "custom" (the
    /// schema's own no-op preset, `values: [:]`) so a fresh or reopened S3
    /// form never silently re-applies a stale provider's values.
    @State private var selectedS3PresetID: String = "custom"

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
            id: editingSessionID ?? UUID(), name: "", host: "", username: "", jump: spec)
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

                if viewModel.kind == .ssh {
                    sshSections
                } else {
                    s3Section
                }

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
                            // The S3 secret lives in `s3SecretAccessKey`, not
                            // `password` (which `beginEditing` always clears
                            // for S3 sessions) — pick the field by kind so an
                            // edited Secret Access Key isn't silently dropped.
                            let secret = viewModel.kind == .s3 ? viewModel.s3SecretAccessKey : viewModel.password
                            onSaveEdited(session, secret.isEmpty ? nil : secret)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    .buttonStyle(.polished)
                    .disabled(loginSetModeIncomplete || jumpLoginSetModeIncomplete || jumpSessionModeIncomplete)
                    Button(L10n.string("connection.saveAndConnect", "Save & connect")) {
                        guard resolveLoginSetForSubmit() else { return }
                        if let session = viewModel.validateForEditSave() {
                            let secret = viewModel.kind == .s3 ? viewModel.s3SecretAccessKey : viewModel.password
                            onSaveEdited(session, secret.isEmpty ? nil : secret)
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

    /// The bespoke SSH sections (host/login/auth/jump), unchanged from
    /// before the M12 type switcher — extracted into their own
    /// `@ViewBuilder` so `formContent` above can gate them on
    /// `viewModel.kind == .ssh` without duplicating this whole block.
    @ViewBuilder
    private var sshSections: some View {
                let hostLabel = L10n.string("connection.field.host", "Host")
                FormRow(label: hostLabel) {
                    TextField(
                        hostLabel, text: $viewModel.host,
                        prompt: Text(L10n.string("connection.field.host.placeholder", "server.example.com"))
                    )
                }
                .errorHighlight(failedField == .host)

                let portLabel = L10n.string("connection.field.port", "Port")
                FormRow(label: portLabel) {
                    // Empty prompts: outside a Form the title parameter would
                    // surface as an in-field placeholder and duplicate the
                    // FormRow label — the titles stay for accessibility only.
                    TextField(
                        portLabel, text: $viewModel.port,
                        prompt: Text(verbatim: ""))
                }
                .errorHighlight(failedField == .port)

                // Three-way login switcher (M10b/T3, mockup section 3): sits
                // above the auth block it replaces/wraps. Set mode shows a
                // login-set picker instead of Username/Auth/Password/Key;
                // Manual mode is today's block, with the "save as new set"
                // toggle appended.
                let loginModeLabel = L10n.string("form.loginMode.label", "Login")
                FormRow(label: loginModeLabel) {
                    Picker(loginModeLabel, selection: $viewModel.loginMode) {
                        Text(L10n.string("form.loginMode.set", "Login set"))
                            .tag(ConnectionViewModel.LoginMode.set)
                        Text(L10n.string("form.loginMode.manual", "Manual"))
                            .tag(ConnectionViewModel.LoginMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if viewModel.loginMode == .set {
                    FormRow(label: "") {
                        HStack(spacing: 10) {
                            Picker(loginModeLabel, selection: $viewModel.selectedLoginSetID) {
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
                    let usernameLabel = L10n.string("connection.field.username", "Username")
                    FormRow(label: usernameLabel) {
                        TextField(
                            usernameLabel, text: $viewModel.username,
                            prompt: Text(verbatim: ""))
                    }
                    .errorHighlight(failedField == .username)

                    let authMethodLabel = L10n.string("connection.field.authMethod", "Authentication")
                    FormRow(label: authMethodLabel) {
                        Picker(authMethodLabel, selection: Binding(
                            get: { viewModel.authChoice },
                            set: { viewModel.selectAuthChoice($0) }
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

                    if viewModel.authChoice == .password {
                        let passwordLabel = L10n.string("connection.auth.password", "Password")
                        FormRow(label: passwordLabel) {
                            SecureField(
                                passwordLabel, text: $viewModel.password,
                                prompt: isEditMode
                                    ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                    : Text(verbatim: "")
                            )
                        }
                        .errorHighlight(failedField == .password)
                    } else if viewModel.authChoice == .privateKey {
                        let keyPathLabel = L10n.string("connection.field.keyPath", "Key path")
                        FormRow(label: keyPathLabel) {
                            HStack(spacing: 6) {
                                TextField(
                                    keyPathLabel, text: $viewModel.keyPath,
                                    prompt: Text(L10n.string(
                                        "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519"))
                                )
                                // "…" is a pure symbol (ellipsis "browse" affordance), not
                                // natural-language text — identical in every locale, so it
                                // stays a literal rather than a catalog key.
                                Button("…") { showKeyImporter = true }
                                    .buttonStyle(.polished)
                                    .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                            }
                        }
                        .errorHighlight(failedField == .keyPath)

                        let passphraseLabel = L10n.string("connection.field.passphrase", "Passphrase (optional)")
                        FormRow(label: passphraseLabel) {
                            SecureField(
                                passphraseLabel,
                                text: $viewModel.password,
                                prompt: isEditMode
                                    ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                    : Text(verbatim: "")
                            )
                        }
                        .errorHighlight(failedField == .password)
                    }
                    // .agent (M10d/T4): neither a secret nor a key path is
                    // needed — the private key never leaves the running
                    // ssh-agent — so no row shows here at all.

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
                                prompt: Text(sessionList.suggestedSetName(forUsername: viewModel.username)))
                        }
                    }
                }

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

    /// The S3 backend descriptor (M12/T7b) — its `fieldSchema` drives the
    /// section below instead of hand-rolling S3-specific rows, so a future
    /// backend with its own schema only needs a `BackendDescriptor`, not a
    /// new bespoke form section like `sshSections` above.
    private var s3Descriptor: BackendDescriptor { .descriptor(for: .s3) }

    /// The schema-driven S3 section (M12/T7b, login-set mode M15/T3): a
    /// provider-preset picker, the location fields (endpoint/region/bucket/
    /// usePathStyle) which are always shown, then the login switcher — Set
    /// mode swaps the credential fields (accessKeyID/secretAccessKey) for a
    /// `.s3`-filtered login-set picker, Manual mode keeps them plus "save as
    /// new set". Deliberately simple/static — no derived layout, no nested
    /// state machine — per the M11n lesson that new GUI here must not risk
    /// an AttributeGraph cycle.
    private var s3Section: some View {
        let presetLabel = L10n.string("connection.s3.preset.label", "Provider preset")
        return Group {
            FormRow(label: presetLabel) {
                Picker(presetLabel, selection: Binding(
                    get: { selectedS3PresetID },
                    set: { id in
                        selectedS3PresetID = id
                        applyS3Preset(id)
                    }
                )) {
                    ForEach(s3Descriptor.fieldSchema.presets) { preset in
                        Text(L10n.string(preset.nameKey, preset.nameDefault)).tag(preset.id)
                    }
                }
                .labelsHidden()
            }

            // Location fields (endpoint/region/bucket/usePathStyle) belong to
            // the session, not the login set (M15 decision 1) — always shown.
            ForEach(s3Descriptor.fieldSchema.fields.filter { !Self.s3CredentialFieldIDs.contains($0.id) }) { field in
                s3FieldRow(field)
            }

            // Login switcher (M15): parity with the SSH block. Set mode swaps
            // the access-key/secret fields for a kind-filtered picker; manual
            // mode keeps today's fields plus "save as new set".
            let loginModeLabel = L10n.string("form.loginMode.label", "Login")
            FormRow(label: loginModeLabel) {
                Picker(loginModeLabel, selection: $viewModel.loginMode) {
                    Text(L10n.string("form.loginMode.set", "Login set"))
                        .tag(ConnectionViewModel.LoginMode.set)
                    Text(L10n.string("form.loginMode.manual", "Manual"))
                        .tag(ConnectionViewModel.LoginMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if viewModel.loginMode == .set {
                FormRow(label: "") {
                    HStack(spacing: 10) {
                        Picker(loginModeLabel, selection: $viewModel.selectedLoginSetID) {
                            Text(L10n.string("form.selectLogin", "Select a login")).tag(UUID?.none)
                            ForEach(sessionList.loginSets.filter { $0.kind == .s3 }) { set in
                                Text("\(set.name) — \(set.accessKeyID ?? "")").tag(UUID?.some(set.id))
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
                ForEach(s3Descriptor.fieldSchema.fields.filter { Self.s3CredentialFieldIDs.contains($0.id) }) { field in
                    s3FieldRow(field)
                }
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
                            prompt: Text(verbatim: ""))
                    }
                }
            }
        }
    }

    /// The two S3 schema fields that constitute the "login" (M15): swapped
    /// for the set picker in Set mode. Everything else (endpoint/region/
    /// bucket/usePathStyle) is session-owned and always visible.
    private static let s3CredentialFieldIDs: Set<String> = ["accessKeyID", "secretAccessKey"]

    /// One form row for a single S3 `ConnectionField`, rendered by its
    /// `kind` and bound to the matching `viewModel.s3*` property BY FIELD
    /// ID (`s3TextBinding(for:)` below) — `.secret`/`.toggle` bind directly
    /// since there is exactly one field of each in the current schema.
    @ViewBuilder
    private func s3FieldRow(_ field: ConnectionField) -> some View {
        let label = L10n.string(field.labelKey, field.labelDefault)
        switch field.kind {
        case .toggle:
            FormRow(label: "") {
                Toggle(label, isOn: $viewModel.s3UsePathStyle)
            }
        case .secret:
            FormRow(label: label) {
                SecureField(
                    label, text: $viewModel.s3SecretAccessKey,
                    prompt: isEditMode
                        ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                        : Text(verbatim: ""))
            }
        case .text, .number:
            FormRow(label: label) {
                TextField(label, text: s3TextBinding(for: field.id), prompt: Text(verbatim: ""))
            }
        }
    }

    /// Maps a schema field id to the matching `viewModel.s3*` text property
    /// (M12/T7b) — the ids are fixed by `BackendDescriptor.s3Descriptor`
    /// (endpoint/region/bucket/accessKeyID); `secretAccessKey`/`usePathStyle`
    /// are handled directly in `s3FieldRow` above, never routed through here.
    private func s3TextBinding(for fieldID: String) -> Binding<String> {
        switch fieldID {
        case "endpoint": return $viewModel.s3Endpoint
        case "region": return $viewModel.s3Region
        case "bucket": return $viewModel.s3Bucket
        case "accessKeyID": return $viewModel.s3AccessKeyID
        default: return .constant("")
        }
    }

    /// Fills the S3 fields from the selected preset's `values` (M12/T7b) —
    /// only the ids present in `values` are touched (e.g. the "aws" preset
    /// sets `endpoint`/`usePathStyle` and leaves region/bucket/accessKeyID
    /// exactly as the user left them); "Custom" carries `values: [:]` and is
    /// therefore a pure no-op.
    private func applyS3Preset(_ id: String) {
        guard let preset = s3Descriptor.fieldSchema.presets.first(where: { $0.id == id }) else { return }
        for (fieldID, value) in preset.values {
            switch fieldID {
            case "endpoint": viewModel.s3Endpoint = value
            case "region": viewModel.s3Region = value
            case "bucket": viewModel.s3Bucket = value
            case "accessKeyID": viewModel.s3AccessKeyID = value
            case "usePathStyle": viewModel.s3UsePathStyle = (value == "true")
            default: break
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

/// Mockup form row (M5k): fixed 110pt right-aligned label column in
/// inkSecondary, 10pt gap to the field. The visible label lives here;
/// the wrapped controls keep their own label parameters for accessibility —
/// which is why the visible label is hidden from VoiceOver (M6a): without
/// that, every row is announced twice. The label also dims with the row's
/// enabled state, matching the system Form behavior the grid replaced.
private struct FormRow<Content: View>: View {
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

private extension View {
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
