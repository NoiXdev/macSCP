import AppKit
import SwiftUI
import macSCPCore

/// Session export/import wiring split out of `ContentView.swift`: building
/// and encoding the export payload, the `fileExporter`/`fileImporter`
/// completion handlers, decoding an import file (with or without a
/// password), and planning/applying a decoded payload.
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    // MARK: - Session export/import (M9a/T3)

    /// Builds the export payload, encodes it, and arms `fileExporter` — the
    /// sheet's Export button calls this and stays open (showing the
    /// returned message) on failure, or dismisses itself on `nil` (spec
    /// M9a §3.3). Encoding failure is rare (random salt generation, AES-GCM
    /// sealing) but not impossible, so it is reported inline rather than
    /// asserted away.
    func performExport(
        scope: SessionListViewModel.ExportScope, options: SessionExportOptions
    ) -> String? {
        let (payload, missingPasswordCount) = sessionListViewModel.exportPayload(
            for: scope, includeGroups: options.includeGroups, includePasswords: options.includePasswords)
        do {
            let data = try SessionExportCodec.encode(payload, password: options.password)
            exportDocument = SessionExportDocument(data: data)
            // Only meaningful when passwords were actually requested —
            // `exportPayload` only counts missing entries in that case.
            exportMissingPasswordCount = options.includePasswords ? missingPasswordCount : 0
            showExportFileExporter = true
            return nil
        } catch {
            return String(format: L10n.string(
                "export.error.encodeFailed %@", "Could not prepare the export: %@"),
                String(describing: error))
        }
    }

    /// `fileExporter` completion: on success, surfaces the "exported without
    /// password" notice when applicable (spec M9a §3.3); on failure, a
    /// generic localized write-error alert.
    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if exportMissingPasswordCount > 0 {
                showExportMissingPasswordAlert = true
            }
        case .failure(let error):
            exportErrorMessage = String(format: L10n.string(
                "export.error.writeFailed %@", "Could not write the export file: %@"),
                String(describing: error))
        }
        // Clear the encoded (possibly plaintext-password-bearing) export
        // bytes from view state once the panel has resolved, whether it
        // succeeded, failed, or the user cancelled the save (M9a final
        // review, Finding 3) — nothing should keep them around indefinitely.
        exportDocument = nil
    }

    /// `fileImporter` completion: reads the chosen file with security-scoped
    /// access (the URL comes from an NSOpenPanel outside this app's own
    /// sandbox container) and probes whether it's encrypted before deciding
    /// whether the password sheet is needed.
    func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = ImportFeedbackText.readErrorMessage(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if try SessionExportCodec.probe(data) {
                    importFileData = data
                    showImportPasswordSheet = true
                } else {
                    // Unencrypted: decode right here (no sheet is up), then
                    // plan/apply — the planner is async since M19, and the
                    // file bytes are already in memory, so the security-scoped
                    // access this method holds need not outlive the task.
                    if case .ready(let pending) = decodeImport(data: data, password: nil) {
                        Task { await applyImport(pending) }
                    }
                }
            } catch let error as SessionExportError {
                importErrorMessage = ImportFeedbackText.importErrorText(for: error)
            } catch {
                importErrorMessage = ImportFeedbackText.readErrorMessage(error)
            }
        }
    }

    /// What a decode attempt produced: something to plan, something the user
    /// can fix by retyping the password, or a failure already surfaced in the
    /// top-level alert.
    enum ImportDecodeOutcome {
        case ready(PendingSessionImport)
        /// Keep the password sheet open and show this message.
        case retry(String)
        case failed
    }

    /// Decode step of an import (spec M9a §3.4). Planning deliberately does
    /// NOT happen here — see `pendingImport`'s doc comment.
    func decodeImport(data: Data, password: String?) -> ImportDecodeOutcome {
        do {
            return .ready(PendingSessionImport(
                payload: try SessionExportCodec.decode(data, password: password),
                wasEncrypted: password != nil))
        } catch SessionExportError.wrongPasswordOrCorrupted {
            return .retry(
                L10n.string("import.password.wrong", "Wrong password, or the file is corrupted."))
        } catch let error as SessionExportError {
            importErrorMessage = ImportFeedbackText.importErrorText(for: error)
            return .failed
        } catch {
            importErrorMessage = ImportFeedbackText.readErrorMessage(error)
            return .failed
        }
    }

    /// Plan → apply for an already-decoded payload. No auto-connect afterwards
    /// (spec M9a §3.5) — only the store/keychain are touched.
    ///
    /// Duplicates are resolved through the SHARED arbiter (M19), whose decider
    /// is `importConflictBridge` and therefore the same `ImportConflictSheet`
    /// the login-set import shows. A cancelled run reports NOTHING: no alert
    /// at all, rather than an "import finished" full of zeros for an import
    /// the user explicitly called off.
    ///
    /// `externalSecretsNotRead` is `nil` for the file import above and a
    /// COUNT — possibly zero — for an import read out of another program's
    /// bookmarks. Non-nil is what makes the result alert grow its two extra
    /// lines: the number of records this run overwrote, and the number of
    /// keychain items it asked for and did not get.
    func applyImport(
        _ pending: PendingSessionImport, externalSecretsNotRead: Int? = nil
    ) async {
        let bridge = importConflictBridge
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let plan = await SessionImportPlanner.plan(
            existing: sessionListViewModel.sessions,
            existingGroups: sessionListViewModel.groups,
            incoming: pending.payload,
            arbiter: arbiter)
        importFileData = nil
        guard !plan.cancelled else { return }
        let result = sessionListViewModel.applyImport(plan)
        importResultMessage = ImportFeedbackText.importResultText(
            result, plan: plan, includesSecrets: pending.payload.includesSecrets,
            encrypted: pending.wasEncrypted,
            external: externalSecretsNotRead.map { notRead in
                ImportFeedbackText.ExternalImportOutcome(
                    // Measured off the plan rather than off the payload: an
                    // entry whose record was deleted between the preview and
                    // the import falls back to a fresh session, and claiming
                    // it as an update would be a number about a wish.
                    updated: plan.sessionsToImport.filter(\.replacesExisting).count,
                    secretsNotRead: notRead)
            })
        showImportResultAlert = true
    }

    // MARK: - Import from another program (Cyberduck import, 2026-09-03)

    /// The Sessions menu's "From Cyberduck…". Reads the folder HERE, before
    /// anything is presented (design §4): the sheet then opens on a preview
    /// that already exists, and a source whose folder is not where it should
    /// be raises the picker instead of an error inside a sheet.
    func beginExternalImport() {
        let source = CyberduckBookmarkSource()
        guard let folder = source.locate(home: FileManager.default.homeDirectoryForCurrentUser)
        else {
            showExternalImportFolderPicker = true
            return
        }
        // The default folder is inside another app's Group Container, which
        // this process reaches by ordinary file permissions — there is no
        // security-scoped URL to open for it, unlike a folder the user picks.
        presentExternalImport(folder: folder, securityScoped: false)
    }

    /// Folder-picker completion for the case above: the user pointed at the
    /// bookmark directory themselves.
    func handleExternalImportFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = ImportFeedbackText.readErrorMessage(error)
        case .success(let urls):
            guard let folder = urls.first else { return }
            presentExternalImport(folder: folder, securityScoped: true)
        }
    }

    /// Builds the preview and hands it to the sheet. The whole read happens
    /// inside the security-scoped access, so nothing the sheet does later
    /// depends on the access still being held.
    private func presentExternalImport(folder: URL, securityScoped: Bool) {
        let didAccess = securityScoped && folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        let model = ImportFromSourceViewModel(
            sessions: sessionListViewModel.sessions, groups: sessionListViewModel.groups)
        model.load(source: CyberduckBookmarkSource(), folder: folder)
        externalImport = model
    }

    /// Import pressed in the preview sheet: read the secrets the user asked
    /// for, then hand the payload to the SAME `applyImport` a file import
    /// uses (design §2 — nothing about the store's write path is duplicated
    /// here).
    ///
    /// The keychain is asked once per selected entry, and only behind the
    /// switch: each query may raise the macOS consent prompt, which belongs
    /// to this click and to no other moment. A refusal or a missing item
    /// leaves the entry secret-free and is counted — never logged, never
    /// named, and never put in a message beside the session it belongs to.
    func applyExternalImport(_ model: ImportFromSourceViewModel) async {
        var payload = model.payload()
        var secretsNotRead = 0
        if model.switches.takeSecrets {
            let reader = CyberduckSecretReader()
            let bookmarks = model.selectedBookmarksByID
            for index in payload.sessions.indices {
                guard let importID = payload.sessions[index].importID,
                      let bookmark = bookmarks[importID]
                else { continue }
                guard let secret = await reader.secret(for: bookmark) else {
                    secretsNotRead += 1
                    continue
                }
                // Which slot the secret belongs in is the same decision
                // `SessionImportPlanner` makes on the way back out: an S3
                // session's credential is its secret access key, everything
                // else's is a password.
                if payload.sessions[index].kind == .s3 {
                    payload.sessions[index].s3SecretAccessKey = secret
                } else {
                    payload.sessions[index].password = secret
                }
            }
        }
        await applyImport(
            PendingSessionImport(payload: payload, wasEncrypted: false),
            externalSecretsNotRead: secretsNotRead)
    }
}
