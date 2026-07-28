import SwiftUI
import macSCPCore

/// Login-sets management sheet (M10b/T3, mockup section 3): lists every
/// reusable login (`SessionListViewModel.loginSets`), with single-selection
/// New/Edit/Delete and a merge-suggestion banner on top when
/// `mergeCandidates()` finds manual sessions sharing the same effective
/// login. Shape mirrors `KnownHostsSheet` (M10a/T2) for consistency across
/// the app's management sheets — list + caption footer + destructive
/// `confirmationDialog` — but selection is single (`Edit…` only ever acts on
/// one set) rather than `KnownHostsSheet`'s multi-selection `Table`.
struct LoginSetsSheet: View {
    let sessionList: SessionListViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: LoginSet.ID?
    /// The single merge suggestion currently shown, or `nil` when none are
    /// left. Recomputed explicitly (not a live computed property) so a
    /// banner action's own re-render doesn't recompute mid-transition —
    /// `refreshMergeCandidate()` is the sole place that reassigns it.
    @State private var mergeCandidate: LoginMergeCandidate?
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingMergeConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var editorTarget: LoginSetEditorTarget?

    /// Drives the editor sub-sheet: wraps "new" (no existing set) or "edit"
    /// (a specific set) so `.sheet(item:)` has a stable identity even for
    /// the "new" case, which otherwise has none of its own — same pattern as
    /// `ContentView.ExportSheetItem`.
    private struct LoginSetEditorTarget: Identifiable {
        let id = UUID()
        let existing: LoginSet?
    }

    private var selectedSet: LoginSet? {
        sessionList.loginSets.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("loginSets.title", "Logins")).font(.headline)

            if let mergeCandidate {
                mergeBanner(mergeCandidate)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            if sessionList.loginSets.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.string("loginSets.empty", "No login sets yet."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                List(sessionList.loginSets, selection: $selectedID) { set in
                    row(set)
                }
            }

            HStack {
                Text(String(
                    format: L10n.string("loginSets.count %lld", "%lld logins"),
                    sessionList.loginSets.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("loginSets.new", "New…")) {
                    editorTarget = LoginSetEditorTarget(existing: nil)
                }
                .buttonStyle(.polished)
                Button(L10n.string("loginSets.edit", "Edit…")) {
                    if let selectedSet {
                        editorTarget = LoginSetEditorTarget(existing: selectedSet)
                    }
                }
                .buttonStyle(.polished)
                .disabled(selectedSet == nil)
                Button(L10n.string("loginSets.delete", "Delete…"), role: .destructive) {
                    isShowingDeleteConfirm = true
                }
                .buttonStyle(.polished)
                .disabled(selectedSet == nil)
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { refreshMergeCandidate() }
        // Editor sub-sheet (Step 2/spec §1-2): one view for both New… and
        // Edit…, distinguished by `target.existing`.
        .sheet(item: $editorTarget) { target in
            LoginSetEditorView(
                existing: target.existing,
                onSave: { set, secret in
                    sessionList.saveLoginSet(set, secret: secret)
                    editorTarget = nil
                },
                onCancel: { editorTarget = nil }
            )
        }
        .confirmationDialog(
            L10n.string("loginSets.delete.title", "Delete this login?"),
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("loginSets.delete.confirm", "Delete"), role: .destructive) {
                deleteSelected()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteConfirmMessage)
        }
        .confirmationDialog(
            L10n.string("loginSets.merge.confirmTitle", "Merge these connections?"),
            isPresented: $isShowingMergeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("loginSets.merge.confirm", "Merge"), role: .destructive) {
                applyMerge()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(mergeConfirmMessage)
        }
    }

    @ViewBuilder
    private func row(_ set: LoginSet) -> some View {
        HStack(spacing: 10) {
            authKindBadge(set.authKind)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.name).font(.system(size: 13))
                Text(subtitle(for: set))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
            }
            Spacer()
            Text(usageText(sessionList.usageCount(of: set.id)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// "KEY"/"PASS" — pure symbols (like `KnownHostsSheet.keyTypeBadge`'s
    /// uppercased key type), never natural-language text, so they stay
    /// literals rather than catalog keys.
    @ViewBuilder
    private func authKindBadge(_ kind: StoredSession.AuthKind) -> some View {
        let isKey = kind == .privateKey
        Text(isKey ? "KEY" : "PASS")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                isKey ? DesignTokens.remoteSoft : DesignTokens.localSoft,
                in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(isKey ? DesignTokens.remoteBlue : DesignTokens.localAmber)
    }

    private func subtitle(for set: LoginSet) -> String {
        if set.authKind == .privateKey {
            return String(
                format: L10n.string("loginSets.subtitle.key %@ %@", "%@ · SSH key (%@)"),
                set.username, set.keyPath ?? "")
        }
        return String(
            format: L10n.string("loginSets.subtitle.password %@", "%@ · Password"), set.username)
    }

    private func usageText(_ count: Int) -> String {
        if count == 1 { return L10n.string("loginSets.usage.one", "1 connection") }
        return String(format: L10n.string("loginSets.usage.many %lld", "%lld connections"), count)
    }

    private var deleteConfirmMessage: String {
        guard let selectedSet else { return "" }
        let count = sessionList.usageCount(of: selectedSet.id)
        return String(
            format: L10n.string(
                "loginSets.delete.message %lld",
                "%lld connections will keep these credentials stored directly again."),
            count)
    }

    /// Deletes the selected set (spec §3: affected connections are restored
    /// to "manual" with the set's own values copied back — see
    /// `SessionListViewModel.deleteLoginSet`'s doc comment). A partial
    /// keychain-restore failure is surfaced as a red inline message (pattern:
    /// `KnownHostsSheet.removeSelected`'s `knownHosts.removeError`), never
    /// silently dropped.
    private func deleteSelected() {
        guard let selectedSet else { return }
        let result = sessionList.deleteLoginSet(selectedSet)
        selectedID = nil
        if result.secretFailures > 0 {
            deleteErrorMessage = String(
                format: L10n.string(
                    "loginSets.deleteError %lld",
                    "Could not restore the stored password for %lld connections."),
                result.secretFailures)
        } else {
            deleteErrorMessage = nil
        }
        refreshMergeCandidate()
    }

    // MARK: - Merge banner (spec §4)

    private func refreshMergeCandidate() {
        mergeCandidate = sessionList.mergeCandidates().first
    }

    @ViewBuilder
    private func mergeBanner(_ candidate: LoginMergeCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\u{1F4A1}")
            Text(String(
                format: L10n.string(
                    "loginSets.merge.banner %lld %@",
                    "%lld connections use the same login \u{201C}%@\u{201D}."),
                candidate.sessionIDs.count, candidate.username))
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("loginSets.merge.ignore", "Ignore")) {
                sessionList.ignoreMerge(candidate)
                refreshMergeCandidate()
            }
            .buttonStyle(.polished)
            Button(L10n.string("loginSets.merge.action", "Merge…")) {
                isShowingMergeConfirm = true
            }
            .buttonStyle(.polishedProminent)
        }
        .padding(10)
        .background(DesignTokens.remoteSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Lists the affected session NAMES (resolved from `sessionIDs`) plus the
    /// target set name (spec §4) — the banner itself only names the
    /// username/count, this dialog is where the concrete connections show up
    /// before the user commits.
    private var mergeConfirmMessage: String {
        guard let mergeCandidate else { return "" }
        let names = mergeCandidate.sessionIDs
            .compactMap { id in sessionList.sessions.first { $0.id == id }?.name }
            .joined(separator: ", ")
        let targetName = sessionList.suggestedSetName(forUsername: mergeCandidate.username)
        return String(
            format: L10n.string(
                "loginSets.merge.confirmMessage %@ %@",
                "%@ will be merged into the login \u{201C}%@\u{201D}."),
            names, targetName)
    }

    private func applyMerge() {
        guard let mergeCandidate else { return }
        let targetName = sessionList.suggestedSetName(forUsername: mergeCandidate.username)
        _ = sessionList.applyMerge(mergeCandidate, name: targetName)
        refreshMergeCandidate()
    }
}

/// New/Edit sub-sheet (spec §1-2): name, username, Password|SSH-key segments
/// — the same field pattern `ConnectionFormView`'s auth block uses (SecureField
/// with a "leave empty to keep" prompt while editing, key path + "Choose…"
/// fileImporter, optional passphrase). Purely local state; `existing == nil`
/// for "New…" builds a fresh `LoginSet` on save, `existing != nil` for
/// "Edit…" keeps that set's id.
private struct LoginSetEditorView: View {
    let existing: LoginSet?
    let onSave: (LoginSet, String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var username: String
    @State private var authChoice: ConnectionViewModel.AuthChoice
    @State private var keyPath: String
    @State private var secret: String = ""
    @State private var showKeyImporter = false

    init(existing: LoginSet?, onSave: @escaping (LoginSet, String?) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: existing?.name ?? "")
        _username = State(initialValue: existing?.username ?? "")
        _authChoice = State(initialValue: existing?.authKind == .privateKey ? .privateKey : .password)
        _keyPath = State(initialValue: existing?.keyPath ?? "")
    }

    private var isEditing: Bool { existing != nil }

    /// Save disabled until name+username are non-empty, trimmed (spec §2).
    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing
                ? L10n.string("loginSets.editor.titleEdit", "Edit login")
                : L10n.string("loginSets.editor.titleNew", "New login"))
                .font(.title3.bold())

            let nameLabel = L10n.string("loginSets.editor.name", "Name")
            EditorRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }
            let usernameLabel = L10n.string("loginSets.editor.username", "Username")
            EditorRow(label: usernameLabel) {
                TextField(usernameLabel, text: $username, prompt: Text(verbatim: ""))
            }

            let authLabel = L10n.string("connection.field.authMethod", "Authentication")
            EditorRow(label: authLabel) {
                Picker(authLabel, selection: $authChoice) {
                    Text(L10n.string("connection.auth.password", "Password"))
                        .tag(ConnectionViewModel.AuthChoice.password)
                    Text(L10n.string("connection.auth.privateKey", "SSH key"))
                        .tag(ConnectionViewModel.AuthChoice.privateKey)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if authChoice == .password {
                let passwordLabel = L10n.string("connection.auth.password", "Password")
                EditorRow(label: passwordLabel) {
                    SecureField(
                        passwordLabel, text: $secret,
                        prompt: isEditing
                            ? Text(L10n.string("loginSets.editor.keepSecret", "leave empty to keep"))
                            : Text(verbatim: ""))
                }
            } else {
                let keyPathLabel = L10n.string("connection.field.keyPath", "Key path")
                EditorRow(label: keyPathLabel) {
                    HStack(spacing: 6) {
                        TextField(
                            keyPathLabel, text: $keyPath,
                            prompt: Text(L10n.string(
                                "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519")))
                        Button("…") { showKeyImporter = true }
                            .buttonStyle(.polished)
                            .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                    }
                }
                let passphraseLabel = L10n.string("connection.field.passphrase", "Passphrase (optional)")
                EditorRow(label: passphraseLabel) {
                    SecureField(
                        passphraseLabel, text: $secret,
                        prompt: isEditing
                            ? Text(L10n.string("loginSets.editor.keepSecret", "leave empty to keep"))
                            : Text(verbatim: ""))
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { onCancel() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) {
                    let set = LoginSet(
                        id: existing?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        authKind: authChoice == .privateKey ? .privateKey : .password,
                        keyPath: authChoice == .privateKey
                            ? keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            : nil)
                    onSave(set, secret.isEmpty ? nil : secret)
                }
                .buttonStyle(.polishedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                keyPath = url.path(percentEncoded: false)
            }
        }
    }
}

/// Narrower cousin of `ConnectionFormView`'s private `FormRow` (90pt label
/// column instead of 110pt, to fit this sheet's 380pt editor width).
private struct EditorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .frame(width: 90, alignment: .trailing)
            content
        }
    }
}
