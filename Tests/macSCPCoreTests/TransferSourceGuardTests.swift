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
}
