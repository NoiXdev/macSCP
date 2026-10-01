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
///    — has no
///    production path to a reader: `TransferEngine` writes `.append` only
///    when `effectiveResume` is true, and that needs
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

    /// Every conformer, and every override — so a seventh conformer that
    /// inherits `true` in silence turns this red instead, WHEN its declaration
    /// names `RemoteFileSystem` (or a protocol refining it) in the header of a
    /// `class`, `struct`, `actor`, `enum` or `extension` under `Sources/`.
    /// Not covered, and said so rather than implied: a subclass of a
    /// conformer (it inherits that conformer's answer, which is the point of
    /// subclassing, not a silent default), a conformance reached through a
    /// `typealias` composition, and anything under `Tests/` — the test doubles
    /// inherit the default on purpose.
    ///
    /// Both checks are POSITIVE: sets that must match, not absences. An
    /// emptied-out scan fails them rather than reading as satisfied
    /// (CLAUDE.md, "Guards that name what they watch").
    ///
    /// Overrides are attributed by FILE, not by walking back to the enclosing
    /// type: the two override lines are textually IDENTICAL
    /// (the declarations in `WebDAVFileSystem.swift` and `S3FileSystem.swift`
    /// differ in nothing but their file), so any search that located a line's owner by
    /// matching its text would be matching on something that is not unique.
    /// A file that declares two conformers and overrides in one would read as
    /// that file overriding — which is red here, and a human then looks. That
    /// is the intended outcome, not a gap.
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
                inherited = list.split(separator: ",").compactMap { token in
                    let trimmed = token.trimmingCharacters(in: .whitespaces)
                    return trimmed.split(separator: ".").last.map(String.init)
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

        // And what is not a conformer.
        #expect(Self.conformers(in: "struct Plain: Sendable {}\nenum Kind: String { case a }") == [])
        #expect(Self.conformers(in: "protocol Unrelated: Sendable {}\nstruct C: Unrelated {}") == [])
    }
}
