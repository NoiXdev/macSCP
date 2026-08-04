import Foundation
import Testing
@testable import macSCPCore

/// `TransferSourceGuard` is CLI groundwork (M20 Task 10): `TransferPlan`
/// plans exactly one file job and never expands a directory source, so
/// something upstream of it must refuse a directory outright instead of
/// letting it through as a bogus single-file job. These tests pin that this
/// inherited-but-previously-untested guard actually does refuse.
@Suite("TransferSourceGuard")
struct TransferSourceGuardTests {
    @Test func refusesADirectorySource() {
        let directory = RemoteFileItem(name: "logs", path: "/var/logs", kind: .directory)
        #expect(throws: TransferSourceError.isDirectory(path: "/var/logs")) {
            try TransferSourceGuard.checkNotDirectory(directory)
        }
    }

    @Test func acceptsAPlainFileSource() throws {
        let file = RemoteFileItem(name: "app.log", path: "/var/logs/app.log", kind: .file)
        try TransferSourceGuard.checkNotDirectory(file)
    }

    /// A symlink is not itself a directory (`RemoteFileItem.isDirectory` is
    /// `kind == .directory` only) — the guard must not conflate the two. If
    /// the symlink's TARGET is a directory, the underlying transfer call
    /// will fail on its own terms; this guard only rejects directories it
    /// can see directly.
    @Test func doesNotTreatASymlinkAsADirectory() throws {
        let link = RemoteFileItem(name: "current", path: "/var/logs/current", kind: .symlink)
        try TransferSourceGuard.checkNotDirectory(link)
    }

    // MARK: - checkDeletable / session-root guard (M20 final-review Finding A)

    /// `SessionReference.parse` maps an empty path to `/` — so `rm -r prod:`
    /// (a truncated or unquoted argument, no path after the colon) reaches
    /// `deleteTree(at: "/")` with nothing else standing in the way. `-r`
    /// alone must not be sufficient to wipe a session root; `allowRoot` is
    /// the deliberate, hard-to-typo escape hatch (wired to `rm
    /// --allow-root-delete` in the CLI).
    @Test func refusesARecursiveDeleteOfTheSessionRoot() {
        let root = RemoteFileItem(name: "/", path: "/", kind: .directory)
        #expect(throws: DeleteSourceError.isSessionRoot(path: "/")) {
            try TransferSourceGuard.checkDeletable(root, recursive: true, allowRoot: false)
        }
    }

    /// `allowRoot: true` is the explicit escape hatch — it must actually let
    /// the recursive root delete through, or it isn't an escape hatch.
    @Test func allowsARecursiveDeleteOfTheSessionRootWhenExplicitlyAllowed() throws {
        let root = RemoteFileItem(name: "/", path: "/", kind: .directory)
        try TransferSourceGuard.checkDeletable(root, recursive: true, allowRoot: true)
    }

    /// A non-root path is a deliberate, named target — not the "empty
    /// argument silently became root" trap this guard exists for — so it is
    /// never caught by the root check, `allowRoot` or not.
    @Test func allowsARecursiveDeleteOfANonRootDirectoryWithoutTheEscapeHatch() throws {
        let directory = RemoteFileItem(name: "logs", path: "/var/logs", kind: .directory)
        try TransferSourceGuard.checkDeletable(directory, recursive: true, allowRoot: false)
    }

    /// `allowRoot` defaults to `false` — the escape hatch must be opt-in, not
    /// opt-out, so a call site that forgets the parameter entirely (like
    /// every pre-existing call in this file) still gets the safe behavior.
    @Test func allowRootDefaultsToFalse() {
        let root = RemoteFileItem(name: "/", path: "/", kind: .directory)
        #expect(throws: DeleteSourceError.isSessionRoot(path: "/")) {
            try TransferSourceGuard.checkDeletable(root, recursive: true)
        }
    }

    /// A non-recursive delete of the root is already refused as a plain
    /// directory (`.isDirectory`), before the root check ever runs — the two
    /// checks are not redundant, but `.isDirectory` fires first when
    /// `recursive` is false, root or not.
    @Test func nonRecursiveDeleteOfRootFailsAsAPlainDirectoryNotAsRoot() {
        let root = RemoteFileItem(name: "/", path: "/", kind: .directory)
        #expect(throws: DeleteSourceError.isDirectory(path: "/")) {
            try TransferSourceGuard.checkDeletable(root, recursive: false, allowRoot: true)
        }
    }
}
