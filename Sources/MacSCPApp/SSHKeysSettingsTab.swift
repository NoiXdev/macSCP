import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// The "SSH Keys" settings tab (M17/T4): lists every macSCP-managed SSH key
/// (`ManagedKeyStore`, Core M17/T2), with Generate/Copy/Export/Delete
/// actions. Shape mirrors `LoginSetsSheet`'s list-plus-actions pattern
/// (`LoginSetsSheet.swift`), adapted to a `SettingsView` tab (`.padding(20)`,
/// no own title — the tab strip already labels it, same as every other
/// tab in this file's sibling `SettingsView.swift`) instead of a standalone
/// sheet.
struct SSHKeysSettingsTab: View {
    @State private var keys: [ManagedKey] = []
    @State private var showGenerate = false
    /// Drives the delete `confirmationDialog` — non-nil means "confirm
    /// deleting this key". Same `Binding(get:set:)`-over-optional shape as
    /// `ContentView`'s `Identifiable`-item sheets, without needing a
    /// separate `Identifiable` wrapper since `ManagedKey` already is one.
    @State private var keyPendingDelete: ManagedKey?
    @State private var isExporting = false
    @State private var exportDocument: SSHPublicKeyDocument?
    @State private var exportFilename = "key.pub"
    @State private var exportErrorMessage: String?

    private let store = ManagedKeyStore(directory: SessionStore.defaultDirectory)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if keys.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.string("keys.empty", "No keys yet. Generate one to get started."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                // `List` scrolls internally, so it fits the fixed
                // 460x460 `SettingsView` frame without changing that
                // shared window size (spec M17/T4 step 2).
                List(keys) { key in row(key) }
            }

            if let exportErrorMessage {
                Text(exportErrorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("keys.generate", "Generate…")) { showGenerate = true }
                    .buttonStyle(.polishedProminent)
            }
        }
        .padding(20)
        .onAppear { reload() }
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet(store: store) { reload() }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: SSHPublicKeyDocument.preferredType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = String(
                    format: L10n.string("keys.export.error %@", "Could not write the export file: %@"),
                    String(describing: error))
            } else {
                exportErrorMessage = nil
            }
        }
        .confirmationDialog(
            L10n.string("keys.delete.title", "Delete this key?"),
            isPresented: Binding(
                get: { keyPendingDelete != nil },
                set: { isPresented in if !isPresented { keyPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("keys.delete", "Delete"), role: .destructive) { performDelete() }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    private func reload() { keys = (try? store.all()) ?? [] }

    @ViewBuilder
    private func row(_ key: ManagedKey) -> some View {
        HStack(spacing: 10) {
            typeBadge(key.type)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(key.name).font(.system(size: 13))
                    if key.hasPassphrase {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(L10n.string("keys.hasPassphrase", "Passphrase-protected"))
                    }
                }
                Text(subtitle(for: key))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !key.type.isConnectable {
                    Text(L10n.string(
                        "keys.notConnectable", "Not usable as a macSCP login (public key export only)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(key.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            actionButtons(for: key)
        }
        .padding(.vertical, 3)
        .contextMenu { actionMenuItems(for: key) }
    }

    /// Compact icon buttons, always visible per row (spec M17/T4:
    /// "Aktionen als Buttons") — `actionMenuItems` below repeats the same
    /// three actions as text-labeled items for the row's `contextMenu`.
    @ViewBuilder
    private func actionButtons(for key: ManagedKey) -> some View {
        HStack(spacing: 8) {
            Button { copyPublicKey(key) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(L10n.string("keys.copyPublic", "Copy public key"))

            Button { exportPublicKey(key) } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help(L10n.string("keys.exportPublic", "Export public key…"))

            Button { keyPendingDelete = key } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help(L10n.string("keys.delete", "Delete"))
        }
    }

    @ViewBuilder
    private func actionMenuItems(for key: ManagedKey) -> some View {
        Button(L10n.string("keys.copyPublic", "Copy public key")) { copyPublicKey(key) }
        Button(L10n.string("keys.exportPublic", "Export public key…")) { exportPublicKey(key) }
        Divider()
        Button(L10n.string("keys.delete", "Delete"), role: .destructive) { keyPendingDelete = key }
    }

    @ViewBuilder
    private func typeBadge(_ type: KeyType) -> some View {
        let (label, soft, ink) = badgeStyle(for: type)
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(soft, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(ink)
    }

    /// Label + colors for `typeBadge` above — reuses the same `DesignTokens`
    /// hues `LoginSetsSheet.badgeStyle(for:)` uses for auth-kind badges,
    /// purely for visual consistency (no semantic link between "SSH key
    /// login" and "ED25519 key type" beyond both landing on `remoteBlue`).
    private func badgeStyle(for type: KeyType) -> (label: String, soft: Color, ink: Color) {
        switch type {
        case .ed25519:
            return (L10n.string("keys.type.ed25519", "ED25519"), DesignTokens.remoteSoft, DesignTokens.remoteBlue)
        case .rsa:
            return (L10n.string("keys.type.rsa", "RSA"), DesignTokens.localSoft, DesignTokens.localAmber)
        case .ecdsa:
            return (L10n.string("keys.type.ecdsa", "ECDSA"), DesignTokens.agentSoft, DesignTokens.agentGreen)
        }
    }

    private func subtitle(for key: ManagedKey) -> String {
        let fingerprint = shortFingerprint(key.fingerprint)
        return key.comment.isEmpty ? fingerprint : "\(key.comment) · \(fingerprint)"
    }

    /// Shortens a "SHA256:…" fingerprint for the row (spec: "gekürzt") —
    /// the full value stays available via the copy/export actions, which
    /// hand over `publicKeyOpenSSH` untouched.
    private func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 28 else { return fingerprint }
        return String(fingerprint.prefix(28)) + "…"
    }

    // MARK: - Actions

    private func copyPublicKey(_ key: ManagedKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKeyOpenSSH, forType: .string)
    }

    private func exportPublicKey(_ key: ManagedKey) {
        exportDocument = SSHPublicKeyDocument(text: key.publicKeyOpenSSH + "\n")
        exportFilename = "\(key.name).pub"
        exportErrorMessage = nil
        isExporting = true
    }

    /// Best-effort usage count (spec M17/T4 "Nutzungs-Warnung beim
    /// Löschen"): sessions and login sets whose `keyPath` resolves to this
    /// key's private-key file. `SessionStore`/`LoginSetStore` are both
    /// reachable here (same `SessionStore.defaultDirectory` every other
    /// App-layer call site uses, e.g. `ContentView.swift`), so this is not
    /// the "not conveniently reachable" fallback case the spec allows for —
    /// a real count is shown. A failed load on either side degrades to 0
    /// for that side rather than blocking the delete flow.
    private func usageCount(of key: ManagedKey) -> Int {
        let target = store.keyDirectory.appendingPathComponent(key.fileName)
            .standardizedFileURL.path
        func matches(_ path: String?) -> Bool {
            guard let path, !path.isEmpty else { return false }
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                .standardizedFileURL.path == target
        }
        let directory = SessionStore.defaultDirectory
        let sessionMatches = ((try? SessionStore(directory: directory).all()) ?? [])
            .filter { matches($0.keyPath) }.count
        let loginSetMatches = ((try? LoginSetStore(directory: directory).all()) ?? [])
            .filter { matches($0.keyPath) }.count
        return sessionMatches + loginSetMatches
    }

    private var deleteConfirmMessage: String {
        guard let keyPendingDelete else { return "" }
        return String(
            format: L10n.string(
                "keys.delete.confirm %lld", "%lld saved connections reference this key."),
            usageCount(of: keyPendingDelete))
    }

    private func performDelete() {
        guard let key = keyPendingDelete else { return }
        try? store.remove(id: key.id, secrets: KeychainSecretStore())
        keyPendingDelete = nil
        reload()
    }
}

/// Write-only `FileDocument` for exporting a managed key's OpenSSH public
/// line as a `.pub` file — mirrors `AuditLogTextDocument`'s write-only
/// contract (`AuditLogSheet.swift`): the text is already assembled by the
/// time `fileExporter` is armed, and reading is never exercised.
struct SSHPublicKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [preferredType] }
    /// `.pub` has no registered system `UTType`; a dynamic one keyed off
    /// the extension keeps the save panel offering `.pub` instead of
    /// silently falling back to `.plainText`'s own preferred extension.
    static let preferredType = UTType(filenameExtension: "pub") ?? .plainText

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Generate-key sheet (M17/T4): name/comment/type/bits/passphrase fields,
/// calling `SSHKeyGenerator.generate` into the store's `keyDirectory` and
/// persisting the result via `store.add`. Shape mirrors
/// `LoginSetsSheet.LoginSetEditorView` (own small field-row helper below,
/// `.polished`/`.polishedProminent` buttons) — kept private to this file
/// since it is only ever opened from `SSHKeysSettingsTab` above.
private struct GenerateKeySheet: View {
    let store: ManagedKeyStore
    let onGenerated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var typeChoice: KeyTypeChoice = .ed25519
    @State private var rsaBits = 3072
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var errorMessage: String?

    /// A `Picker`-friendly stand-in for `KeyType` — `KeyType.rsa` carries a
    /// `bits` payload, so it can't be a segmented-picker `tag` on its own;
    /// `rsaBits` below supplies that payload separately.
    private enum KeyTypeChoice: String, CaseIterable, Identifiable {
        case ed25519, rsa, ecdsa
        var id: String { rawValue }
    }

    private var resolvedType: KeyType {
        switch typeChoice {
        case .ed25519: return .ed25519
        case .rsa: return .rsa(bits: rsaBits)
        case .ecdsa: return .ecdsa
        }
    }

    private var passphrasesMismatch: Bool { passphrase != passphraseConfirm }

    private var isGenerateDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || passphrasesMismatch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.generate.title", "Generate SSH Key")).font(.title3.bold())

            let nameLabel = L10n.string("keys.generate.name", "Name")
            GenerateFieldRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }
            let commentLabel = L10n.string("keys.generate.comment", "Comment")
            GenerateFieldRow(label: commentLabel) {
                TextField(commentLabel, text: $comment, prompt: Text(verbatim: ""))
            }
            let typeLabel = L10n.string("keys.generate.type", "Type")
            GenerateFieldRow(label: typeLabel) {
                Picker(typeLabel, selection: $typeChoice) {
                    Text(L10n.string("keys.type.ed25519", "ED25519")).tag(KeyTypeChoice.ed25519)
                    Text(L10n.string("keys.type.rsa", "RSA")).tag(KeyTypeChoice.rsa)
                    Text(L10n.string("keys.type.ecdsa", "ECDSA")).tag(KeyTypeChoice.ecdsa)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if typeChoice != .ed25519 {
                Text(L10n.string(
                    "keys.notConnectable", "Not usable as a macSCP login (public key export only)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if typeChoice == .rsa {
                let bitsLabel = L10n.string("keys.generate.bits", "Key size")
                GenerateFieldRow(label: bitsLabel) {
                    Picker(bitsLabel, selection: $rsaBits) {
                        Text("2048").tag(2048)
                        Text("3072").tag(3072)
                        Text("4096").tag(4096)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            let passphraseLabel = L10n.string("keys.generate.passphrase", "Passphrase (optional)")
            GenerateFieldRow(label: passphraseLabel) {
                SecureField(passphraseLabel, text: $passphrase, prompt: Text(verbatim: ""))
            }
            let confirmLabel = L10n.string("keys.generate.passphrase.confirm", "Confirm passphrase")
            GenerateFieldRow(label: confirmLabel) {
                SecureField(confirmLabel, text: $passphraseConfirm, prompt: Text(verbatim: ""))
            }
            if passphrasesMismatch && !passphraseConfirm.isEmpty {
                Text(L10n.string("keys.generate.passphrase.mismatch", "Passphrases don't match."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("keys.generate.submit", "Generate")) { generate() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isGenerateDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
    }

    /// Generates the key on disk, saves the passphrase (if any) to the
    /// Keychain under a FRESH id, and persists the resulting `ManagedKey` —
    /// order matters: the Keychain write and `store.add` only happen after
    /// `SSHKeyGenerator.generate` succeeds, so a failed generation never
    /// leaves an orphaned Keychain entry or metadata record.
    private func generate() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let generated = try SSHKeyGenerator.generate(
                type: resolvedType, comment: trimmedComment,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                into: store.keyDirectory)
            let newID = UUID()
            if !passphrase.isEmpty {
                try KeychainSecretStore().savePassword(passphrase, for: newID)
            }
            let key = ManagedKey(
                id: newID, name: trimmedName, comment: trimmedComment, type: resolvedType,
                fingerprint: generated.fingerprint, publicKeyOpenSSH: generated.publicKeyOpenSSH,
                createdAt: Date(), hasPassphrase: !passphrase.isEmpty,
                fileName: generated.privateKeyURL.lastPathComponent)
            try store.add(key)
            onGenerated()
            dismiss()
        } catch {
            // Never surface the underlying error (same reasoning as
            // `PresignedURLSheet.generate`) — a fixed message only; the
            // failure carries no secret material here, but this keeps the
            // sheet consistent with the rest of the app's error surfaces.
            errorMessage = L10n.string("keys.generate.error", "Couldn't generate the key.")
        }
    }
}

/// Narrow field-row helper — same shape as `LoginSetsSheet.EditorRow`, kept
/// as its own private copy here since that one is private to its own file.
private struct GenerateFieldRow<Content: View>: View {
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
