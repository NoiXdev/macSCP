import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The one property the value tests cannot reach: that the ledger behind
/// the checksum column has exactly ONE writer — the request path.
///
/// (There were two. The other — that the table's cell mapping knows every
/// column — is now a compile-time check instead of a scan: `cellText`
/// switches over `FileColumn` exhaustively. The scan it replaced was
/// satisfied by the STYLING switch in the same file and stayed green after
/// the real branch was deleted, measured while writing this.)
///
/// This one is the whole point of the feature. A column that fills itself
/// is a column that computes, and computing is the thing the maintainer
/// decided must stay an action. There is no rendering harness here (the
/// boundary the other wiring guards in this target document), so the check
/// reads source — built to `CLAUDE.md`'s two rules for that:
///
/// - **Nothing spells a symbol it could read.** File locations come off the
///   type names themselves. Rename a type and this guard follows it to its
///   new file rather than going silent.
/// - **Every negative check stands beside a positive one over the same
///   text.** The one negative below (the browse view model never touches
///   the ledger) is anchored by a positive check that the file it scans is
///   the browse view model at all.
@Suite("Checksum column wiring")
@MainActor
struct ChecksumColumnWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ChecksumColumnWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourcesRoot = repoRoot.appendingPathComponent("Sources")

    /// A file's CODE, with every `//` comment cut away — the difference
    /// between a guard and a comment that runs (see
    /// `ChecksumSurfaceGuardTests`, which was caught by exactly that).
    /// This project writes long explanatory comments AND scans source, so a
    /// prose sentence naming a call is indistinguishable from the call
    /// unless the prose is removed first.
    private static func code(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Every `.swift` file under `Sources/`, found rather than listed.
    private static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil)
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The single file whose code DECLARES `name` as a type. Fails if it is
    /// not exactly one, so a split or a duplicate cannot leave this guard
    /// scanning a file that no longer holds the thing it is about.
    private static func fileDeclaring(_ name: String) throws -> URL {
        var matches: [URL] = []
        for url in try swiftFiles() {
            if declares(name, in: try code(at: url)) { matches.append(url) }
        }
        #expect(matches.count == 1, "expected exactly one file declaring \(name)")
        return try #require(matches.first)
    }

    /// Whether `text` declares a type called exactly `name`.
    ///
    /// The name has to END where it is written: a plain `contains` of
    /// "struct BrowserPane" also matched the file declaring
    /// `BrowserPaneSide`, and `fileDeclaring` then reported two candidates.
    /// It failed loudly — the count is a positive check — which is the only
    /// reason this was a five-minute fix rather than a guard reading the
    /// wrong file.
    private static func declares(_ name: String, in text: String) -> Bool {
        let keywords = ["struct ", "final class ", "class ", "enum ", "actor "]
        for keyword in keywords {
            var searchStart = text.startIndex
            while let range = text.range(
                of: keyword + name, range: searchStart..<text.endIndex) {
                searchStart = range.upperBound
                guard searchStart < text.endIndex else { return true }
                let next = text[searchStart]
                if !next.isLetter && !next.isNumber && next != "_" { return true }
            }
        }
        return false
    }

    // MARK: - The ledger has one writer, and it is the request path

    private static var ledgerName: String { String(describing: ChecksumLedger.self) }
    private static var batchName: String { String(describing: ChecksumBatch.self) }

    /// The writer exists at all — the positive anchor under everything
    /// below, which is otherwise a set of claims about how RARE a call is.
    ///
    /// Derived, not spelled: the ledger's write is whichever of its
    /// functions takes a request result, and `ledgerWrite()` asserts there
    /// is exactly one. Its labels are what every count below matches on, so
    /// this is also the check that those counts are matching on something
    /// real. `mutating` is a keyword rather than a name, and it is what
    /// makes the write a write.
    @Test func theLedgerDeclaresExactlyOneWriter() throws {
        let write = try Self.ledgerWrite()
        let ledger = try Self.code(at: Self.fileDeclaring(Self.ledgerName))

        #expect(write.requiredLabels.isEmpty == false)
        #expect(ledger.contains("mutating func \(write.name)("))
    }

    // MARK: - Reading a call shape off its declaration

    /// One function's name and argument labels, read off its declaration
    /// rather than spelled in a test — `"_"` for an unlabelled argument.
    ///
    /// This exists because a guard has to tell TWO calls apart that share a
    /// name. `.record(` is a generic selector: the ledger's write and an
    /// unrelated transfer-rate window both spell it, and the first attempt
    /// to separate them picked the files that happened to name the ledger
    /// type. That denominator then SHRANK on its own — a later fix moved the
    /// last `ChecksumLedger()` literal out of the file that builds both
    /// panes, and with it the whole file left the guard's world, so a
    /// compute-and-record planted there was invisible. A denominator that
    /// can quietly stop containing the place a violation would be written is
    /// not a scope, it is a leak.
    ///
    /// So the world is now every Swift file under `Sources/`, with no
    /// exclusion by name, and the two calls are told apart by their argument
    /// LABELS — which come from the declaration, so renaming the ledger's
    /// method or its labels moves this with it.
    private struct CallShape: Equatable {
        let name: String
        let labels: [String]

        /// The labels a call must carry to be this function's call, in the
        /// spelling a call site uses.
        var requiredLabels: [String] { labels.filter { $0 != "_" }.map { "\($0):" } }
    }

    /// Every function declared in `text`, with its parameter list and its
    /// declared return type (empty when it returns nothing).
    private static func declaredFunctions(
        in text: String
    ) -> [(shape: CallShape, parameters: String, returns: String)] {
        var found: [(CallShape, String, String)] = []
        var searchStart = text.startIndex
        while let keyword = text.range(of: "func ", range: searchStart..<text.endIndex) {
            searchStart = keyword.upperBound
            guard let open = text[keyword.upperBound...].firstIndex(of: "("),
                let close = matchingParenthesis(from: open, in: text)
            else { continue }
            let name = String(text[keyword.upperBound..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { continue }
            let parameters = String(text[text.index(after: open)..<close])
            let tail = text[close...].prefix(while: { $0 != "{" && $0 != "\n" })
            let returns = tail.range(of: "-> ").map {
                String(tail[$0.upperBound...]).trimmingCharacters(in: .whitespaces)
            } ?? ""
            found.append(
                (CallShape(name: name, labels: labels(inParameterList: parameters)),
                 parameters, returns))
            searchStart = close
        }
        return found
    }

    /// The label of each parameter in `list`: the first word of each
    /// top-level component, which is `_` for an unlabelled one.
    private static func labels(inParameterList list: String) -> [String] {
        var components: [String] = []
        var depth = 0
        var current = ""
        for character in list {
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]", ">": depth -= 1
            default: break
            }
            if character == ",", depth == 0 {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        components.append(current)
        return components.compactMap { component in
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init)
        }
    }

    /// The index of the `)` closing the `(` at `open`.
    private static func matchingParenthesis(
        from open: String.Index, in text: String
    ) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// How many calls of `shape` — the right name AND every one of its
    /// labels — appear in `text`.
    private static func callCount(of shape: CallShape, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while let call = text.range(
            of: ".\(shape.name)(", range: searchStart..<text.endIndex) {
            let open = text.index(before: call.upperBound)
            searchStart = call.upperBound
            guard let close = matchingParenthesis(from: open, in: text) else { continue }
            let arguments = text[text.index(after: open)..<close]
            if shape.requiredLabels.allSatisfy({ arguments.contains($0) }) { count += 1 }
            searchStart = close
        }
        return count
    }

    /// Every call of `shape` in the package, as (file, count) — no file is
    /// excluded, by name or by what it happens to mention.
    private static func callSites(of shape: CallShape) throws -> [(file: URL, count: Int)] {
        var sites: [(URL, Int)] = []
        for url in try swiftFiles() {
            let count = callCount(of: shape, in: try code(at: url))
            if count > 0 { sites.append((url, count)) }
        }
        return sites
    }

    /// The one function in `text` whose parameter list names `type`.
    private static func shape(takingParameterOfType type: String, in text: String) throws
        -> CallShape {
        let matches = declaredFunctions(in: text).filter { $0.parameters.contains(type) }
        #expect(matches.count == 1, "expected one function taking a \(type)")
        return try #require(matches.first?.shape)
    }

    /// The one function in `text` whose declared return type is `type`.
    private static func shape(returning type: String, in text: String) throws -> CallShape {
        let matches = declaredFunctions(in: text).filter { $0.returns == type }
        #expect(matches.count == 1, "expected one function returning \(type)")
        return try #require(matches.first?.shape)
    }

    /// The ledger's write, read off `ChecksumLedger`'s own declaration.
    private static func ledgerWrite() throws -> CallShape {
        try shape(
            takingParameterOfType: String(describing: ChecksumRequestResult.self),
            in: try code(at: fileDeclaring(ledgerName)))
    }

    // MARK: - The scan itself is measured before it is trusted

    /// The matcher tells the ledger's call from another `record(` that
    /// shares its name — checked against text this test owns, so it holds
    /// whatever the package currently contains.
    ///
    /// Without this, "one write in the package" could be true because the
    /// matcher matches almost nothing. It is the positive anchor under a
    /// count whose whole job is to be small.
    @Test func theCallMatcherTellsTheLedgersWriteFromAnotherRecordCall() throws {
        let write = try Self.ledgerWrite()

        let ledgerCall = "checksumLedger.record(result, for: item)"
        let otherCall = "rateWindow.record(bytes: progress.bytesTransferred, at: now())"
        let wrappedLedgerCall = "ledger.record(\n    result,\n    for: item)"

        #expect(Self.callCount(of: write, in: ledgerCall) == 1)
        #expect(Self.callCount(of: write, in: wrappedLedgerCall) == 1)
        #expect(Self.callCount(of: write, in: otherCall) == 0)
        #expect(Self.callCount(of: write, in: ledgerCall + otherCall) == 1)
    }

    /// The scan reaches the whole package. 258 Swift files under `Sources/`
    /// when this was written; the floor is deliberately well below that, so
    /// it survives ordinary growth and shrinkage while still failing loudly
    /// if the enumeration ever comes back with a handful of files or none.
    @Test func theScanReadsEverySwiftFileInThePackage() throws {
        #expect(try Self.swiftFiles().count >= 200)
    }

    /// Exactly ONE write into the ledger in the WHOLE package, and it is in
    /// the file that also builds the run.
    ///
    /// A second one anywhere is the edit this guard exists to stop: a
    /// listing, a refresh or a column toggle quietly filling the ledger,
    /// i.e. computing without being asked. "Anywhere" is the point — the
    /// previous version of this test asked only the files that mentioned the
    /// ledger type, and a compute-and-record planted in the file that builds
    /// both panes was invisible to it.
    @Test func theLedgerIsWrittenFromOnePlaceAndItIsTheRequestPath() throws {
        let sites = try Self.callSites(of: Self.ledgerWrite())
        let total = sites.reduce(0) { $0 + $1.count }

        #expect(total == 1, "expected 1 ledger write in Sources, found \(total)")
        #expect(sites.count == 1)

        let requestPath = try #require(sites.first?.file)
        #expect(try Self.code(at: requestPath).contains("\(Self.batchName)("))
    }

    /// Both surfaces that can ask for a digest ask through ONE place, and
    /// that place is the one that remembers (review C1).
    ///
    /// The info sheet and the batch sheet each called the view model
    /// themselves, and only the batch's answer was recorded — so a digest
    /// read in the info sheet left the column empty for the very file it
    /// had just been computed for, and asking again cost a second
    /// server-side hash of the whole file. What holds that shut is a count:
    /// ONE call to the view model's checksum operation in the whole
    /// PACKAGE, and it is in the file that also holds the single write
    /// above. Package-wide for the same reason as the write: a third
    /// surface added in another file would otherwise bypass the ledger with
    /// nothing going red.
    @Test func bothChecksumSurfacesAskThroughTheOnePlaceThatRemembers() throws {
        let ask = try Self.shape(
            returning: String(describing: ChecksumRequestResult.self),
            in: try Self.code(
                at: Self.fileDeclaring(String(describing: RemoteBrowserViewModel.self))))
        let sites = try Self.callSites(of: ask)
        let total = sites.reduce(0) { $0 + $1.count }

        #expect(total == 1, "expected 1 call asking for a checksum, found \(total)")
        let asking = try #require(sites.first?.file)

        let code = try Self.code(at: asking)
        #expect(code.contains("\(String(describing: ChecksumBatchSheet.self))("))
        #expect(code.contains("\(String(describing: InfoPermissionsSheet.self))("))
        #expect(Self.callCount(of: try Self.ledgerWrite(), in: code) == 1)
    }

    /// The ledger is NOT the pane's own state (review I2): a value the user
    /// paid a server-side hash for must not die when the pane is rebuilt —
    /// a tab switch, hiding the Files pane, a reconnect. Its home is the
    /// session, which `SessionTabTests` reads from the value side.
    ///
    /// Both panes get their ledger from the session, and the check does not
    /// spell the way they do it (re-review N3).
    ///
    /// This was the one unguarded link. `checksumLedger: .constant(…)` at
    /// both call sites keeps every other check in this file green — the
    /// property is still a binding, the write is still one — and undoes the
    /// whole of "the ledger lives with the tab" with a suite that reports
    /// success. The failure it produces is visible (a column that never
    /// fills) rather than wrong, which is why it is a guard and not a
    /// redesign.
    ///
    /// Derived end to end: the factory's NAME is read out of the session
    /// type's own file as the one function returning a binding of the
    /// ledger, and the argument label is read out of the pane's own
    /// declaration. Rename either and this follows it.
    @Test func bothPanesTakeTheirLedgerFromTheSessionsOwnBindingFactory() throws {
        let sessionFile = try Self.code(at: Self.fileDeclaring(String(describing: SessionTab.self)))
        let factories = Self.functionNames(returning: "Binding<\(Self.ledgerName)>", in: sessionFile)
        #expect(factories.count == 1, "one factory binds a pane to a session's ledger")
        let factory = try #require(factories.first)

        let label = try #require(try Self.ledgerArgumentLabel())
        let regions = try Self.paneConstructionRegions()
        #expect(regions.count == 2, "the window builds a local pane and a remote one")

        for region in regions {
            #expect(region.contains("\(label):"), "a pane is built without a ledger")
            #expect(region.contains("\(factory)("), "a pane's ledger does not come from a session")
        }
    }

    /// The names of the functions in `text` whose declared return type is
    /// exactly `returnType`.
    ///
    /// Walks BACK from the return type to the nearest preceding `func `
    /// rather than reading one line, because a signature wraps: the factory
    /// this guard looks for puts its parameters on their own line, so
    /// `func` and `-> …` are not on the same one. A line-at-a-time version
    /// found nothing and said so — the count is a positive check — which is
    /// how this shape was noticed rather than silently tolerated.
    private static func functionNames(returning returnType: String, in text: String) -> [String] {
        var names: [String] = []
        var searchStart = text.startIndex
        while let arrow = text.range(
            of: "-> \(returnType)", range: searchStart..<text.endIndex) {
            searchStart = arrow.upperBound
            guard let keyword = text.range(
                of: "func ", options: .backwards, range: text.startIndex..<arrow.lowerBound),
                let parenthesis = text[keyword.upperBound..<arrow.lowerBound].firstIndex(of: "(")
            else { continue }
            names.append(String(text[keyword.upperBound..<parenthesis]))
        }
        return names
    }

    /// The pane's own argument label for the ledger, read off its
    /// declaration instead of spelled here.
    private static func ledgerArgumentLabel() throws -> String? {
        let pane = try code(at: fileDeclaring(String(describing: BrowserPane.self)))
        for line in pane.split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains("var ") && line.contains(": \(ledgerName)") {
            guard let variable = line.range(of: "var "),
                let colon = line[variable.upperBound...].firstIndex(of: ":")
            else { continue }
            return String(line[variable.upperBound..<colon]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// One slice of source per `BrowserPane(` construction, each running to
    /// the start of the next (or to the end of the file) — the same shape
    /// `BucketListTransferGuardTests` already uses on this file, so a check
    /// about one pane cannot be satisfied by the other pane's arguments.
    private static func paneConstructionRegions() throws -> [String] {
        let paneName = String(describing: BrowserPane.self)
        let files = try swiftFiles().filter { try code(at: $0).contains("\(paneName)(") }
        let constructing = files.filter { !declares(paneName, in: (try? code(at: $0)) ?? "") }
        #expect(constructing.count == 1, "one file builds the panes")
        guard let file = constructing.first else { return [] }

        let source = try code(at: file)
        var starts: [String.Index] = []
        var searchStart = source.startIndex
        while let found = source.range(of: "\(paneName)(", range: searchStart..<source.endIndex) {
            starts.append(found.lowerBound)
            searchStart = found.upperBound
        }
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : source.endIndex
            return String(source[starts[index]..<end])
        }
    }

    /// Reads DECLARATIONS rather than a spelled property name: every stored
    /// property of the ledger's type in that file has to be a binding, so a
    /// renamed property is still covered and a re-added pane-owned one is
    /// caught whatever it is called. The positive half — that there is such
    /// a declaration at all — is what keeps this from passing over a file
    /// that stopped mentioning the ledger entirely.
    @Test func thePanesLedgerIsBoundFromOutsideRatherThanOwnedByThePane() throws {
        let pane = try Self.code(at: Self.fileDeclaring(String(describing: BrowserPane.self)))

        let declarations = pane
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("var ") && $0.contains(": \(Self.ledgerName)") }

        #expect(declarations.count == 1, "the pane declares one ledger property")
        #expect(declarations.allSatisfy { $0.contains("@Binding") })
    }

    /// The negative: nothing on the browse/listing path writes the ledger.
    /// A listing is where a value would have to be filled in automatically,
    /// and "empty until asked" is exactly the property that would be lost.
    ///
    /// Anchored by two positive checks over the same text — the file really
    /// is the browse view model (it declares the sort key the browser sorts
    /// by) and it really does list directories — so this cannot become a
    /// check that scans nothing and passes.
    @Test func theBrowseViewModelNeverTouchesTheLedger() throws {
        let viewModel = try Self.code(
            at: Self.fileDeclaring(String(describing: RemoteBrowserViewModel.self)))

        #expect(viewModel.contains("enum \(String(describing: FileSortKey.self))"))
        #expect(viewModel.contains("func refresh"))

        #expect(viewModel.contains(Self.ledgerName) == false)
        #expect(viewModel.contains(".record(") == false)
    }
}
