import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionSelectionValues")
struct FileActionSelectionValuesTests {
    private func item(path: String, name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: path, kind: .file)
    }

    @Test func bindsTheThreeReservedNames() {
        let values = FileActionSelectionValues.values(for: item(path: "/var/log/syslog", name: "syslog"))
        #expect(values["PATH"] == "/var/log/syslog")
        #expect(values["DIR"] == "/var/log")
        #expect(values["NAME"] == "syslog")
    }

    /// The three a SINGLE item supplies. `PATHS` is the whole selection's
    /// and is expanded by `FileActionPlanner`, not bound here, so it is
    /// absent by construction rather than by omission — and this equality
    /// is what would fail if it were ever added in the wrong place.
    @Test func bindsTheThreeNamesASingleItemSupplies() {
        let values = FileActionSelectionValues.values(for: item(path: "/a/b", name: "b"))
        #expect(Set(values.keys) == ["PATH", "DIR", "NAME"])
        #expect(Set(values.keys).isSubset(of: FileActionTemplate.reservedNames))
    }

    @Test func anItemAtTheRootGetsTheRootAsItsDirectory() {
        let values = FileActionSelectionValues.values(for: item(path: "/only", name: "only"))
        #expect(values["DIR"] == "/")
    }

    /// A listing is unspecified input for `RemotePath`, so the path is
    /// normalized before its parent is taken. A doubled slash from a server
    /// must not reach `parent(of:)` raw.
    @Test func aDoubledSlashFromTheServerIsNormalizedBeforeTheParentIsTaken() {
        let values = FileActionSelectionValues.values(for: item(path: "//var//log//syslog", name: "syslog"))
        #expect(values["PATH"] == "/var/log/syslog")
        #expect(values["DIR"] == "/var/log")
    }

    /// A trailing slash on a directory item must not make its own name the
    /// directory.
    @Test func aTrailingSlashDoesNotMakeTheItemItsOwnParent() {
        let values = FileActionSelectionValues.values(for: item(path: "/var/log/", name: "log"))
        #expect(values["PATH"] == "/var/log")
        #expect(values["DIR"] == "/var")
    }
}
