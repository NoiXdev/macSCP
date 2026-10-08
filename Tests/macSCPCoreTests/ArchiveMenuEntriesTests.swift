import Testing
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveMenuEntriesTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }
    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .directory)
    }
    private func entries(
        _ selection: [RemoteFileItem], archiving: Bool = true
    ) -> [BrowserMenuEntry] {
        BrowserContextMenu.entries(
            for: selection, side: .remote, supportsArchiving: archiving)
    }
    private func isExtract(_ entry: BrowserMenuEntry) -> Bool {
        if case .extractArchive = entry { return true } else { return false }
    }
    private func isCompress(_ entry: BrowserMenuEntry) -> Bool {
        if case .compressTo = entry { return true } else { return false }
    }

    @Test func aBackendThatCannotRunCommandsOffersNoArchiveEntryAtAll() {
        let offered = entries([folder("d")], archiving: false)
        #expect(offered.contains(where: isCompress) == false)
        #expect(offered.contains(where: isExtract) == false)
    }

    /// The same holds for a selection that WOULD offer an extraction: the
    /// gate closes both kinds of entry, not just the compress run.
    @Test func aClosedGateAlsoWithholdsExtractFromAnArchive() {
        let offered = entries([file("ar.tar.gz")], archiving: false)
        #expect(offered.contains(where: isCompress) == false)
        #expect(offered.contains(where: isExtract) == false)
    }

    /// The positive beside that negative: with the gate open the entries ARE
    /// there. Without this, a model that stopped emitting them entirely
    /// would satisfy the case above.
    @Test func aBackendThatCanRunCommandsOffersThem() {
        let offered = entries([folder("d")])
        #expect(offered.contains(.compressTo(.zip)))
        #expect(offered.contains(.compressTo(.tarGz)))
    }

    @Test func theGateDefaultsToClosedSoEveryOldCallSiteKeepsItsMenu() {
        let offered = BrowserContextMenu.entries(for: [file("ar.zip")], side: .remote)
        #expect(offered.contains(where: isCompress) == false)
        #expect(offered.contains(where: isExtract) == false)
    }

    @Test func gzIsOfferedOnlyForASingleFile() {
        #expect(entries([file("a.log")]).contains(.compressTo(.gz)))
        #expect(entries([folder("d")]).contains(.compressTo(.gz)) == false)
        #expect(entries([file("a"), file("b")]).contains(.compressTo(.gz)) == false)
    }

    @Test func theCompressEntriesSitInOneUnbrokenRunInFormatOrder() throws {
        let offered = entries([file("a.log")])
        let positions = offered.indices.filter { isCompress(offered[$0]) }
        let first = try #require(positions.first)
        let last = try #require(positions.last)
        #expect(positions == Array(first...last))
        #expect(
            positions.map { offered[$0] }
                == [.compressTo(.zip), .compressTo(.tarGz), .compressTo(.gz)])
    }

    @Test func extractIsOfferedForOneRowWhoseNameNamesAFormat() {
        #expect(entries([file("ar.tar.gz")]).contains(.extractArchive(.tarGz)))
        #expect(entries([file("notes.txt")]).contains(where: isExtract) == false)
    }

    /// Both sides of the kind gate: a FILE named `ar.zip` offers extract, a
    /// DIRECTORY of the same name does not.
    @Test func extractIsOfferedForAFileButNotForAFolderOfTheSameName() {
        #expect(entries([file("ar.zip")]).contains(.extractArchive(.zip)))
        #expect(entries([folder("ar.zip")]).contains(where: isExtract) == false)
    }

    @Test func extractIsNotOfferedForSeveralRows() {
        #expect(entries([file("a.zip"), file("b.zip")]).contains(where: isExtract) == false)
    }

    /// A bucket row still answers only `copyPath` — the rule at the top of
    /// `entries(for:…)`. Archiving must not reach around it.
    @Test func aBucketRowGetsNoArchiveEntry() {
        let bucket = RemoteFileItem(
            name: "b", path: "/b", kind: .directory, isBucket: true)
        let offered = BrowserContextMenu.entries(
            for: [bucket], side: .remote, supportsArchiving: true,
            scope: BrowserScope(rootIsContainerList: true, currentPath: "/"))
        #expect(offered == [.copyPath])
    }
}
