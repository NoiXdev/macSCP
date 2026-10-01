import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// `supportsAppendResume` is defaulted to `true` in a protocol extension
/// (`RemoteFileSystem.swift:207`), so a conformer that does not override it
/// is appendable BY SILENCE. Two things follow, and this suite pins both.
///
/// 1. `WebDAVFileSystem` answers `false`, which is why
///    `RemoteFSFinding.resumeNotSupported` — thrown by
///    `WebDAVFileSystem.write(path:mode:contents:)` when `mode != .overwrite`
///    — has no production path to a reader: `TransferEngine` writes `.append`
///    only when `effectiveResume` is true, and that needs
///    `destination.supportsAppendResume` (`TransferEngine.swift:182`). The
///    throw is defence in depth. That PAIR is what `docs/BACKLOG.md` records
///    as pinned by nothing: a WebDAV that later answered `true` would make
///    the finding live with nothing announcing it. The first test below is
///    the announcement.
/// 2. An S3 redirect refusal cannot be classified resumable, because an
///    upload's destination is S3 and S3 answers `false` — the third gate in
///    `TransferQueueViewModel.swift:1231`. See
///    `RemoteFSFinding.readsAsConnectionFailure` for the whole argument.
///
/// The source half exists because `CitadelFileSystem` needs a live
/// connection and `S3FileSystem` has only a `private init` and an async
/// `connect`, so neither can be instantiated here. It is read through
/// `SourceCorpus.code(of:)`, which blanks comments and string literals, so a
/// comment quoting a conformance or an override can neither satisfy nor trip
/// it (CLAUDE.md, "Source-scanning guards read comments too").
@Suite("RemoteFileSystem append-resume")
struct RemoteFileSystemAppendResumeGuardTests {
    /// The two conformers a unit test can build, by their real answers.
    @Test func theTwoConstructibleBackendsAnswerWhatTheQueueReads() throws {
        #expect(LocalFileSystem().supportsAppendResume == true)

        let config = WebDAVConnectionConfig(
            baseURL: "https://dav.example.com/dav", username: "u",
            useNextcloudPath: false, password: "p")
        let webdav = WebDAVFileSystem(config: config, transport: FakeHTTPTransport(replies: []))
        #expect(webdav.supportsAppendResume == false)
    }

    /// The conformers and the overrides found under `Sources/`, each against a
    /// fixed expected set. This is a BEST-EFFORT check over declaration
    /// headers, not a proof that no conformer escapes it.
    ///
    /// What it reads: the header of every `class`, `struct`, `actor`, `enum`
    /// and `extension` that names `RemoteFileSystem`, or a protocol refining
    /// it (to any depth, through `,`, `&` and a leading attribute such as
    /// `@preconcurrency`).
    ///
    /// What it does not read, as far as known: a subclass of a conformer (it
    /// inherits that class's answer, so it is not a silent default); a
    /// conformance reached through a `typealias` composition; anything under
    /// `Tests/`, where the test doubles inherit the default on purpose; a
    /// declaration whose header contains a `{` before its inheritance list
    /// ends; a NESTED type that reuses the name of a real conformer (the set
    /// keys on bare names, so `enum Ns { struct ThroughputSink: ... }` leaves
    /// `ThroughputSink` appearing once and the set matching); and an override
    /// whose body spans several lines (only a single-line `{ true }` or
    /// `{ false }` is read, so such an override would drop out of the
    /// override set). The list is whatever was found, not a closed set.
    ///
    /// Why no stronger claim: eight defects have been found in this guard's
    /// scans so far, in this order. Six are misses: a keyword list without
    /// `extension`; an `enum`; a header wrapped over two lines; a type
    /// conforming through a refined protocol; a refinement composed with `&`;
    /// an attribute before the type. Two are not misses: an override
    /// attributed by walking back to its enclosing type (a design defect),
    /// and the protocol extension's own default counted as an overrider (a
    /// false red). The first miss and the override attribution were found by
    /// the plan author reading the sample guard; the false red by running it;
    /// and five of the six misses, all but the first, by a reader PLANTING a
    /// spelling the previous list lacked. CLAUDE.md ("Guards that name what
    /// they watch") calls a scan that keeps buying one spelling and revealing
    /// another evidence that the property wants a structural boundary rather
    /// than another anchor; five planted-and-missed spellings is that
    /// pattern.
    ///
    /// The structural alternative, not taken here: deleting the
    /// `supportsAppendResume` default from the protocol extension would make
    /// the compiler demand an answer from every conformer and close the
    /// question permanently. Measured 2026-10-01, it forces an explicit
    /// answer onto 30 conformer declarations across 22 files under `Tests/`,
    /// which is exactly what that extension's own comment says it exists to
    /// avoid. That is the maintainer's decision, raised separately; the
    /// `docs/BACKLOG.md` row that raises it carries the whole derivation of
    /// that figure — the scan, its 37 matches, and the seven excluded
    /// lines named — because this count was first written as 32 across 23
    /// and three different regexes gave three different totals.
    ///
    /// Both checks are POSITIVE: sets that must match, not absences. An
    /// emptied-out scan fails them rather than reading as satisfied
    /// (CLAUDE.md, "Guards that name what they watch").
    ///
    /// Overrides are attributed by FILE, not by walking back to the
    /// enclosing type: the two override lines are textually IDENTICAL (the
    /// declarations in `WebDAVFileSystem.swift` and `S3FileSystem.swift`
    /// differ in nothing but their file), so any search that located a
    /// line's owner by matching its text would be matching on something that
    /// is not unique. A file that declares two conformers and overrides in
    /// one would read as that file overriding — which is red here, and a
    /// human then looks. That is the intended outcome, not a gap.
    @Test func exactlyTheseTypesConformAndExactlyTheseFilesOverride() throws {
        var declarations: [Declaration] = []
        var overridesByFile: [String: String] = [:]
        // The protocol extension's own default is the thing being overridden,
        // not an override; it is read separately so the guard's premise (the
        // default is `true`) is itself pinned.
        var protocolDefault: String?

        let sources = SourceCorpus.url(of: .sources)
        for url in try SourceCorpus.files(under: sources)
        where url.pathExtension == "swift" {
            let code = try SourceCorpus.code(of: url)
            let key = SourceCorpus.key(url)
            declarations += Self.declarations(in: code)
            for line in code.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line)
                guard text.contains("var supportsAppendResume") else { continue }
                // The declaration's body, not a mention: `{ true }` / `{ false }`.
                let answer = text.contains("{ true }") ? "true"
                    : text.contains("{ false }") ? "false" : nil
                guard let answer else { continue }
                if key.hasSuffix("RemoteFS/RemoteFileSystem.swift") {
                    protocolDefault = answer
                } else {
                    overridesByFile[key] = answer
                }
            }
        }

        let conformers = Self.conformers(among: declarations)
        #expect(conformers == [
            "S3FileSystem", "WebDAVFileSystem", "LocalFileSystem",
            "CitadelFileSystem", "ThroughputPayload", "ThroughputSink",
        ], """
            The set of RemoteFileSystem conformers in Sources/ changed. A new \
            conformer inherits supportsAppendResume == true from the protocol \
            extension (RemoteFileSystem.swift:207) unless it overrides. Decide \
            its answer, then add it here. Found: \
            \(conformers.sorted().joined(separator: ", "))
            """)

        #expect(protocolDefault == "true", """
            The protocol extension in RemoteFileSystem.swift no longer answers \
            true for supportsAppendResume (found: \(protocolDefault ?? "no default")). \
            This guard's premise is that a conformer which does not override is \
            appendable by silence; if the default changed, the guard needs \
            rethinking, not a new expected value.
            """)

        #expect(overridesByFile.count == 2, """
            Expected exactly two files to override supportsAppendResume. \
            Found \(overridesByFile.count): \
            \(overridesByFile.keys.sorted().joined(separator: ", "))
            """)
        for (file, answer) in overridesByFile {
            #expect(answer == "false", """
                \(file) overrides supportsAppendResume to \(answer). Only S3 and \
                WebDAV override, and both answer false — a backend that can \
                append does not need to override at all, because the protocol \
                extension already answers true.
                """)
            #expect(
                file.hasSuffix("S3FileSystem.swift") || file.hasSuffix("WebDAVFileSystem.swift"),
                """
                \(file) overrides supportsAppendResume, which only \
                S3FileSystem.swift and WebDAVFileSystem.swift did when this \
                guard was written (2026-10-01).
                """)
        }
    }

    /// One `class` / `struct` / `actor` / `enum` / `extension` / `protocol`
    /// declaration, reduced to what the conformance question needs.
    struct Declaration: Equatable {
        let kind: String
        let name: String
        /// The comma-separated list after the colon, module prefixes dropped.
        let inherited: [String]
    }

    /// Every declaration in `code`, read STATEMENT-wise: newlines are folded
    /// to spaces first, so a header wrapped over several lines
    /// (`struct Foo: Sendable,` / `    RemoteFileSystem {`) is one unit. A
    /// line-wise scan cannot see that conformance, because neither line
    /// carries both the keyword and the protocol.
    ///
    /// The header is the text from the declared name up to the next `{`; a
    /// balanced generic parameter list is skipped, and a trailing `where`
    /// clause is cut off before the list is split.
    static func declarations(in code: String) -> [Declaration] {
        let flat = code.replacingOccurrences(of: "\n", with: " ")
        let keyword = /\b(class|struct|actor|enum|extension|protocol)\s+([A-Za-z_][A-Za-z0-9_.]*)/
        return flat.matches(of: keyword).map { match in
            let afterName = flat[match.range.upperBound...]
            var header = Substring(afterName.prefix { $0 != "{" })
            header = header.drop { $0.isWhitespace }
            if header.first == "<" {
                var depth = 0
                var end = header.startIndex
                for index in header.indices {
                    if header[index] == "<" { depth += 1 }
                    if header[index] == ">" { depth -= 1 }
                    end = header.index(after: index)
                    if depth == 0 { break }
                }
                header = header[end...].drop { $0.isWhitespace }
            }
            var inherited: [String] = []
            if header.first == ":" {
                var list = header.dropFirst()
                if let clause = list.range(of: " where ") { list = list[..<clause.lowerBound] }
                // `,` separates inherited types and `&` composes them
                // (`Sendable & RemoteFileSystem`); a leading attribute such as
                // `@preconcurrency` or `@retroactive` is a separate word, so
                // the type is the token's last word, minus any module prefix.
                inherited = list.split(whereSeparator: { $0 == "," || $0 == "&" })
                    .compactMap { token in
                        token.split(whereSeparator: \.isWhitespace).last
                            .flatMap { $0.split(separator: ".").last }
                            .map(String.init)
                    }
            }
            return Declaration(
                kind: String(match.output.1), name: String(match.output.2),
                inherited: inherited)
        }
    }

    /// The type names that conform to `RemoteFileSystem`, directly or through
    /// a protocol that refines it — to any depth, because
    /// `protocol Refined: RemoteFileSystem {}` followed by `struct Bar: Refined`
    /// never names `RemoteFileSystem` on `Bar`'s line and inherits `true` by
    /// silence all the same.
    ///
    /// Protocols are not themselves counted (a refinement is not an instance),
    /// and neither is the protocol or its own default-providing
    /// `extension RemoteFileSystem {` (`RemoteFileSystem.swift:161`).
    static func conformers(among declarations: [Declaration]) -> Set<String> {
        var protocols: Set<String> = ["RemoteFileSystem"]
        var grew = true
        while grew {
            grew = false
            for declaration in declarations
            where declaration.kind == "protocol"
                && !protocols.contains(declaration.name)
                && declaration.inherited.contains(where: protocols.contains) {
                protocols.insert(declaration.name)
                grew = true
            }
        }
        return Set(declarations
            .filter {
                $0.kind != "protocol" && $0.name != "RemoteFileSystem"
                    && $0.inherited.contains(where: protocols.contains)
            }
            .map(\.name))
    }

    private static func conformers(in code: String) -> Set<String> {
        conformers(among: declarations(in: code))
    }

    /// The positive companion to the scanner's exclusions: it really does read
    /// a conformance off a declaration, however the declaration is spelled,
    /// and really does ignore the protocol's own extension. Without this, a
    /// scanner that returned nothing would leave the set check comparing the
    /// tree against an expected set only a human keeps honest — and the first
    /// version of this scanner was line-wise with a `class`/`struct`/`actor`/
    /// `extension` keyword list, which a planted `enum`, a wrapped header and a
    /// refined protocol all walked through with the suite green.
    @Test func theConformerScannerReadsDeclarationsAndNotTheProtocolsOwnExtension() {
        #expect(Self.conformers(
            in: "public final class S3FileSystem: RemoteFileSystem, S3RequestBuilder {")
            == ["S3FileSystem"])
        #expect(Self.conformers(in: "public struct LocalFileSystem: RemoteFileSystem {")
            == ["LocalFileSystem"])
        #expect(Self.conformers(in: "extension Foo: RemoteFileSystem {") == ["Foo"])
        #expect(Self.conformers(in: "extension RemoteFileSystem {") == [])
        #expect(Self.conformers(in: "public protocol RemoteFileSystem: Sendable {") == [])

        // The three forms that once got through.
        #expect(Self.conformers(in: "enum Foo: RemoteFileSystem {}") == ["Foo"])
        #expect(Self.conformers(in: "struct Foo: Sendable,\n    RemoteFileSystem {\n}") == ["Foo"])
        #expect(Self.conformers(in: "extension Foo:\n    RemoteFileSystem\n{\n}") == ["Foo"])
        #expect(Self.conformers(in: """
            protocol Refined: RemoteFileSystem {}
            struct Bar: Refined {}
            """) == ["Bar"])
        // Refinement to depth two, declared in the opposite order.
        #expect(Self.conformers(in: """
            struct Baz: Deeper {}
            protocol Deeper: Refined, Sendable {}
            protocol Refined: RemoteFileSystem {}
            """) == ["Baz"])

        // Spellings around the keyword: generics, a where clause, a module
        // prefix, two conformers in one file.
        #expect(Self.conformers(in: "struct Box<T: Sendable>: RemoteFileSystem {}") == ["Box"])
        #expect(Self.conformers(in: "extension Foo: RemoteFileSystem where Foo: Sendable {}")
            == ["Foo"])
        #expect(Self.conformers(in: "struct Foo: macSCPCore.RemoteFileSystem {}") == ["Foo"])
        #expect(Self.conformers(in: """
            struct A: RemoteFileSystem {}
            final class B: Sendable, RemoteFileSystem {}
            """) == ["A", "B"])

        // Attributes before the type, and `&` compositions.
        #expect(Self.conformers(in: "struct Foo: @preconcurrency RemoteFileSystem {}") == ["Foo"])
        #expect(Self.conformers(in: "extension Foo: @retroactive RemoteFileSystem {}") == ["Foo"])
        #expect(Self.conformers(
            in: "struct Foo: @unchecked Sendable, @preconcurrency RemoteFileSystem {}")
            == ["Foo"])
        #expect(Self.conformers(in: """
            protocol Composed: Sendable & RemoteFileSystem {}
            struct Baz: Composed {}
            """) == ["Baz"])
        #expect(Self.conformers(in: "struct Foo: Sendable & RemoteFileSystem {}") == ["Foo"])

        // And what is not a conformer.
        #expect(Self.conformers(in: "struct Plain: Sendable {}\nenum Kind: String { case a }") == [])
        #expect(Self.conformers(in: "protocol Unrelated: Sendable {}\nstruct C: Unrelated {}") == [])
    }
}
