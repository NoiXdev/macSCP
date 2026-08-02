import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// SSH-key management sheet (M18/T5): the standalone overlay for managing
/// macSCP-managed SSH keys, reachable from the Sessions menu and the form's
/// "Manage keys…" link, same as `LoginSetsSheet`/`KnownHostsSheet`. Replaces
/// the M17 `SSHKeysSettingsTab` (removed in M18/T6 — this sheet is now the
/// only place keys are managed). Shape mirrors `LoginSetsSheet` (title,
/// `SheetSearchField` + `sheetSearchPredicate`, filtered list with a
/// `*.noMatches` vs. `*.empty` distinction, footer buttons, fixed
/// `.frame(width: 720, height: 460)`, row `.contextMenu`).
///
/// `GenerateKeySheet` and `SSHPublicKeyDocument` below are this file's own
/// types (moved from the removed `SSHKeysSettingsTab.swift`).
struct SSHKeysSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var keys: [ManagedKey] = []
    @State private var searchText = ""
    @State private var searchIsRegex = false

    @State private var showGenerate = false

    /// Drives the private-key file picker (Step 2) — on success, wraps the
    /// chosen URL in `ImportTarget` so `.sheet(item:)` has a stable identity
    /// (`URL` alone isn't `Identifiable`) and opens `ImportKeySheet`.
    @State private var showImportFileImporter = false
    @State private var importTarget: ImportTarget?

    /// `ManagedKey` is already `Identifiable`, so the rename sub-sheet reuses
    /// that identity directly instead of a wrapper (same reasoning
    /// `LoginSetsSheet`'s `LoginSetEditorTarget` documents for why the "new"
    /// case there needs one but this one-target-only sheet doesn't).
    @State private var renameTarget: ManagedKey?

    /// Drives the delete `confirmationDialog` — non-nil means "confirm
    /// deleting this key".
    @State private var keyPendingDelete: ManagedKey?

    /// Drives the private-key export warning `confirmationDialog` (M18/T5,
    /// security constraint: private-key export is NEVER a single click —
    /// this dialog is the one and only gate, whether reached from the row's
    /// icon button or its context menu).
    @State private var exportPrivateTarget: ManagedKey?

    @State private var isExporting = false
    @State private var exportDocument: SSHPublicKeyDocument?
    @State private var exportFilename = "key.pub"

    @State private var isExportingPrivate = false
    @State private var exportPrivateDocument: SSHPrivateKeyExportDocument?
    @State private var exportPrivateFilename = "key"

    /// Shared error banner for this sheet's own action failures — export
    /// (both `fileExporter` completions) and delete write into it.
    @State private var errorMessage: String?

    private let store = ManagedKeyStore(directory: SessionStore.defaultDirectory)

    private struct ImportTarget: Identifiable {
        let id = UUID()
        let fileURL: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.sheet.title", "SSH Keys")).font(.headline)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            let (predicate, searchError) = sheetSearchPredicate(
                text: searchText, isRegex: searchIsRegex)
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)
                .padding(.bottom, 4)

            let visibleKeys = keys.filter {
                predicate.matches("\($0.name) \($0.comment) \($0.fingerprint)")
            }

            if visibleKeys.isEmpty {
                Spacer(minLength: 0)
                Text(searchText.isEmpty
                    ? L10n.string("keys.empty", "No keys yet. Generate one to get started.")
                    : L10n.string("keys.noMatches", "No matches."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                List(visibleKeys) { key in row(key) }
            }

            HStack {
                Spacer()
                Button(L10n.string("keys.import", "Import…")) { showImportFileImporter = true }
                    .buttonStyle(.polished)
                Button(L10n.string("keys.generate", "Generate…")) { showGenerate = true }
                    .buttonStyle(.polished)
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { reload() }
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet(store: store) { reload() }
        }
        .fileImporter(
            isPresented: $showImportFileImporter, allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result {
                importTarget = ImportTarget(fileURL: url)
            }
        }
        .sheet(item: $importTarget) { target in
            ImportKeySheet(fileURL: target.fileURL, store: store) { reload() }
        }
        .sheet(item: $renameTarget) { key in
            RenameKeySheet(key: key, store: store) { reload() }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: SSHPublicKeyDocument.preferredType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = String(
                    format: L10n.string("keys.export.error %@", "Could not write the export file: %@"),
                    String(describing: error))
            } else {
                errorMessage = nil
            }
        }
        .fileExporter(
            isPresented: $isExportingPrivate,
            document: exportPrivateDocument,
            contentType: .data,
            defaultFilename: exportPrivateFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = String(
                    format: L10n.string("keys.export.error %@", "Could not write the export file: %@"),
                    String(describing: error))
            } else {
                errorMessage = nil
            }
            // The completion handler fires after the write (success) or the
            // cancel/failure path completes, so it's safe to drop the raw
            // private key bytes here rather than keeping them in view state
            // for the sheet's remaining lifetime.
            exportPrivateDocument = nil
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
        // Private-key export warning (M18/T5 security constraint): the ONLY
        // path to `isExportingPrivate = true` — reached from either the
        // row's icon button or its context menu, both just set
        // `exportPrivateTarget`.
        .confirmationDialog(
            L10n.string("keys.exportPrivate.title", "Export the private key?"),
            isPresented: Binding(
                get: { exportPrivateTarget != nil },
                set: { isPresented in if !isPresented { exportPrivateTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("keys.exportPrivate.confirm", "Export")) { beginPrivateExport() }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { exportPrivateTarget = nil }
        } message: {
            Text(L10n.string(
                "keys.exportPrivate.warn", "The private key will leave the protected store. Continue?"))
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

    /// Compact icon buttons, always visible per row — a "buttons plus a
    /// context menu that repeats them" split, extended with rename and
    /// private-key export (Step 2).
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

            Button { exportPrivateTarget = key } label: {
                Image(systemName: "lock.open")
            }
            .buttonStyle(.plain)
            .help(L10n.string("keys.exportPrivate", "Export private key…"))

            Button { renameTarget = key } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help(L10n.string("keys.rename", "Rename…"))

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
        Button(L10n.string("keys.exportPrivate", "Export private key…")) { exportPrivateTarget = key }
        Button(L10n.string("keys.rename", "Rename…")) { renameTarget = key }
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
        errorMessage = nil
        isExporting = true
    }

    /// Reads the private key's bytes off disk and arms `isExportingPrivate`
    /// — the ONLY caller is the confirmation dialog's "Export" button above,
    /// so by the time this runs the user has already seen and accepted the
    /// "leaves the protected store" warning.
    private func beginPrivateExport() {
        guard let key = exportPrivateTarget else { return }
        exportPrivateTarget = nil
        let source = store.keyDirectory.appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: source) else {
            errorMessage = L10n.string("keys.exportPrivate.error", "Couldn't read the private key file.")
            return
        }
        exportPrivateDocument = SSHPrivateKeyExportDocument(data: data)
        exportPrivateFilename = key.name
        errorMessage = nil
        isExportingPrivate = true
    }

    /// Best-effort usage count: sessions and login sets whose `keyPath`
    /// resolves to this key's private-key file.
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
        do {
            try store.remove(id: key.id, secrets: KeychainSecretStore())
            errorMessage = nil
        } catch {
            errorMessage = L10n.string("keys.delete.error", "Couldn't delete the key.")
        }
        keyPendingDelete = nil
        reload()
    }
}

/// Write-only `FileDocument` for exporting a managed key's OpenSSH public
/// line as a `.pub` file — mirrors `AuditLogTextDocument`'s write-only
/// contract (`AuditLogSheet.swift`): the text is already assembled by the
/// time `fileExporter` is armed, and reading is never exercised. Moved here
/// from the removed `SSHKeysSettingsTab.swift` (M18/T6).
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

/// Write-only `FileDocument` for exporting a managed key's PRIVATE key file
/// bytes (M18/T5) — same write-only contract as `SSHPublicKeyDocument`
/// above, but holds the raw bytes read off disk instead of an assembled
/// OpenSSH text line. Generic `.data` content type: private keys have no
/// fixed extension (`id_ed25519` has none), so there is no single UTType to
/// prefer the way `.pub` works for the public-key export.
struct SSHPrivateKeyExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Generate-key sheet (M17/T4): name/comment/type/bits/passphrase fields,
/// calling `SSHKeyGenerator.generate` into the store's `keyDirectory` and
/// persisting the result via `store.add`. Shape mirrors
/// `LoginSetsSheet.LoginSetEditorView` (own small field-row helper below,
/// `.polished`/`.polishedProminent` buttons). Moved here from the removed
/// `SSHKeysSettingsTab.swift` (M18/T6) — `internal` (not `private`) so it
/// stays usable from `SSHKeysSheet.body`'s `.sheet(isPresented:)` above.
struct GenerateKeySheet: View {
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
            KeyFieldRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }
            let commentLabel = L10n.string("keys.generate.comment", "Comment")
            KeyFieldRow(label: commentLabel) {
                TextField(commentLabel, text: $comment, prompt: Text(verbatim: ""))
            }
            let typeLabel = L10n.string("keys.generate.type", "Type")
            KeyFieldRow(label: typeLabel) {
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
                KeyFieldRow(label: bitsLabel) {
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
            KeyFieldRow(label: passphraseLabel) {
                SecureField(passphraseLabel, text: $passphrase, prompt: Text(verbatim: ""))
            }
            let confirmLabel = L10n.string("keys.generate.passphrase.confirm", "Confirm passphrase")
            KeyFieldRow(label: confirmLabel) {
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
    /// Keychain under a FRESH id, and persists the resulting `ManagedKey`.
    ///
    /// `savePassword`/`store.add` run in an INNER `do/catch` so that a
    /// failure on either of them — AFTER `SSHKeyGenerator.generate` already
    /// wrote the private/public key files (and possibly the Keychain entry,
    /// if `store.add` is what threw) — actively rolls back everything THIS
    /// run created, instead of leaving orphaned artifacts behind (a key file
    /// with no metadata record, or a Keychain entry with no matching key).
    /// The cleaned-up error is then re-thrown so the outer `catch` still
    /// reports the same single fixed message as any other failure.
    private func generate() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let generated = try SSHKeyGenerator.generate(
                type: resolvedType, comment: trimmedComment,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                into: store.keyDirectory)
            let newID = UUID()
            do {
                if !passphrase.isEmpty {
                    try KeychainSecretStore().savePassword(passphrase, for: newID)
                }
                let key = ManagedKey(
                    id: newID, name: trimmedName, comment: trimmedComment, type: resolvedType,
                    fingerprint: generated.fingerprint, publicKeyOpenSSH: generated.publicKeyOpenSSH,
                    createdAt: Date(), hasPassphrase: !passphrase.isEmpty,
                    fileName: generated.privateKeyURL.lastPathComponent)
                try store.add(key)
            } catch {
                try? FileManager.default.removeItem(at: generated.privateKeyURL)
                try? FileManager.default.removeItem(
                    at: generated.privateKeyURL.deletingLastPathComponent()
                        .appendingPathComponent(generated.privateKeyURL.lastPathComponent + ".pub"))
                try? KeychainSecretStore().deletePassword(for: newID)
                throw error
            }
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

/// Import-key sheet (M18/T5 Step 2): name/comment/optional-passphrase fields
/// for the private key file the caller already picked via `fileImporter`.
/// `SSHKeyImporter.inspect` (Task 4) reads the file first — on success, the
/// file is copied into `store.keyDirectory` under a FRESH id, chmod'd 0600,
/// the passphrase (if any) saved to the Keychain under that SAME id, and the
/// resulting `ManagedKey` persisted. A failure at any point AFTER the copy
/// rolls back both the copied file and the Keychain slot (best-effort,
/// `try?`) — mirrors `GenerateKeySheet.generate()`'s own rollback for the
/// exact same reason: never leave an orphaned file or Keychain entry behind.
private struct ImportKeySheet: View {
    let fileURL: URL
    let store: ManagedKeyStore
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var errorMessage: String?

    init(fileURL: URL, store: ManagedKeyStore, onImported: @escaping () -> Void) {
        self.fileURL = fileURL
        self.store = store
        self.onImported = onImported
        _name = State(initialValue: fileURL.lastPathComponent)
    }

    private var isImportDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.import.title", "Import SSH Key")).font(.title3.bold())

            let fileLabel = L10n.string("keys.import.file", "File")
            KeyFieldRow(label: fileLabel) {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            let nameLabel = L10n.string("keys.generate.name", "Name")
            KeyFieldRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }
            let commentLabel = L10n.string("keys.generate.comment", "Comment")
            KeyFieldRow(label: commentLabel) {
                TextField(commentLabel, text: $comment, prompt: Text(verbatim: ""))
            }
            let passphraseLabel = L10n.string("keys.generate.passphrase", "Passphrase (optional)")
            KeyFieldRow(label: passphraseLabel) {
                SecureField(passphraseLabel, text: $passphrase, prompt: Text(verbatim: ""))
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("keys.import.submit", "Import")) { performImport() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImportDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
    }

    private func performImport() {
        // `fileURL` came out of a `fileImporter` picker in the parent sheet,
        // possibly outside this app's own sandbox container — the same
        // access dance `ContentView.handleImportFileSelection` already
        // documents for session imports.
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let info = try SSHKeyImporter.inspect(
                privateKeyURL: fileURL, passphrase: passphrase.isEmpty ? nil : passphrase)
            let newID = UUID()
            let destination = store.keyDirectory.appendingPathComponent(newID.uuidString)
            do {
                try FileManager.default.createDirectory(
                    at: store.keyDirectory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                // `createDirectory` only applies `attributes` when it creates the
                // directory; if it already existed, permissions are left untouched.
                // Harden explicitly so the 0700 invariant holds either way.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: store.keyDirectory.path(percentEncoded: false))
                try FileManager.default.copyItem(at: fileURL, to: destination)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: destination.path(percentEncoded: false))
                if !passphrase.isEmpty {
                    try KeychainSecretStore().savePassword(passphrase, for: newID)
                }
                let key = ManagedKey(
                    id: newID, name: trimmedName, comment: trimmedComment, type: info.type,
                    fingerprint: info.fingerprint, publicKeyOpenSSH: info.publicKeyOpenSSH,
                    createdAt: Date(), hasPassphrase: !passphrase.isEmpty,
                    fileName: newID.uuidString)
                try store.add(key)
            } catch {
                // Anything failing AFTER the copy above (chmod, Keychain
                // save, or `store.add`) must not leave an orphaned file or
                // Keychain slot behind — both removals are best-effort and
                // safe to run even if the step that "created" them never
                // actually got there (e.g. `copyItem` itself is what threw).
                try? FileManager.default.removeItem(at: destination)
                try? KeychainSecretStore().deletePassword(for: newID)
                throw error
            }
            onImported()
            dismiss()
        } catch {
            // Fixed message only (same reasoning as `GenerateKeySheet`):
            // never surface the underlying error, which could otherwise leak
            // filesystem paths or `ssh-keygen` diagnostics.
            errorMessage = L10n.string("keys.import.error", "Couldn't import the key.")
        }
    }
}

/// Rename sheet (M18/T5 Step 2): name/comment only — an UPSERT of the same
/// `id` (file and Keychain slot are untouched, per the M17 invariant that
/// only metadata changes here).
private struct RenameKeySheet: View {
    let key: ManagedKey
    let store: ManagedKeyStore
    let onRenamed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var comment: String
    @State private var errorMessage: String?

    init(key: ManagedKey, store: ManagedKeyStore, onRenamed: @escaping () -> Void) {
        self.key = key
        self.store = store
        self.onRenamed = onRenamed
        _name = State(initialValue: key.name)
        _comment = State(initialValue: key.comment)
    }

    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.rename.title", "Rename Key")).font(.title3.bold())

            let nameLabel = L10n.string("keys.generate.name", "Name")
            KeyFieldRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }
            let commentLabel = L10n.string("keys.generate.comment", "Comment")
            KeyFieldRow(label: commentLabel) {
                TextField(commentLabel, text: $comment, prompt: Text(verbatim: ""))
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) { save() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
    }

    private func save() {
        var updated = key
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.add(updated)
            onRenamed()
            dismiss()
        } catch {
            errorMessage = L10n.string("keys.rename.error", "Couldn't rename the key.")
        }
    }
}

/// Narrow field-row helper shared by this file's small sheets (Generate,
/// Import, Rename) — same shape as `LoginSetsSheet.EditorRow`, kept as its
/// own private copy since that one is private to its own file.
private struct KeyFieldRow<Content: View>: View {
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
