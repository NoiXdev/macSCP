import Foundation
import MacSCPTestSupport
import Testing

/// Both tab fills of a key passphrase go through the form's own fill,
/// `ConnectionViewModel.fillManagedKeyPassphrase(store:secrets:)` (review
/// follow-ups of 2026-09-18, Task 6 fix round 1) — the one that records
/// whether an unreadable `managed_keys.json` hid the key, so that a dial
/// failing for a missing passphrase names the store. A fill that called
/// `ManagedKeyPassphrase.resolve` itself would drop that record and bring
/// back "enter a passphrase" with nothing pointing at the store.
///
/// Scanned rather than run: nothing in this target renders SwiftUI, so no
/// test presses Connect. Every read goes through
/// `SwiftSource.blankingCommentsAndStrings` first, so a comment naming
/// either call cannot satisfy or trip the checks. The NEGATIVE ("no App
/// file calls the resolver") stands beside the POSITIVE over the same span
/// ("the two fills call the form's fill"), so neither can go quiet alone
/// (CLAUDE.md, "Guards that name what they watch").
@Suite("Tab key passphrase fill guard")
struct TabKeyPassphraseFillGuardTests {
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit")

    private static func blankedAppSources() throws -> [String: String] {
        var files: [String: String] = [:]
        for url in try SourceCorpus.files(under: appRoot) where url.pathExtension == "swift" {
            files[url.lastPathComponent] = try SourceCorpus.code(of: url)
        }
        return files
    }

    private static func count(_ token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    @Test func bothTabFillsGoThroughTheFormsOwnFill() throws {
        let files = try Self.blankedAppSources()
        #expect(files.count > 50, "the scan read \(files.count) App files")

        // POSITIVE: the two fills, one in each file, counted 2026-09-18.
        let fill = ".fillManagedKeyPassphrase("
        let filling = files.filter { Self.count(fill, in: $0.value) > 0 }
            .mapValues { Self.count(fill, in: $0) }
        #expect(filling == ["ContentView.swift": 1, "ConnectionFormView.swift": 1])

        // NEGATIVE, over the same files: nothing resolves the passphrase
        // around the form's fill.
        let resolving = files.filter { $0.value.contains("ManagedKeyPassphrase.resolve(") }.keys
        #expect(resolving.isEmpty, "\(resolving.sorted())")
    }
}
