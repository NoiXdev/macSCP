import Foundation
import Testing
@testable import macSCPCore

@Suite("HiddenImportStore")
struct HiddenImportStoreTests {
    private func makeStore() -> (HiddenImportStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-hiddenimports-\(UUID().uuidString)")
        return (HiddenImportStore(directory: dir), dir)
    }

    @Test func missingFileReadsEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.allHidden() == [])
        #expect(try store.isHidden("x") == false)
    }

    @Test func hideThenAllHiddenAndIsHidden() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.hide("a")
        #expect(try store.allHidden() == ["a"])
        #expect(try store.isHidden("a") == true)
    }

    @Test func hidingTwiceIsIdempotent() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.hide("a")
        try store.hide("a")
        #expect(try store.allHidden() == ["a"])
    }

    @Test func unhideRemovesAndUnknownAliasIsNoop() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.hide("a")
        try store.unhide("a")
        #expect(try store.allHidden() == [])

        // Unhiding an alias that was never hidden must not throw and must
        // not change anything.
        try store.unhide("missing")
        #expect(try store.allHidden() == [])
    }

    @Test func unhideRemovesAllOccurrencesOfADuplicateAlias() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("hidden-imports.json")
        try Data("""
        {"aliases":["a","a"]}
        """.utf8).write(to: fileURL)

        try store.unhide("a")
        #expect(try store.allHidden() == [])
        #expect(try store.isHidden("a") == false)
    }

    @Test func allHiddenIsSortedCaseInsensitively() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.hide("zulu")
        try store.hide("alpha")
        #expect(try store.allHidden() == ["alpha", "zulu"])
    }

    @Test func isHiddenComparesExactly() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.hide("Prod")
        #expect(try store.isHidden("prod") == false)
        #expect(try store.isHidden("Prod") == true)
    }

    @Test func forwardCompatibilityWithUnknownField() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("hidden-imports.json")
        try Data("""
        {"aliases":["a"],"futureField":42}
        """.utf8).write(to: fileURL)

        #expect(try store.allHidden() == ["a"])
    }

    @Test func emptyFileStructureReadsEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("hidden-imports.json")
        try Data("{}".utf8).write(to: fileURL)

        #expect(try store.allHidden() == [])
    }
}

@Suite("ImportedHostPartition")
struct ImportedHostPartitionTests {
    private func host(_ alias: String) -> SSHConfigHost {
        SSHConfigHost(alias: alias, hostName: nil, user: nil, port: nil, identityFile: nil)
    }

    @Test func noHiddenAliasesLeavesEverythingVisible() {
        let hosts = [host("a"), host("b")]
        let result = ImportedHostPartition.split(hosts: hosts, hiddenAliases: [])
        #expect(result.visible == hosts)
        #expect(result.hidden == [])
        #expect(result.orphaned == [])
    }

    @Test func oneHiddenAliasIsRemovedFromVisibleAndListedInHidden() {
        let a = host("a")
        let b = host("b")
        let result = ImportedHostPartition.split(hosts: [a, b], hiddenAliases: ["a"])
        #expect(result.visible == [b])
        #expect(result.hidden == [a])
        #expect(result.orphaned == [])
    }

    @Test func hiddenAliasMissingFromHostsIsOrphaned() {
        let a = host("a")
        let result = ImportedHostPartition.split(hosts: [a], hiddenAliases: ["gone"])
        #expect(result.visible == [a])
        #expect(result.hidden == [])
        #expect(result.orphaned == ["gone"])
    }

    @Test func visiblePreservesInputOrder() {
        let z = host("zulu")
        let a = host("alpha")
        let result = ImportedHostPartition.split(hosts: [z, a], hiddenAliases: [])
        #expect(result.visible == [z, a])
    }

    @Test func renamedAliasEndsUpVisibleAndOldNameOrphaned() {
        let new = host("new")
        let result = ImportedHostPartition.split(hosts: [new], hiddenAliases: ["old"])
        #expect(result.visible == [new])
        #expect(result.orphaned == ["old"])
    }

    @Test func splitComparesAliasesExactly() {
        let prod = host("Prod")
        let result = ImportedHostPartition.split(hosts: [prod], hiddenAliases: ["prod"])
        #expect(result.visible == [prod])
        #expect(result.hidden == [])
        #expect(result.orphaned == ["prod"])
    }

    @Test func orphanedIsSortedAlphabeticallyWithMultipleEntries() {
        let result = ImportedHostPartition.split(hosts: [], hiddenAliases: ["zulu", "alpha", "mike"])
        #expect(result.orphaned == ["alpha", "mike", "zulu"])
    }

    /// Pins the tie-breaker in `sortAliasesForDisplay` (M11f/T1 review): two
    /// aliases that differ only by case compare as `.orderedSame` under
    /// `localizedCaseInsensitiveCompare`, and `Array.sorted` is not
    /// guaranteed stable, so without the plain `<` tie-breaker this pair's
    /// order flips between runs (reviewer measured 5 of 6 process runs one
    /// way, 1 the other). "Prod" < "prod" lexicographically (uppercase
    /// sorts first in ASCII), so this must always come out in that order.
    @Test func orphanedOrderIsDeterministicForCaseOnlyDifferingAliases() {
        let result = ImportedHostPartition.split(hosts: [], hiddenAliases: ["Prod", "prod"])
        #expect(result.orphaned == ["Prod", "prod"])
    }
}
