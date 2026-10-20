import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Holds `BoundedViewRegistry` to the `BoundedView` conformances in
/// `Sources/MacSCPAppKit`, and holds the sources to the ways a view could
/// bound itself without being counted.
///
/// `BoundedViewLayoutGuardTests` measures every entry of the registry in every
/// language, but it can only measure what the registry lists: a view that
/// declares a bound and is never added there is not measured, and nothing in
/// that suite would say so. Four checks close that, each with a positive half
/// beside it:
///
/// 1. **Set equality** between the registry's `typeName`s and the types the
///    source declares as conformers. Not a count: a count that happens to
///    match hides a swap. The failure message names the two directions as
///    separate lists, so a red says which way the gap runs.
/// 2. **No indirection around the scan.** The conformer scan reads the
///    protocol's own name on a declaration, so a conformance spelled through
///    a protocol that refines `BoundedView`, or through a typealias of it, is
///    invisible to it. A NEW view declared that way is in neither set — the
///    compiler does not force a registry entry — and nothing would be red.
///    So no such protocol or alias may exist in the app's sources.
/// 3. **No bound that bypasses the protocol.** `sheetBound(_:)` is an
///    unconstrained `View` method; a view that never conforms and writes a
///    literal into the call is bounded and in neither set. Every call site
///    must pass `Self.bound`, which only a type that declares a `bound` has.
/// 4. **Conformers and applications agree.** The number of conformer names
///    equals the number of `.sheetBound(Self.bound)` call sites. A view that
///    drops its conformance and keeps `static let bound` and the modifier
///    looks conformant, measures nothing, and is silent in checks 1 to 3;
///    it leaves one more application than conformers.
/// 5. The positive halves: each scan sees what it is written to see.
///
/// All scans read the comment-and-string-blanked view, so a doc comment that
/// quotes a conformance, a protocol or a call is not counted as one.
///
/// **What remains outside the scan.** A conformer declared in the TEST target
/// is not in `Sources/`: if it is not private, it compiles as a registry
/// entry (`BoundedViewEntry.init` requires conformance, not a location) and
/// the red reads "only in the registry". Two such probes exist in
/// `SheetBoundTests` and are private. And check 4 compares two totals: a
/// swap that keeps both equal (one conformer drops its application while a
/// non-conformer gains one) is not seen by it.
@Suite("Bounded view coverage")
struct BoundedViewCoverageTests {
    private static let appKitSources: URL = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit", isDirectory: true)

    /// Every Swift file under the app's own sources, blanked of comments and
    /// string literals, paired with its name.
    private static func blankedSources() throws -> [(name: String, code: String)] {
        let urls = try SourceCorpus.files(under: appKitSources).filter { $0.pathExtension == "swift" }
        let code = try SourceCorpus.code(ofAll: urls)
        return zip(urls, code).map { ($0.lastPathComponent, $1) }
    }

    // MARK: - The conformers

    /// The names of the types declared to conform to `BoundedView` in
    /// `code`: a `struct`, `class`, `enum` or `extension`, with the
    /// protocol among its inherited types.
    ///
    /// A word's left edge is spelled `(?:^|\W)`, never `\b`: Swift's `\b` is
    /// the Unicode word boundary, under which the `.` in `x.sheetBound` or
    /// `Module.BoundedView` joins two letters into one word and no edge is
    /// found. Measured on 2026-10-18: `x.sheetBound(someBound)` matched
    /// `\bsheetBound\s*\(` zero times. Swift's regex has no lookbehind, so the
    /// left edge consumes one character.
    static func conformerNames(in code: String) -> Set<String> {
        let declaration = #/(?:^|\W)(?:struct|class|enum|extension)\s+(\w+)\s*(?:<[^>{]*>)?\s*:[^{]*(?:^|\W)BoundedView(?!\w)/#
        return Set(code.matches(of: declaration).map { String($0.output.1) })
    }

    /// The names of the types `Sources/MacSCPAppKit` declares to conform to
    /// `BoundedView`, read off the blanked source.
    static func boundedViewTypeNamesInSources() throws -> Set<String> {
        try blankedSources().reduce(into: Set<String>()) { $0.formUnion(conformerNames(in: $1.code)) }
    }

    @Test @MainActor func everyConformerIsInTheRegistry() throws {
        let declared = try Self.boundedViewTypeNamesInSources()
        let measured = Set(BoundedViewRegistry.all.map(\.typeName))
        let onlyInSources = declared.subtracting(measured).sorted()
        let onlyInRegistry = measured.subtracting(declared).sorted()
        #expect(
            declared == measured,
            """
            only in Sources: \(onlyInSources); only in the registry: \(onlyInRegistry). \
            A type only in Sources is a view that bounds itself and is never measured: \
            add an entry for it to BoundedViewRegistry (Tests/macSCPAppKitTests/BoundedViewRegistry.swift). \
            A type only in the registry is one the scan cannot see, or a conformer declared outside \
            Sources/MacSCPAppKit: check for a protocol or typealias around BoundedView first.
            """)
    }

    /// The positive beside the check above: a scan that silently stopped
    /// matching anything would leave `declared` empty, which reads exactly
    /// like a scan that is satisfied.
    ///
    /// The floor is 35 on 2026-10-20, counted by
    /// `grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit | wc -l`
    /// (which prints 35; the line anchor leaves out the doc comments that
    /// quote the same text). It is a floor, not the expected figure: set
    /// equality above carries the exactness, and the floor moves with the
    /// tree — raise it when a thirty-sixth view lands.
    ///
    /// **Corrected 2026-10-20 (S3 bucket settings, Task 8).** This paragraph
    /// read, verbatim: "The floor is 33 on 2026-10-18" and "(which prints 33;"
    /// and "raise it when a thirty-fourth view lands". `BucketVersioningSheet`
    /// is the thirty-fourth, so all three moved by one; the same command run
    /// under the session's `grep` and under `/usr/bin/grep` prints 34.
    ///
    /// **Corrected 2026-10-20 (S3 bucket settings, Task 9).** The paragraph
    /// above this one read, verbatim: "The floor is 34 on 2026-10-20" and
    /// "(which prints 34;" and "raise it when a thirty-fifth view lands".
    /// `BucketCORSSheet` is the thirty-fifth, so all three moved by one. The
    /// Task 8 correction directly above is left as it stands: it records what
    /// the command printed when it was written.
    @Test func theScanFindsTheConformancesAtAll() throws {
        let declared = try Self.boundedViewTypeNamesInSources()
        #expect(declared.count >= 35, "the scan found \(declared.count) names")
        #expect(declared.contains(String(describing: FileActionEditor.self)))
    }

    // MARK: - No indirection around the scan

    /// Every protocol that refines `BoundedView` and every typealias that
    /// names it, as `"protocol Name"` / `"typealias Name"`. The protocol's
    /// own declaration is not among them: it has no `BoundedView` in its
    /// inheritance clause.
    static func indirections(in code: String) -> [String] {
        let refining = #/(?:^|\W)protocol\s+(\w+)[^{]*(?:^|\W)BoundedView(?!\w)/#
        let alias = #/(?:^|\W)typealias\s+(\w+)[^\n]*(?:^|\W)BoundedView(?!\w)/#
        return code.matches(of: refining).map { "protocol \($0.output.1)" }
            + code.matches(of: alias).map { "typealias \($0.output.1)" }
    }

    @Test func noProtocolOrAliasHidesAConformanceFromTheScan() throws {
        var offenders: [String] = []
        for (name, code) in try Self.blankedSources() {
            offenders += Self.indirections(in: code).map { "\(name): \($0)" }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders): a view declared through one of these is a BoundedView the conformer \
            scan cannot see, so it is in neither the scan nor the registry and nothing is red. \
            Conform each view to BoundedView directly.
            """)
    }

    /// The positive half. The negative above passes on a corpus the pattern
    /// can no longer read, so this requires the corpus to hold the one
    /// declaration of the protocol — and the patterns to flag every
    /// spelling they are written for, and only those.
    @Test func theIndirectionScanSeesWhatItClaimsToRead() throws {
        let declaration = #/(?:^|\W)protocol\s+BoundedView(?!\w)/#
        let declaring = try Self.blankedSources().filter { !$0.code.matches(of: declaration).isEmpty }
        #expect(declaring.map(\.name) == ["SheetBound.swift"], "\(declaring.map(\.name))")
        let declarations = declaring.reduce(0) { $0 + $1.code.matches(of: declaration).count }
        #expect(declarations == 1, "\(declarations) declarations of the protocol")

        #expect(Self.indirections(in: "protocol BoundedView: View {").isEmpty)
        #expect(Self.indirections(in: "protocol Refined: Sendable, BoundedView {").sorted() == ["protocol Refined"])
        #expect(Self.indirections(in: "protocol Refined where Self: BoundedView {").sorted() == ["protocol Refined"])
        #expect(Self.indirections(in: "typealias Alias = BoundedView").sorted() == ["typealias Alias"])
        #expect(Self.indirections(in: "typealias Alias = Sendable & BoundedView").sorted() == ["typealias Alias"])
        #expect(Self.indirections(in: "typealias Alias = MacSCPAppKit.BoundedView").sorted() == ["typealias Alias"])
        #expect(Self.indirections(in: "protocol Unrelated: Sendable {\n}\ntypealias Other = Int").isEmpty)
    }

    // MARK: - No bound that bypasses the protocol

    /// Every call of `sheetBound` in `code` that does not pass `Self.bound`,
    /// each as the text from the call's name to the end of its line, plus
    /// the number of calls and of declarations seen. A `func` declaration
    /// of the method is counted apart and is not a call.
    static func sheetBoundCalls(in code: String) -> (calls: Int, declarations: Int, offenders: [String]) {
        let name = #/(?:^|\W)(sheetBound)\s*\(/#
        let passesSelfBound = #/\s*Self\.bound\s*\)/#
        var calls = 0
        var declarations = 0
        var offenders: [String] = []
        for match in code.matches(of: name) {
            let start = match.output.1.startIndex
            if code[..<start].suffix(8).trimmingCharacters(in: .whitespaces).hasSuffix("func") {
                declarations += 1
                continue
            }
            calls += 1
            let rest = code[match.range.upperBound...]
            if rest.prefixMatch(of: passesSelfBound) == nil {
                let line = code[start...].prefix { $0 != "\n" }
                offenders.append(String(line))
            }
        }
        return (calls, declarations, offenders)
    }

    @Test func everySheetBoundCallPassesSelfBound() throws {
        var offenders: [String] = []
        for (name, code) in try Self.blankedSources() {
            offenders += Self.sheetBoundCalls(in: code).offenders.map { "\(name): \($0)" }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders): sheetBound(_:) is applied to something other than Self.bound. A view that \
            bounds itself with a literal never conforms to BoundedView, so it is in neither the \
            conformer scan nor the registry. Declare `static let bound` on a BoundedView and pass it.
            """)
    }

    /// The positive half: the scan sees the method's own declaration once,
    /// sees at least as many calls as there are bounded views, and flags
    /// every shape of call it is written to flag.
    ///
    /// The call floor is 33 on 2026-10-18, counted by
    /// `grep -rhn -e '^ *\.sheetBound(Self\.bound)$' Sources/MacSCPAppKit | wc -l`
    /// (which prints 33); like the conformer floor it moves with the tree.
    @Test func theCallScanSeesWhatItClaimsToRead() throws {
        let sources = try Self.blankedSources()
        let seen = sources.map { ($0.name, Self.sheetBoundCalls(in: $0.code)) }
        let declaring = seen.filter { $0.1.declarations > 0 }.map(\.0)
        #expect(declaring == ["SheetBound.swift"], "\(declaring)")
        #expect(seen.reduce(0) { $0 + $1.1.declarations } == 1)
        let calls = seen.reduce(0) { $0 + $1.1.calls }
        #expect(calls >= 33, "\(calls) calls of sheetBound")

        let literal = Self.sheetBoundCalls(in: "        .sheetBound(.width(400))\n")
        #expect(literal.calls == 1 && literal.offenders == ["sheetBound(.width(400))"], "\(literal)")
        let named = Self.sheetBoundCalls(in: "    x.sheetBound(someBound)")
        #expect(named.offenders == ["sheetBound(someBound)"], "\(named)")
        let other = Self.sheetBoundCalls(in: "        .sheetBound(Other.bound)")
        #expect(other.offenders == ["sheetBound(Other.bound)"], "\(other)")
        let clean = Self.sheetBoundCalls(in: "        .sheetBound(Self.bound)\n        .sheetBound( Self.bound )")
        #expect(clean.calls == 2 && clean.offenders.isEmpty, "\(clean)")
        let declaration = Self.sheetBoundCalls(in: "    func sheetBound(_ bound: SheetBound) -> some View {")
        #expect(declaration.calls == 0 && declaration.declarations == 1, "\(declaration)")
    }

    // MARK: - Conformers and applications agree

    /// The number of types declared as `BoundedView` conformers, and the
    /// number of `sheetBound` calls that pass `Self.bound`, over the app's
    /// sources.
    static func conformerAndApplicationCounts() throws -> (conformers: Int, applications: Int) {
        let applications = try blankedSources().reduce(0) {
            let found = sheetBoundCalls(in: $1.code)
            return $0 + found.calls - found.offenders.count
        }
        return (try boundedViewTypeNamesInSources().count, applications)
    }

    /// Equal, not "at least". The two directions mean different defects:
    ///
    /// - **More applications than conformers** is the copied view: someone
    ///   kept `static let bound` and `.sheetBound(Self.bound)` and dropped
    ///   `: BoundedView`, so it is bounded, unregistered and silent in every
    ///   other guard. It is also what an honest second application in one
    ///   type would look like, and that is deliberately NOT allowed: a type
    ///   that applies its bound in two branches of a `body` should apply it
    ///   once, on the container, so the bound has one place to read and one
    ///   place to change. A floor
    ///   (`applications >= conformers`) could not detect the copied view at
    ///   all, since that is exactly the direction in which it is satisfied.
    /// - **More conformers than applications** is a declared bound that
    ///   nothing applies: the type claims a size, is measured against it, and
    ///   is rendered with none.
    ///
    /// Both totals are 33 on 2026-10-18 (the commands are beside the floors
    /// above).
    @Test func everyConformerAppliesItsBoundExactlyOnce() throws {
        let counts = try Self.conformerAndApplicationCounts()
        #expect(
            counts.conformers == counts.applications,
            """
            \(counts.conformers) BoundedView conformers but \(counts.applications) applications of \
            sheetBound(Self.bound). More applications: a view keeps `static let bound` and the modifier \
            without conforming (conform it, or remove both), or a conformer applies its bound twice \
            (apply it once, on the container). More conformers: a conformer declares a bound nothing applies.
            """)
    }
}
