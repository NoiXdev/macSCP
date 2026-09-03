import Foundation
import macSCPCore

/// Text mappings for the session import/export path. Lifted out of
/// `ContentView` (M29-P2-Entkernung/T6) so the mapping is held by tests
/// rather than by reading.
enum ImportFeedbackText {
    /// The two numbers an import from another program has to report that an
    /// import from a file does not (Cyberduck import, 2026-09-03).
    ///
    /// `updated` is MEASURED, not promised: it is what the plan actually
    /// overwrote, so an update whose record vanished between the preview and
    /// the import — it fell back to a fresh session — is not counted here.
    ///
    /// `secretsNotRead` counts the keychain items that were asked for and
    /// not given: absent, refused, or a prompt the user cancelled. Only
    /// `CyberduckSecretLookup.notFound` — a bookmark the reader never queried
    /// because Cyberduck could hold no item for it is not a failure and is
    /// not here. A COUNT, like every other line in this function — never a
    /// name, and never a value.
    ///
    /// Both numbers produce a line only when they are above zero, the shape
    /// every other conditional line here follows: "Existing sessions updated:
    /// 0" on a clean run reads as a report about something that went wrong.
    struct ExternalImportOutcome: Equatable {
        var updated: Int
        var secretsNotRead: Int
    }

    /// Shared formatter for non-typed read/decode failures on the import
    /// path — single source for the message so the three call sites cannot
    /// drift apart (T3 review).
    static func readErrorMessage(_ error: Error) -> String {
        String(format: L10n.string(
            "import.error.readFailed %@", "Could not read the file: %@"),
            String(describing: error))
    }

    /// Maps the two non-password `SessionExportError` cases the top-level
    /// alert can show (spec M9a §3.5). `.passwordRequired` and
    /// `.wrongPasswordOrCorrupted` are only ever thrown from a `decode` call
    /// that already supplied a password (handled inline by the password
    /// sheet instead), so they fall back to the same generic text here —
    /// defensive only, never actually reached.
    static func importErrorText(for error: SessionExportError) -> String {
        switch error {
        case .notAnExportFile:
            return L10n.string("import.error.notExport", "Not a macSCP sessions file.")
        case .unsupportedVersion:
            return L10n.string(
                "import.error.newerVersion",
                "This file was created by a newer version of macSCP.")
        case .passwordRequired, .wrongPasswordOrCorrupted:
            return L10n.string("import.password.wrong", "Wrong password, or the file is corrupted.")
        case .randomnessUnavailable:
            // Only ever thrown from `encode`, never from `decode` — this
            // import-path mapper never actually reaches it. Kept for
            // exhaustiveness now that the enum has a fourth case.
            return L10n.string("import.error.notExport", "Not a macSCP sessions file.")
        }
    }

    /// Assembles the multi-line import result alert body (spec M9a §3.4):
    /// the base imported/skipped/passwords-imported line, the M19 lines for
    /// what the user decided about duplicates (replaced/renamed) and for
    /// secrets a replace removed, plus optional lines for password-save
    /// failures, store-write failures, the M27 count of entries the planner
    /// rejected outright as unusable, the count of folders whose broken
    /// nesting the import straightened (D1), and an unencrypted-secrets
    /// notice when the file wasn't itself encrypted.
    /// `external` is set only for an import read out of another program's
    /// bookmarks; it adds the update count and, when the user asked for
    /// secrets, the ones the keychain did not hand over.
    static func importResultText(
        _ result: SessionListViewModel.SessionImportResult, plan: SessionImportPlan,
        includesSecrets: Bool, encrypted: Bool,
        external: ExternalImportOutcome? = nil
    ) -> String {
        var lines = [String(format: L10n.string(
            "import.result.body %lld %lld %lld",
            "%lld imported, %lld skipped as duplicates, %lld passwords imported"),
            result.imported, result.skipped, result.passwordsImported)]
        if !plan.replaced.isEmpty || !plan.renamed.isEmpty {
            lines.append(String(format: L10n.string(
                "import.result.resolved %lld %lld", "%lld replaced, %lld renamed"),
                plan.replaced.count, plan.renamed.count))
        }
        // A replace from a secret-free file drops the stored password rather
        // than leaving the old one bound (see `applyImport`) — the user has to
        // be told, or the session silently stops connecting.
        if result.secretsRemoved > 0 {
            lines.append(String(format: L10n.string(
                "import.result.secretsRemoved %lld",
                "Stored passwords removed because the file had none: %lld"),
                result.secretsRemoved))
        }
        // The other half of that rule: a removal the Keychain refused leaves
        // the OLD credential live under the reused id. Silence there would be
        // the worst case of all — a session connecting with a password the
        // user believes they just replaced.
        if result.secretRemovalFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.secretsRemoveFailed %lld",
                "Stored passwords that could not be removed: %lld"),
                result.secretRemovalFailures))
        }
        if result.passwordFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.passwordFailures %lld", "Passwords that could not be saved: %lld"),
                result.passwordFailures))
        }
        if result.storeFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.storeFailures %lld", "Not saved due to an error: %lld"),
                result.storeFailures))
        }
        // Entries the planner refused: the file described a connection with
        // nothing to dial, which the store would discard on its next read. A
        // COUNT only — a rejected entry can carry a password, and neither it
        // nor the entry's contents belong in an alert.
        if !plan.rejected.isEmpty {
            lines.append(String(format: L10n.string(
                "import.result.rejected %lld",
                "Not imported because the entry was incomplete: %lld"),
                plan.rejected.count))
        }
        // Folders whose place in the file could not be kept: the parent was
        // missing, or the chain closed a ring, so they arrived at the top
        // level. Nothing was lost — the folders and their sessions all
        // imported — which is why this reads as a note rather than a failure.
        // A COUNT, like the rejected line above, for the same reason: a
        // folder name is the user's own text and does not belong in an alert.
        if !plan.liftedGroups.isEmpty {
            lines.append(String(format: L10n.string(
                "import.result.liftedGroups %lld",
                "Folders moved to the top level because the file's nesting was broken: %lld"),
                plan.liftedGroups.count))
        }
        if includesSecrets && !encrypted && external == nil {
            lines.append(L10n.string(
                "import.result.plaintextNotice", "The file contained unencrypted passwords."))
        }
        // An external import has no file, so the plaintext notice above is
        // suppressed for it: there was nothing on disk to be unencrypted.
        // What it does have to say is how many records it overwrote, and how
        // many secrets the keychain kept to itself.
        // Both lines follow the shape of every other conditional line above:
        // a count of zero is not news, and a line reading "…: 0" on a clean
        // run reads as a failure report.
        if let external {
            if external.updated > 0 {
                lines.append(String(format: L10n.string(
                    "import.result.updated %lld", "Existing sessions updated: %lld"),
                    external.updated))
            }
            if external.secretsNotRead > 0 {
                lines.append(String(format: L10n.string(
                    "import.result.secretsNotRead %lld",
                    "Passwords that could not be read from the keychain: %lld"),
                    external.secretsNotRead))
            }
        }
        return lines.joined(separator: "\n")
    }
}
