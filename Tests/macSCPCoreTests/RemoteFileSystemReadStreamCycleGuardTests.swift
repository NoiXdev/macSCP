import Foundation
import MacSCPTestSupport
import Testing

/// Pins the no-cycle invariant between `RemoteFileSystem`'s two `readStream`
/// spellings, which until now was carried by a comment.
///
/// The shape (`RemoteFileSystem.swift`'s own doc comment): BOTH spellings are
/// protocol requirements, so both dispatch through the witness table, and the
/// protocol extension defaults the three-argument one to the two-argument one.
/// A conformer that overrides only the two-argument one lands in its own
/// implementation and stops. A conformer that can check the validator —
/// `S3FileSystem`, `WebDAVFileSystem` — overrides BOTH, its two-argument one
/// delegating to its own three-argument one, so the extension's default is out
/// of the picture for it entirely.
///
/// The one spelling that recurses forever is the mixture: a conformer whose
/// two-argument `readStream` calls the three-argument one while taking the
/// extension's default for the three-argument one. That default calls the
/// two-argument one back. Nothing in the tree does it, it compiles, and it is
/// a hang rather than a crash — a download that never yields a byte.
/// `RemoteFileSystem.swift` said "it is the thing to check when a backend
/// grows a validator", and a sentence asking a future reader to check
/// something is what this project's own rule calls a comment that runs
/// (backlog: "The resume-identity and window-scope plan's deferred minors",
/// Task 1, item 2).
///
/// Read through `SourceCorpus`, so a comment describing the wiring — and both
/// backends carry one — cannot satisfy the scan.
@Suite("readStream's two spellings cannot form a cycle")
struct RemoteFileSystemReadStreamCycleGuardTests {
    /// Both roots: a test double that recursed would hang a test run exactly
    /// as a backend would hang a download.
    private static func swiftFiles() throws -> [URL] {
        try SourceCorpus.Root.allCases.flatMap { root in
            try SourceCorpus.files(under: SourceCorpus.url(of: root))
                .filter { $0.pathExtension == "swift" }
        }
    }

    /// Only the files whose RAW text carries the symbol are blanked. The raw
    /// read is the one the corpus caches anyway; blanking every Swift file in
    /// both roots to find the handful that declare a `readStream` would be
    /// the expensive half of this scan and would change no answer, because a
    /// file with no `readStream` in its text has none in its code view
    /// either.
    private static func declarations() throws -> [ReadStreamScan.Declaration] {
        var found: [ReadStreamScan.Declaration] = []
        for url in try swiftFiles() {
            guard try SourceCorpus.text(of: url).contains(ReadStreamScan.marker) else { continue }
            found += ReadStreamScan.declarations(
                in: try SourceCorpus.code(of: url), file: url.lastPathComponent)
        }
        return found
    }

    /// The negative: no conformer delegates its two-argument `readStream` to
    /// the three-argument one without implementing the three-argument one
    /// itself.
    ///
    /// "Itself" is read as "in the same file, at the same brace depth" — one
    /// type body, for every shape in this tree, where a conformer and its own
    /// members sit at one depth inside one file. A conformer split across two
    /// files, or one whose two spellings sit at different depths, would be
    /// read as a violation and named, not passed over.
    @Test func noConformerDelegatesIntoTheDefaultThatCallsItBack() throws {
        let declarations = try Self.declarations()
        var cycles: [String] = []
        for declaration in declarations
        where declaration.takesOffset && !declaration.takesValidator
            && declaration.body?.contains("ifMatching:") == true {
            let overrides = declarations.contains {
                $0.file == declaration.file && $0.depth == declaration.depth
                    && $0.takesValidator && $0.body != nil
            }
            if !overrides { cycles.append("\(declaration.file):\(declaration.line)") }
        }
        #expect(cycles.isEmpty, """
            \(cycles.joined(separator: ", ")): a two-argument readStream delegates to the \
            validator spelling, and the same type does not implement the validator spelling. \
            The protocol extension defaults it back to the two-argument one, so this recurses \
            until the download hangs — see RemoteFileSystem.swift's own comment on the pair.
            """)
    }

    /// The positive beside it, in three parts, because the negative above is
    /// a filter expected to come back empty and would go on passing if the
    /// scan stopped finding anything.
    ///
    /// 1. The scan sees the declarations at all.
    /// 2. The safe delegation really is in the tree — the shape the negative
    ///    has to walk past rather than flag.
    /// 3. BOTH spellings are protocol REQUIREMENTS. That is the premise of
    ///    the whole no-cycle argument: demote the validator spelling to an
    ///    extension-only member and a conformer overriding the two-argument
    ///    one could no longer be reached through the witness table, which is
    ///    the step the comment reasons from.
    @Test func theScanSeesTheDeclarationsItIsFilteringOver() throws {
        let declarations = try Self.declarations()
        #expect(declarations.count > 20, """
            only \(declarations.count) `\(ReadStreamScan.marker)` declarations found in the \
            whole tree — the scan the negative above runs is reading almost nothing.
            """)
        let delegating = declarations.filter {
            $0.takesOffset && !$0.takesValidator && $0.body?.contains("ifMatching:") == true
        }
        #expect(delegating.count >= 2, """
            no conformer delegates its two-argument readStream to the validator spelling any \
            more, so the negative above is walking past nothing. Either the HTTP backends \
            stopped doing it — in which case this guard wants re-anchoring — or the scan \
            broke. Found: \(delegating.map(\.file).joined(separator: ", ")).
            """)
        let protocolFile = declarations.filter { $0.file == "RemoteFileSystem.swift" }
        let requirements = protocolFile.filter { $0.body == nil }
        #expect(requirements.count == 2, """
            RemoteFileSystem declares \(requirements.count) bodyless readStream \
            requirements, not 2 — both spellings must be requirements, or a conformer's \
            override is not reached through the witness table and the no-cycle argument \
            does not hold.
            """)
        #expect(requirements.contains(where: \.takesValidator)
            && requirements.contains(where: { !$0.takesValidator }), """
                the two readStream requirements are not one of each spelling.
                """)
    }

    // MARK: - The scanner reacts (fixtures over synthetic source)

    /// The violation, planted: a conformer that delegates and does not
    /// override. The scanner must see both facts about it.
    @Test func theScannerSeesADelegationWithNoOverrideBesideIt() {
        let source = """
            struct Recursing: RemoteFileSystem {
                func readStream(
                    path: String, fromOffset offset: UInt64
                ) async throws -> AsyncThrowingStream<Data, Error> {
                    try await readStream(path: path, fromOffset: offset, ifMatching: nil)
                }
            }
            """
        let found = ReadStreamScan.declarations(in: source, file: "planted.swift")
        #expect(found.count == 1)
        #expect(found.first?.takesOffset == true)
        #expect(found.first?.takesValidator == false)
        #expect(found.first?.body?.contains("ifMatching:") == true)
    }

    /// And the safe shape: the same delegation with the validator spelling
    /// implemented beside it, at the same depth.
    @Test func theScannerSeesTheOverrideThatMakesTheDelegationSafe() {
        let source = """
            struct Checking: RemoteFileSystem {
                func readStream(
                    path: String, fromOffset offset: UInt64
                ) async throws -> AsyncThrowingStream<Data, Error> {
                    try await readStream(path: path, fromOffset: offset, ifMatching: nil)
                }

                func readStream(
                    path: String, fromOffset offset: UInt64, ifMatching tag: String?
                ) async throws -> AsyncThrowingStream<Data, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }
            """
        let found = ReadStreamScan.declarations(in: source, file: "planted.swift")
        #expect(found.count == 2)
        #expect(found.map(\.takesValidator) == [false, true])
        #expect(Set(found.map(\.depth)).count == 1, "both sit in one type body")
        #expect(found.allSatisfy { $0.body != nil })
    }

    /// A bodyless declaration — a protocol requirement — is read as one, and
    /// its depth is the protocol's, not the file's.
    @Test func theScannerTellsARequirementFromAnImplementation() {
        let source = """
            protocol Streaming {
                func readStream(path: String, fromOffset offset: UInt64) async throws -> Stream
                func readStream(
                    path: String, fromOffset offset: UInt64, ifMatching tag: String?
                ) async throws -> Stream
            }
            """
        let found = ReadStreamScan.declarations(in: source, file: "planted.swift")
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.body == nil })
        #expect(found.allSatisfy { $0.depth == 1 })
    }
}

/// Reads `func readStream(` declarations out of an already blanked Swift
/// source view: what the parameter list carries, how deep the declaration
/// sits, and its body if it has one.
///
/// Separate from the suite so the fixtures above can drive it over synthetic
/// sources, the shape `SnippetSourceScan` and this project's other scanners
/// use. The brace walk is `SourceSpan`'s.
enum ReadStreamScan {
    static let marker = "func readStream("

    struct Declaration {
        let file: String
        /// 1-based, counted in the blanked view, whose lines are the file's.
        let line: Int
        /// The parameter list as written, between the declaration's own
        /// parentheses.
        let parameters: String
        /// `{`s minus `}`s before the `func` keyword: one type body, one
        /// depth.
        let depth: Int
        /// `nil` for a declaration with no body — a protocol requirement.
        let body: String?

        var takesOffset: Bool { parameters.contains("fromOffset") }
        var takesValidator: Bool { parameters.contains("ifMatching") }
    }

    /// Every `readStream` declaration in `source`, in order of appearance.
    ///
    /// A declaration has a body when the line its parameter list closes on
    /// ends in `{`. Every `readStream` in this tree is written that way, and
    /// so is every Swift function whose signature is not a protocol
    /// requirement: the return clause carries no brace and no line break of
    /// its own. A declaration this rule misreads would be read as a
    /// requirement — bodyless — which is the fail-closed direction for the
    /// check above, since a requirement can neither delegate nor override.
    static func declarations(in source: String, file: String) -> [Declaration] {
        var found: [Declaration] = []
        var search = source.startIndex..<source.endIndex
        while let keyword = source.range(of: marker, range: search) {
            search = keyword.upperBound..<source.endIndex
            guard let close = closingParen(from: keyword.upperBound, in: source) else { continue }
            let parameters = String(source[keyword.upperBound..<close])
            let lineEnd = source[close...].firstIndex(of: "\n") ?? source.endIndex
            let tail = source[close..<lineEnd].trimmingCharacters(in: .whitespaces)
            var body: String?
            if tail.hasSuffix("{"),
               let brace = source[close..<lineEnd].lastIndex(of: "{") {
                body = SourceSpan.closingBrace(from: brace, in: source).map {
                    String(source[source.index(after: brace)..<$0])
                }
            }
            found.append(Declaration(
                file: file,
                line: source[..<keyword.lowerBound].filter { $0 == "\n" }.count + 1,
                parameters: parameters,
                depth: depth(before: keyword.lowerBound, in: source),
                body: body))
        }
        return found
    }

    /// The index of the `)` that balances the `(` just before `start`.
    private static func closingParen(from start: String.Index, in source: String) -> String.Index? {
        var depth = 1
        var index = start
        while index < source.endIndex {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func depth(before end: String.Index, in source: String) -> Int {
        var depth = 0
        for character in source[..<end] {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
        }
        return depth
    }
}
