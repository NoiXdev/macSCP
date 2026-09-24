import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// SSH-key management sheet (M18/T5): the standalone overlay for managing
/// macSCP-managed SSH keys, reachable from the Sessions menu and the form's
/// "Manage keys…" link, same as `LoginSetsSheet`/`KnownHostsSheet`. Replaces
/// the M17 `SSHKeysSettingsTab` (removed in M18/T6 — this sheet is now the
/// only place keys are managed). Shape mirrors `LoginSetsSheet` (title,
/// `SheetSearchField` + `sheetSearchPredicate`, the `SheetFacetPicker`
/// under it and the `SheetListEmptyState` that names which of the two
/// narrowings emptied the list, footer buttons and the shared
/// `SheetOverflowMenu`, fixed
/// `.frame(width: 720, height: 460)`, row `.contextMenu`).
///
/// The facet here is the KEY TYPE (facet design, 2026-08-29), derived from
/// the keys on disk rather than from `KeyType`'s cases: a type nobody has
/// is not offered, and with only one type present the picker does not
/// appear at all.
///
/// `GenerateKeySheet` and `SSHPublicKeyDocument` below are this file's own
/// types (moved from the removed `SSHKeysSettingsTab.swift`).
struct SSHKeysSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The READ, not just its result: an unreadable store must not render as
    /// "No keys yet." on the one screen whose job is to answer which keys
    /// exist (see `ManagedKeysLoad`).
    @State private var load: ManagedKeysLoad = .loaded([])
    @State private var searchText = ""
    @State private var searchIsRegex = false
    /// The key-type quick filter (facet design, 2026-08-29). A view, not a
    /// setting: it starts cleared every time the sheet opens, so it can
    /// never name a type no managed key carries any more.
    @State private var facet: SheetFacetFilter = .all

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

    /// Drives the "Correct the stored passphrase" sub-sheet — the key's own
    /// identity again, for the reason `renameTarget` gives.
    @State private var correctPassphraseTarget: ManagedKey?

    /// Drives the "Change the key's passphrase" sub-sheet. Deliberately a
    /// SECOND target rather than a mode on the first: one of the two rewrites
    /// the key file and the other cannot, and a single sheet with a switch
    /// would put one press between them (maintainer's answer, 2026-09-24:
    /// "both, as two separate actions").
    @State private var changePassphraseTarget: ManagedKey?

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

            SheetFacetPicker(
                values: SheetFacetFilter.values(of: load.keys) { Self.keyTypeLabel($0.type) },
                label: L10n.string("keys.facet.type", "Key type"),
                filter: $facet)
                .padding(.bottom, 4)

            // The search and the key-type facet applied together, in one call
            // to the shared chaining — so what the list draws and what the
            // empty state blames are two readings of the same pass.
            let narrowing = facet.narrowing(
                load.keys,
                search: predicate,
                searchText: { "\($0.name) \($0.comment) \($0.fingerprint)" },
                facetValue: { Self.keyTypeLabel($0.type) })
            let visibleKeys = narrowing.visible

            if visibleKeys.isEmpty {
                Spacer(minLength: 0)
                // The unreadable case comes FIRST and is not a variant of
                // "empty": the file is there and still holds every key, so
                // neither the store-is-empty sentence nor a narrowing would
                // be the truth, and there is nothing for "Show all" to clear.
                if load.isUnreadable {
                    Text(Self.unreadableMessage)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    SheetListEmptyState(
                        emptiness: narrowing.emptiness,
                        noRowsMessage: L10n.string(
                            "keys.empty", "No keys yet. Generate one to get started."),
                        noSearchMatchesMessage: L10n.string("keys.noMatches", "No matches."),
                        onShowAll: clearNarrowings)
                }
                Spacer(minLength: 0)
            } else {
                List(visibleKeys) { key in row(key) }
            }

            HStack {
                Spacer()
                Button(L10n.string("keys.generate", "Generate…")) { showGenerate = true }
                    .buttonStyle(.polished)
                // Same rule as the logins sheet (backlog 2026-08-20, point 5):
                // Import reads a file from disk, so it belongs under the menu.
                // This sheet gets the menu not for want of footer space but so
                // the rule holds in one place rather than one of two.
                SheetOverflowMenu(
                    actions: SheetOverflowAction.offered(canExport: false, canImport: true)
                ) { action in
                    switch action {
                    case .import:
                        showImportFileImporter = true
                    case .export:
                        // Not offered here, so never delivered: the per-key
                        // exports live in the row, and an action that cannot
                        // apply is absent rather than greyed. When the private
                        // export moves into the footer, it lands here.
                        break
                    }
                }
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { reload() }
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet(store: store) { keptPassphrase in
                reportKeyOutcome(keptPassphrase: keptPassphrase)
            }
        }
        .fileImporter(
            isPresented: $showImportFileImporter, allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result {
                importTarget = ImportTarget(fileURL: url)
            }
        }
        .sheet(item: $importTarget) { target in
            ImportKeySheet(fileURL: target.fileURL, store: store) { _, keptPassphrase in
                reportKeyOutcome(keptPassphrase: keptPassphrase)
            }
        }
        .sheet(item: $renameTarget) { key in
            RenameKeySheet(key: key, store: store) { reload() }
        }
        .sheet(item: $correctPassphraseTarget) { key in
            CorrectKeyPassphraseSheet(key: key, store: store) {
                reload()
                errorMessage = nil
            }
        }
        .sheet(item: $changePassphraseTarget) { key in
            ChangeKeyPassphraseSheet(key: key, store: store) { outcome in
                reportPassphraseChange(outcome)
            }
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

    private func reload() { load = ManagedKeysLoad(reading: store) }

    /// What stands in place of the list when the keys file is there but
    /// cannot be decoded — see the branch in `body` that prefers it over
    /// every emptiness the narrowing could report.
    private static var unreadableMessage: String {
        L10n.string(
            "keys.load.error",
            "The keys file couldn't be read. It exists but can't be decoded \u{2014} no key was lost, and nothing will be written over it.")
    }

    /// Clears BOTH narrowings — what the empty state's "Show all" does. One
    /// of them alone would leave the list just as empty.
    private func clearNarrowings() {
        searchText = ""
        facet = .all
    }

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
        Button(L10n.string("keys.passphrase.correct", "Correct the stored passphrase…")) {
            correctPassphraseTarget = key
        }
        .disabled(!Self.canCorrectPassphrase(key, in: store))
        Button(L10n.string("keys.passphrase.change", "Change the key's passphrase…")) {
            changePassphraseTarget = key
        }
        .disabled(!Self.canChangePassphrase(key, in: store))
        Divider()
        Button(L10n.string("keys.delete", "Delete"), role: .destructive) { keyPendingDelete = key }
    }

    /// When "Correct the stored passphrase" applies: the key FILE is
    /// encrypted, so there is a passphrase for macSCP to be remembering
    /// wrongly, AND the metadata names a file inside the key directory, so
    /// there is something to verify the typed value against. For an
    /// unencrypted key there is nothing to store — the action is greyed
    /// rather than absent, because "this key has no passphrase" is the
    /// answer the user came for.
    static func canCorrectPassphrase(_ key: ManagedKey, in store: ManagedKeyStore) -> Bool {
        key.hasPassphrase && store.privateKeyURL(for: key) != nil
    }

    /// When "Change the key's passphrase" applies: whenever the metadata
    /// names a file inside the key directory. An UNENCRYPTED key is included
    /// on purpose — the action then encrypts it, leaving the current
    /// passphrase field empty — so the only thing greyed here is an entry
    /// whose `fileName` addresses no file macSCP owns
    /// (`ManagedKeyStore.privateKeyURL(for:)` refuses it), which takes a
    /// hand-edited `managed_keys.json` to produce.
    static func canChangePassphrase(_ key: ManagedKey, in store: ManagedKeyStore) -> Bool {
        store.privateKeyURL(for: key) != nil
    }

    @ViewBuilder
    private func typeBadge(_ type: KeyType) -> some View {
        let (label, soft, ink) = Self.badgeStyle(for: type)
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(soft, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(ink)
    }

    /// How a key's type is written wherever this sheet writes it — the badge
    /// and the facet both go through here, so the value the picker offers is
    /// character-for-character the value a row is matched on.
    ///
    /// Note what this makes true of `rsa`: its bit count is not part of the
    /// label, so every RSA key lands in one facet regardless of length. That
    /// is the wanted reading (a facet is a small, closed dimension) and it
    /// costs nothing, since key length is not offered as a facet at all —
    /// it lives inside a composed subtitle string, which the design rules
    /// out as a facet source.
    static func keyTypeLabel(_ type: KeyType) -> String {
        badgeStyle(for: type).label
    }

    private static func badgeStyle(for type: KeyType) -> (label: String, soft: Color, ink: Color) {
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

    /// Refreshes the list after a key was generated or imported, and says so
    /// when the key made it but its passphrase did not. The message belongs
    /// HERE and not in the creating sheet: that sheet dismisses itself on the
    /// same run, and the key must not be creatable a second time just to
    /// surface a note about the first one. `reload()` only refills `keys` and
    /// leaves `errorMessage` alone, so the note survives it either way.
    private func reportKeyOutcome(keptPassphrase: Bool) {
        reload()
        if !keptPassphrase {
            errorMessage = L10n.string(
                "keys.passphrase.notStored",
                "The key was saved, but its passphrase wasn't. It will be asked for on the next connection.")
        }
    }

    /// Refreshes the list after the key file's passphrase was changed, and
    /// says so when the file was rewritten but macSCP could not finish
    /// writing the new passphrase down.
    ///
    /// The note belongs HERE, not in the sheet that did the work: that sheet
    /// dismisses itself on the same run, and the change must not be offered a
    /// second time just to surface a remark about the first one — the same
    /// reasoning `reportKeyOutcome(keptPassphrase:)` above spells out. It is
    /// not phrased as a failure, because it is not one: the key file really
    /// does use the new passphrase now.
    private func reportPassphraseChange(_ outcome: ChangeKeyPassphraseForm.Outcome) {
        reload()
        errorMessage = outcome == .changedButNotStored
            ? L10n.string(
                "keys.passphrase.change.notStored",
                "The key file now uses the new passphrase \u{2014} from now on only that opens it. macSCP couldn't finish saving it, so it may be asked for on the next connection.")
            : nil
    }

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
        // `privateKeyURL` refuses a `fileName` that would leave the key
        // directory, so a tampered store file cannot turn "export my key"
        // into "export whatever that name points at".
        guard let source = store.privateKeyURL(for: key),
              let data = try? Data(contentsOf: source)
        else {
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
        guard let target = store.privateKeyURL(for: key)?.standardizedFileURL.path else { return 0 }
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
/// `SSHKeysSettingsTab.swift` (M18/T6) — `private` like its neighbors
/// `ImportKeySheet`/`RenameKeySheet` below: a top-level `private` type is
/// file-scoped, so it stays usable from `SSHKeysSheet.body`'s
/// `.sheet(isPresented:)` above without needing wider visibility.
private struct GenerateKeySheet: View {
    let store: ManagedKeyStore
    /// `false` means the key exists but its passphrase did not reach the
    /// Keychain — see `GenerateKeyForm.run`.
    let onGenerated: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The fields, the latch and the run live in `GenerateKeyForm` (Core),
    /// where `GenerateKeyFormTests` can edit fields mid-run and cancel one.
    @State private var form = GenerateKeyForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.generate.title", "Generate SSH Key")).font(.title3.bold())

            // Fixed while `ssh-keygen` runs: the run works from the values it
            // started with (`GenerateKeyForm`), and fields that went on
            // accepting edits would show a key the sheet is not making.
            Group {
                let nameLabel = L10n.string("keys.generate.name", "Name")
                KeyFieldRow(label: nameLabel) {
                    TextField(nameLabel, text: $form.name, prompt: Text(verbatim: ""))
                }
                let commentLabel = L10n.string("keys.generate.comment", "Comment")
                KeyFieldRow(label: commentLabel) {
                    TextField(commentLabel, text: $form.comment, prompt: Text(verbatim: ""))
                }
                let typeLabel = L10n.string("keys.generate.type", "Type")
                KeyFieldRow(label: typeLabel) {
                    Picker(typeLabel, selection: $form.typeChoice) {
                        Text(L10n.string("keys.type.ed25519", "ED25519")).tag(GenerateKeyForm.TypeChoice.ed25519)
                        Text(L10n.string("keys.type.rsa", "RSA")).tag(GenerateKeyForm.TypeChoice.rsa)
                        Text(L10n.string("keys.type.ecdsa", "ECDSA")).tag(GenerateKeyForm.TypeChoice.ecdsa)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if !form.resolvedType.isConnectable {
                    Text(L10n.string(
                        "keys.notConnectable", "Not usable as a macSCP login (public key export only)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if form.typeChoice == .rsa {
                    let bitsLabel = L10n.string("keys.generate.bits", "Key size")
                    KeyFieldRow(label: bitsLabel) {
                        Picker(bitsLabel, selection: $form.rsaBits) {
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
                    SecureField(passphraseLabel, text: $form.passphrase, prompt: Text(verbatim: ""))
                }
                let confirmLabel = L10n.string("keys.generate.passphrase.confirm", "Confirm passphrase")
                KeyFieldRow(label: confirmLabel) {
                    SecureField(confirmLabel, text: $form.passphraseConfirm, prompt: Text(verbatim: ""))
                }
            }
            .disabled(form.isGenerating)
            if form.passphrasesMismatch && !form.passphraseConfirm.isEmpty {
                Text(L10n.string("keys.generate.passphrase.mismatch", "Passphrases don't match."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let errorMessage = form.failure.map(Self.message(for:)) {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) {
                    form.cancel()
                    dismiss()
                }
                    .buttonStyle(.polished)
                Button(L10n.string("keys.generate.submit", "Generate")) { generate() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.isGenerateDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
        // However the sheet goes away — Cancel, Escape, the parent closing —
        // a run still in flight is cancelled, so a dismissed sheet adds no
        // key. A finished run makes this a no-op.
        .onDisappear { form.cancel() }
    }

    /// Hands the run to the form, which captures every field before
    /// `ssh-keygen` starts, refuses an overlapping press, and on success is
    /// where the key and its Keychain slot are written (on the main actor).
    @MainActor private func generate() {
        guard let task = form.start(store: store, secrets: KeychainSecretStore()) else { return }
        Task { @MainActor in
            if case .generated(let keptPassphrase) = await task.value {
                onGenerated(keptPassphrase)
                dismiss()
            }
        }
    }

    /// A fixed message per failure — never the underlying error (same
    /// reasoning as `PresignedURLSheet.generate`). A timeout gets its own, so
    /// a tool that was stopped does not read like a key that is broken.
    private static func message(for failure: GenerateKeyForm.Failure) -> String {
        switch failure {
        case .failed:
            return L10n.string("keys.generate.error", "Couldn't generate the key.")
        case .timedOut:
            return L10n.string(
                "keys.generate.error.timedOut",
                "Generating the key took too long and was stopped. Nothing was saved.")
        }
    }
}

/// Import-key sheet (M18/T5 Step 2): name/comment/optional-passphrase fields
/// for the private key file the caller already picked via `fileImporter`.
///
/// The file is copied into `store.keyDirectory` under a FRESH id and
/// CONVERTED to OpenSSH format on the way (`SSHKeyConverter.copyAsOpenSSH`,
/// PEM private keys plan, Task 4); the copy is what `SSHKeyImporter.inspect`
/// then reads, the resulting `ManagedKey` is persisted, and only THEN is the
/// passphrase (if any) saved to the Keychain under that SAME id. A failure up
/// to and including the metadata write rolls the copied file back; a failed
/// passphrase write keeps the key and reports itself instead — same ordering
/// and the same reasoning as `GenerateKeySheet.generate()`, whose doc spells
/// both directions out.
///
/// Converting on the way in is what keeps the store homogeneous. Until Task 4
/// the inspection ran on the SOURCE and the copy was a byte-for-byte
/// `copyItem`, so a PEM key imported that way would connect (the loader reads
/// PEM now) but could never be exported — `EmbeddedKeyPorter` requires the
/// OpenSSH boundary, for the reason its own comment gives.
///
/// Not `private`: the failed-connect surface presents this same sheet for its
/// "Convert key…" remedy (`ContentView.convertFailedKey(_:)`), which is why
/// `onImported` hands back the `ManagedKey` it created — that caller has to
/// re-point a session at the new file, and the key is where its path comes
/// from. It ignores the `Bool`; `onImported`'s own doc says why.
struct ImportKeySheet: View {
    let fileURL: URL
    let store: ManagedKeyStore
    /// The key that was created, and whether its passphrase reached the
    /// Keychain — `false` means the key exists but the passphrase did not,
    /// see `GenerateKeySheet.generate()`.
    ///
    /// `true` is NOT "a Keychain slot exists" and must not be read as one
    /// (PEM private keys plan, Task 4 fix round 2, review finding MEDIUM 1).
    /// An import with an EMPTY passphrase writes no slot and reports `true`,
    /// because the flag answers "did what the user typed get lost", which is
    /// the question its consumer `SSHKeysSheet.reportKeyOutcome(
    /// keptPassphrase:)` asks in order to warn about it. A caller that needs
    /// the other question — does the key's slot hold a passphrase — asks
    /// `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`,
    /// as `ContentView.convertedKeyImported(_:for:)` and
    /// `ContentView.repointLoginSet(_:)` do.
    let onImported: (ManagedKey, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var errorMessage: String?
    /// True while the import task runs. It greys the button out
    /// (`isImportDisabled`) for the whole conversion, which is what keeps a
    /// second press from starting a second conversion into a second UUID
    /// destination — the copy and the `ssh-keygen` rewrite are `await`ed
    /// now, so the press is no longer over before the sheet can be pressed
    /// again.
    @State private var isImporting = false
    /// The run in flight, if any. Cancel and every other way out of the
    /// sheet (`onDisappear`) cancel it, so a dismissed sheet adds no key.
    @State private var importTask: Task<Void, Never>?

    init(
        fileURL: URL, store: ManagedKeyStore,
        onImported: @escaping (ManagedKey, Bool) -> Void
    ) {
        self.fileURL = fileURL
        self.store = store
        self.onImported = onImported
        _name = State(initialValue: fileURL.lastPathComponent)
    }

    private var isImportDisabled: Bool {
        isImporting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.import.title", "Import SSH Key")).font(.title3.bold())

            // Fixed while the conversion and the inspection run: the run
            // works from the values it started with (captured below in
            // `performImport()`), and fields that went on accepting edits
            // would show a key the sheet is not importing.
            Group {
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
            }
            .disabled(isImporting)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) {
                    importTask?.cancel()
                    dismiss()
                }
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
        // However the sheet goes away — Cancel, Escape, the parent closing —
        // a run still in flight is cancelled, so a dismissed sheet adds no
        // key. A finished run makes this a no-op.
        .onDisappear { importTask?.cancel() }
    }

    /// Runs on the main actor and hands the work to a task on it: the
    /// conversion (`SSHKeyConverter.copyAsOpenSSH`) AND the inspection
    /// (`SSHKeyImporter.inspect`) below are both `await`ed now, and a
    /// `Button` action cannot be `async`. Nothing leaves the main actor —
    /// each wait is a suspension rather than a blocked thread, so awaiting
    /// them here does not hold the main actor while the tools run.
    ///
    /// `isImporting` closes the door that suspension opens: until both calls
    /// became `async` this ran to completion inside the press, so a second
    /// press could not overlap the first, and nothing could edit the fields
    /// out from under a run in flight. Now both are possible across TWO
    /// suspensions, not one, so every field the run reads is captured into a
    /// `let` — `trimmedName`, `trimmedComment`, `capturedPassphrase` — before
    /// the first `await`, and the fields themselves are disabled
    /// (`.disabled(isImporting)`) for the same window. A passphrase read
    /// live after either await could put a different secret in the Keychain
    /// slot than the one the key was converted and inspected with.
    ///
    /// `importTask` lets Cancel, and every other way out of the sheet
    /// (`onDisappear`), stop a run in flight: a cancellation caught after
    /// both awaits return records nothing and removes the destination file
    /// the conversion wrote.
    @MainActor private func performImport() {
        guard !isImporting else { return }
        isImporting = true
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedPassphrase = passphrase.isEmpty ? nil : passphrase
        importTask = Task { @MainActor in
            defer { isImporting = false }
            // `fileURL` came out of a `fileImporter` picker in the parent sheet,
            // possibly outside this app's own sandbox container — the same
            // access dance `ContentView.handleImportFileSelection` already
            // documents for session imports.
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

            do {
                let newID = UUID()
                let destination = store.keyDirectory.appendingPathComponent(newID.uuidString)
                let key: ManagedKey
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
                    // Copy AND convert in one step: the converter writes the
                    // destination at 0600, rewrites it with `ssh-keygen -p` unless
                    // it is already OpenSSH-format, never opens the source for
                    // writing, and removes the destination itself on any failure
                    // of its own. The inspection below therefore reads the copy,
                    // not the picked file — which is what makes the stored key's
                    // recorded type and fingerprint those of the file macSCP will
                    // actually dial with.
                    try await SSHKeyConverter.copyAsOpenSSH(
                        from: fileURL, to: destination,
                        passphrase: capturedPassphrase)
                    let info = try await SSHKeyImporter.inspect(
                        privateKeyURL: destination,
                        passphrase: capturedPassphrase)
                    // A cancellation that arrived after both awaits returned:
                    // the user has already left the sheet, so the key must
                    // not appear in the list.
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: destination)
                        return
                    }
                    key = ManagedKey(
                        id: newID, name: trimmedName, comment: trimmedComment, type: info.type,
                        fingerprint: info.fingerprint, publicKeyOpenSSH: info.publicKeyOpenSSH,
                        createdAt: Date(), hasPassphrase: capturedPassphrase != nil,
                        fileName: newID.uuidString)
                    try store.add(key)
                } catch {
                    // Anything failing AFTER the copy above (the inspection or
                    // `store.add`) must not leave a key file behind that no
                    // metadata entry claims. The removal is best-effort and safe
                    // to run even if the step that "created" the file never
                    // actually got there (`copyAsOpenSSH` removes its own
                    // destination on every failure of its own, and this covers
                    // the steps after it). No Keychain slot exists to clean up
                    // yet — that write happens below, once the key is
                    // discoverable.
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                var keptPassphrase = true
                if let capturedPassphrase {
                    do {
                        try KeychainSecretStore().savePassword(capturedPassphrase, for: newID)
                    } catch {
                        keptPassphrase = false
                    }
                }
                onImported(key, keptPassphrase)
                dismiss()
            } catch SSHKeyConverter.ConversionError.timedOut {
                // Its own fixed text: `ssh-keygen -p` was stopped at
                // `KeyToolBound.keygen` while rewriting the copy, which says
                // nothing about the key.
                errorMessage = L10n.string(
                    "keys.import.error.conversionTimedOut",
                    "Converting the key took too long and was stopped. The key was not imported.")
            } catch SSHKeyImporter.SSHKeyImportError.timedOut {
                // Its own fixed text: `ssh-keygen` was stopped at
                // `KeyToolBound.keygen`, which says nothing about the key.
                errorMessage = L10n.string(
                    "keys.import.error.timedOut",
                    "Reading the key took too long and was stopped. The key was not imported.")
            } catch {
                // Fixed message only (same reasoning as `GenerateKeySheet`):
                // never surface the underlying error, which could otherwise leak
                // filesystem paths or `ssh-keygen` diagnostics.
                errorMessage = L10n.string("keys.import.error", "Couldn't import the key.")
            }
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

/// "Correct the stored passphrase" (2026-09-24): one field, and the key FILE
/// is never opened for writing.
///
/// It exists because a managed key's stored passphrase wins over one typed for
/// a jump hop (since 2026-09-20), which left a wrong or missing stored value
/// with nowhere to be corrected — the typed one was saved and then never
/// consulted. The typed value is proved against the key file
/// (`ssh-keygen -y`) before it replaces anything, so pressing Save with a
/// guess cannot destroy a passphrase that was right.
///
/// The fields, the latch and the run live in `CorrectKeyPassphraseForm`
/// (Core), where `KeyPassphraseFormsTests` can edit the field mid-run and
/// cancel one — the same split `GenerateKeySheet` uses, and for the same
/// reason: `ssh-keygen` is awaited, so the field stays live while it runs.
private struct CorrectKeyPassphraseSheet: View {
    let key: ManagedKey
    let store: ManagedKeyStore
    let onCorrected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form = CorrectKeyPassphraseForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.passphrase.correct.title", "Correct the Stored Passphrase"))
                .font(.title3.bold())
            Text(L10n.string(
                "keys.passphrase.correct.explain",
                "Type the passphrase that opens this key. macSCP checks it before saving it, and the key file itself is not changed."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Fixed while `ssh-keygen` runs: the run works from the value it
            // started with, and a field that went on accepting edits would
            // show a passphrase the sheet is not checking.
            let passphraseLabel = L10n.string("keys.passphrase.field", "Passphrase")
            KeyFieldRow(label: passphraseLabel) {
                SecureField(passphraseLabel, text: $form.passphrase, prompt: Text(verbatim: ""))
            }
            .disabled(form.isRunning)

            if let message = form.failure.map(Self.message(for:)) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) {
                    form.cancel()
                    dismiss()
                }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) { save() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .textFieldStyle(.roundedBorder)
        // However the sheet goes away — Cancel, Escape, the parent closing —
        // a run still in flight is cancelled. Nothing has been written at
        // that point either way; see the form's own `cancel`.
        .onDisappear { form.cancel() }
    }

    @MainActor private func save() {
        guard let task = form.start(key: key, store: store, secrets: KeychainSecretStore())
        else { return }
        Task { @MainActor in
            if case .stored = await task.value {
                onCorrected()
                dismiss()
            }
        }
    }

    /// A fixed message per failure — never the underlying error (same
    /// reasoning as `GenerateKeySheet.message(for:)`).
    private static func message(for failure: CorrectKeyPassphraseForm.Failure) -> String {
        switch failure {
        case .doesNotOpenTheKey:
            return L10n.string(
                "keys.passphrase.error.doesNotOpen",
                "That passphrase doesn't open this key. Nothing was saved.")
        case .notManaged:
            return L10n.string(
                "keys.passphrase.error.notManaged",
                "This key's file isn't in macSCP's own key folder, so macSCP won't touch it.")
        case .keyFileMissing:
            return L10n.string(
                "keys.passphrase.error.keyFileMissing",
                "macSCP can't find this key's file. It may have been moved or deleted.")
        case .keyIsNotEncrypted:
            return L10n.string(
                "keys.passphrase.error.notEncrypted",
                "This key file isn't protected by a passphrase, so there is none to remember. Use \u{201C}Change the key's passphrase\u{2026}\u{201D} to give it one.")
        case .notStored:
            return L10n.string(
                "keys.passphrase.correct.error.notStored",
                "The passphrase is right, but it couldn't be saved. The key file was not changed \u{2014} try again.")
        // These two say "nothing was changed" truthfully HERE and would not in
        // the change sheet, which is why that sheet has keys of its own: this
        // action never opens the key file for writing at all.
        case .timedOut:
            return L10n.string(
                "keys.passphrase.correct.error.timedOut",
                "Checking the key took too long and was stopped. Nothing was changed.")
        case .failed:
            return L10n.string(
                "keys.passphrase.correct.error.failed",
                "Something went wrong. Nothing was changed.")
        }
    }
}

/// "Change the key's passphrase" (2026-09-24): the current passphrase, a new
/// one and its confirmation, and `ssh-keygen -p` over the key file itself.
///
/// The sibling sheet above changes nothing on disk; this one is irreversible,
/// which is why the two are separate actions rather than one sheet with a
/// switch. The current passphrase is proved first, so a mistyped one is
/// reported as itself instead of as a broken run, and the stored value follows
/// the file in the same operation — including the case where it cannot, which
/// `SSHKeysSheet.reportPassphraseChange(_:)` says out loud.
///
/// The fields, the latch and the run live in `ChangeKeyPassphraseForm` (Core).
private struct ChangeKeyPassphraseSheet: View {
    let key: ManagedKey
    let store: ManagedKeyStore
    /// Called with how the run ended, not merely that it ended: the parent
    /// has to tell `.changed` from `.changedButNotStored`, and only the
    /// parent survives this sheet's dismissal to say so.
    let onChanged: (ChangeKeyPassphraseForm.Outcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form = ChangeKeyPassphraseForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("keys.passphrase.change.title", "Change the Key's Passphrase"))
                .font(.title3.bold())
            Text(L10n.string(
                "keys.passphrase.change.explain",
                "This rewrites the key file. Afterwards only the new passphrase opens it, and macSCP remembers the new one."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Fixed while `ssh-keygen` runs, for the reason the sibling sheet
            // above gives — with more at stake here, since the run rewrites
            // the key file with the values it started from.
            Group {
                let oldLabel = L10n.string("keys.passphrase.change.old", "Current passphrase")
                KeyFieldRow(label: oldLabel) {
                    SecureField(oldLabel, text: $form.oldPassphrase, prompt: Text(verbatim: ""))
                }
                let newLabel = L10n.string("keys.passphrase.change.new", "New passphrase")
                KeyFieldRow(label: newLabel) {
                    SecureField(newLabel, text: $form.newPassphrase, prompt: Text(verbatim: ""))
                }
                let confirmLabel = L10n.string(
                    "keys.passphrase.change.confirm", "Confirm new passphrase")
                KeyFieldRow(label: confirmLabel) {
                    SecureField(confirmLabel, text: $form.newPassphraseConfirm, prompt: Text(verbatim: ""))
                }
            }
            .disabled(form.isRunning)

            if form.passphrasesMismatch && !form.newPassphraseConfirm.isEmpty {
                Text(L10n.string("keys.generate.passphrase.mismatch", "Passphrases don't match."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let message = form.failure.map(Self.message(for:)) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) {
                    form.cancel()
                    dismiss()
                }
                    .buttonStyle(.polished)
                Button(L10n.string("keys.passphrase.change.submit", "Change")) { change() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .textFieldStyle(.roundedBorder)
        // Safe at every point, which is why it is unconditional: a cancelled
        // rewrite is rolled back before the error leaves the tool, so however
        // the sheet goes away — Cancel, Escape, the parent closing — the key
        // file is the one the user still has the current passphrase for
        // (`ChangeKeyPassphraseForm`, "What a cancellation means").
        .onDisappear { form.cancel() }
    }

    @MainActor private func change() {
        guard let task = form.start(key: key, store: store, secrets: KeychainSecretStore())
        else { return }
        Task { @MainActor in
            let outcome = await task.value
            // Both of these mean the key file was rewritten, which is why
            // they leave the sheet: only a `.failed` or a `.cancelled` is
            // something to try again here.
            if outcome == .changed || outcome == .changedButNotStored {
                onChanged(outcome)
                dismiss()
            }
        }
    }

    /// A fixed message per failure — never the underlying error.
    private static func message(for failure: ChangeKeyPassphraseForm.Failure) -> String {
        switch failure {
        case .notManaged:
            return L10n.string(
                "keys.passphrase.error.notManaged",
                "This key's file isn't in macSCP's own key folder, so macSCP won't touch it.")
        case .keyFileMissing:
            return L10n.string(
                "keys.passphrase.error.keyFileMissing",
                "macSCP can't find this key's file. It may have been moved or deleted.")
        case .oldDoesNotOpenTheKey:
            return L10n.string(
                "keys.passphrase.change.error.oldDoesNotOpen",
                "The current passphrase doesn't open this key. Nothing was changed.")
        // NOT the correction sheet's two: either of these can arrive from the
        // `ssh-keygen -p` run and not only from the check before it, and a
        // stopped or failed rewrite is exactly the case where macSCP must not
        // promise that the key file is untouched. It puts the file back from
        // the copy it makes first, and that restore is the one step it cannot
        // guarantee, so the wording sends the user to look rather than telling
        // them not to.
        case .timedOut:
            return L10n.string(
                "keys.passphrase.change.error.timedOut",
                "The key tool took too long and was stopped. Check that the current passphrase still opens this key before trying again.")
        case .failed:
            return L10n.string(
                "keys.passphrase.change.error.failed",
                "Something went wrong. Check that the current passphrase still opens this key before trying again.")
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
