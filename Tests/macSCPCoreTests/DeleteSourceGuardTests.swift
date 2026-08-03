import Foundation
import Testing
@testable import macSCPCore

/// `TransferSourceGuard.checkDeletable` is the CLI's `rm` groundwork (M20
/// Task 11): recursive deletion via `deleteTree` must be opt-in, so
/// something upstream of the actual delete call must refuse a directory
/// target when `--recursive` was not passed, with a clear message instead of
/// whatever raw protocol error the backend would throw. These tests pin
/// that refusal.
@Suite("TransferSourceGuard.checkDeletable")
struct DeleteSourceGuardTests {
    @Test func refusesADirectoryWithoutRecursive() {
        let directory = RemoteFileItem(name: "logs", path: "/var/logs", kind: .directory)
        #expect(throws: DeleteSourceError.isDirectory(path: "/var/logs")) {
            try TransferSourceGuard.checkDeletable(directory, recursive: false)
        }
    }

    @Test func acceptsADirectoryWithRecursive() throws {
        let directory = RemoteFileItem(name: "logs", path: "/var/logs", kind: .directory)
        try TransferSourceGuard.checkDeletable(directory, recursive: true)
    }

    @Test func acceptsAPlainFileWithoutRecursive() throws {
        let file = RemoteFileItem(name: "app.log", path: "/var/logs/app.log", kind: .file)
        try TransferSourceGuard.checkDeletable(file, recursive: false)
    }

    /// A symlink is not itself a directory — mirrors
    /// `TransferSourceGuardTests.doesNotTreatASymlinkAsADirectory`.
    @Test func doesNotTreatASymlinkAsADirectory() throws {
        let link = RemoteFileItem(name: "current", path: "/var/logs/current", kind: .symlink)
        try TransferSourceGuard.checkDeletable(link, recursive: false)
    }
}
