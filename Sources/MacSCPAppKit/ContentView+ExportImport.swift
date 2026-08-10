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
    func applyImport(_ pending: PendingSessionImport) async {
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
            encrypted: pending.wasEncrypted)
        showImportResultAlert = true
    }
}
