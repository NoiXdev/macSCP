import Foundation
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// Custom exported type for `.macscpsessions` files (M9a/T3). Declared
/// dynamically via `exportedAs` so `swift run` development builds work
/// without an `Info.plist` (there is no bundle to read one from); the
/// packaged `.app` ALSO declares this identifier in `Info.plist`
/// (`UTExportedTypeDeclarations`, see `scripts/package-app`) so Launch
/// Services associates the `.macscpsessions` extension with it for
/// double-click/Quick Look outside this app's own file panels. The ad hoc
/// declaration here has no filename-extension tag of its own — the actual
/// extension is carried by `defaultFilename` in the `fileExporter` call
/// below, which is sufficient for this app's own save/open panels.
extension UTType {
    static let macscpSessions = UTType(exportedAs: "dev.noix.macscp.sessions", conformingTo: .json)
}

/// Write-only `FileDocument` wrapper around already-encoded export bytes.
/// `SessionExportCodec.encode` has already run by the time `ContentView`
/// constructs this — it only carries the result to `fileExporter`. Reading
/// is never exercised: import goes through `SessionExportCodec.decode`
/// directly on `Data` read from the chosen URL, never through this type's
/// read path — hence the empty `readableContentTypes` and the throwing
/// `init(configuration:)`.
struct SessionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.macscpSessions] }

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

/// Finalized choices from `SessionExportSheet`, handed to `ContentView` to
/// actually run `exportPayload` + `SessionExportCodec.encode` (spec M9a
/// §3.3). `password` is `nil` for an unencrypted export.
struct SessionExportOptions {
    var includeGroups: Bool
    var includePasswords: Bool
    var password: String?
}

/// Export sheet — one view for all three scopes (single session, group,
/// all), driven by the sidebar's "Export…"/"Export Group…"/"Export All…"
/// context-menu entries (spec M9a §3.2). NameEntrySheet-styled: title,
/// fields, `isWorking`, `.polished`/`.polishedProminent` buttons.
struct SessionExportSheet: View {
    let viewModel: SessionListViewModel
    let scope: SessionListViewModel.ExportScope
    /// Runs the actual export (payload build + encode + arms `ContentView`'s
    /// `fileExporter`) in `ContentView`. Returns an error message to show
    /// inline and keep the sheet open, or `nil` on success — `ContentView`
    /// has already taken over by the time this returns, so the sheet just
    /// dismisses itself (mirrors `NameEntrySheet`'s `onConfirm` contract).
    let onExport: (SessionExportOptions) -> String?

    @Environment(\.dismiss) private var dismiss

    @State private var includeGroups = true
    @State private var includePasswords = false
    @State private var encryptionMode: EncryptionMode = .encrypted
    @State private var password = ""
    @State private var passwordRepeat = ""
    /// Two-stage plaintext confirm (spec M9a §3.2): the primary button's
    /// first click, while unencrypted+passwords are both on, only ARMS the
    /// destructive re-label ("Export Anyway…"); the second click actually
    /// exports. Any option change disarms it again — the destructive button
    /// must never survive a change of mind about what it's about to export.
    @State private var isConfirmingPlaintext = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    enum EncryptionMode: String, CaseIterable {
        case encrypted
        case unencrypted
    }

    private var scopedCount: Int {
        switch scope {
        case .single: return 1
        case .group(let group): return viewModel.sessions(inGroup: group.id).count
        case .all: return viewModel.sessions.count
        }
    }

    /// Hidden for a single session with no group — there is nothing for the
    /// toggle to include (spec M9a §3.2).
    private var showsGroupToggle: Bool {
        if case .single(let session) = scope { return session.groupID != nil }
        return true
    }

    private var showsPlaintextWarning: Bool {
        encryptionMode == .unencrypted && includePasswords
    }

    private var passwordsMatchAndPresent: Bool {
        !password.isEmpty && password == passwordRepeat
    }

    private var canExport: Bool {
        guard scopedCount >= 1 else { return false }
        if encryptionMode == .encrypted { return passwordsMatchAndPresent }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("export.sheet.title", "Export Sessions")).font(.headline)
            Text(String(
                format: L10n.string("export.summary %lld", "%lld connections"), scopedCount))
                .foregroundStyle(.secondary)

            if showsGroupToggle {
                Toggle(
                    L10n.string("export.includeGroups", "Include group assignment"),
                    isOn: $includeGroups
                )
                .disabled(isWorking)
                .onChange(of: includeGroups) { _, _ in isConfirmingPlaintext = false }
            }
            Toggle(L10n.string("export.includePasswords", "Include passwords"), isOn: $includePasswords)
                .disabled(isWorking)
                .onChange(of: includePasswords) { _, _ in isConfirmingPlaintext = false }

            Picker("", selection: $encryptionMode) {
                Text(L10n.string("export.encrypted", "Encrypted")).tag(EncryptionMode.encrypted)
                Text(L10n.string("export.unencrypted", "Unencrypted")).tag(EncryptionMode.unencrypted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // labelsHidden strips the VoiceOver label too — restore it
            // explicitly (T3 review).
            .accessibilityLabel(L10n.string("export.encryptionLabel", "Encryption"))
            .disabled(isWorking)
            .onChange(of: encryptionMode) { _, _ in isConfirmingPlaintext = false }

            if encryptionMode == .encrypted {
                SecureField(L10n.string("export.password", "Password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                SecureField(L10n.string("export.passwordRepeat", "Repeat password"), text: $passwordRepeat)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                Text(L10n.string(
                    "export.passwordHint",
                    "A long password makes the export harder to crack if the file is intercepted."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showsPlaintextWarning {
                Text(L10n.string(
                    "export.plaintextWarning",
                    "Passwords will be stored in plain text in this file. "
                        + "Anyone who obtains it can read them."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(.polished)
                    .disabled(isWorking)
                if showsPlaintextWarning && isConfirmingPlaintext {
                    Button(L10n.string("export.confirmAnyway", "Export Anyway…"), role: .destructive) {
                        runExport()
                    }
                    .buttonStyle(.polishedProminent)
                    .disabled(isWorking || !canExport)
                } else {
                    Button(L10n.string("export.action", "Export…")) {
                        if showsPlaintextWarning {
                            isConfirmingPlaintext = true
                        } else {
                            runExport()
                        }
                    }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !canExport)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private func runExport() {
        guard !isWorking else { return }
        isWorking = true
        let options = SessionExportOptions(
            includeGroups: includeGroups,
            includePasswords: includePasswords,
            password: encryptionMode == .encrypted ? password : nil)
        let error = onExport(options)
        isWorking = false
        if let error {
            errorMessage = error
            isConfirmingPlaintext = false
        } else {
            dismiss()
        }
    }
}

/// Password prompt shown when `SessionExportCodec.probe` reports the chosen
/// import file is encrypted (spec M9a §3.4). Any number of attempts are
/// allowed; Cancel aborts the whole import.
struct ImportPasswordSheet: View {
    /// Attempts `SessionExportCodec.decode` + the planner + `applyImport`
    /// with the given password. Returns an inline error message (stays open)
    /// or `nil` (dismiss — `ContentView` has already shown the result alert).
    let onSubmit: (String) async -> String?
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("import.password.title", "Password Required")).font(.headline)
            SecureField(L10n.string("export.password", "Password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .disabled(isWorking)
                .onSubmit { submit() }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.polished)
                .disabled(isWorking)
                Button(L10n.string("import.password.unlock", "Unlock")) { submit() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || password.isEmpty)
            }
        }
        .padding(20)
    }

    private func submit() {
        guard !isWorking, !password.isEmpty else { return }
        isWorking = true
        let candidate = password
        // Decoding and planning are async since M19 (the planner can ask
        // about duplicates), so the sheet stays responsive and `isWorking`
        // actually covers the work instead of flipping within one turn.
        Task {
            let error = await onSubmit(candidate)
            isWorking = false
            if let error {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }
}
