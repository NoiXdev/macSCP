import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// `supportsAppendResume` is defaulted to `true` in a protocol extension
/// (`RemoteFileSystem.swift:207`), so a conformer that does not override it
/// is appendable BY SILENCE. Two things follow, and this suite pins both.
///
/// 1. `WebDAVFileSystem` answers `false`, which is why
///    `RemoteFSFinding.resumeNotSupported` — thrown at
///    `WebDAVFileSystem.swift:450` when `mode != .overwrite` — has no
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
    /// inherits `true` in silence turns this red instead.
    ///
    /// Both checks are POSITIVE: sets that must match, not absences. An
    /// emptied-out scan fails them rather than reading as satisfied
    /// (CLAUDE.md, "Guards that name what they watch").
    ///
    /// Overrides are attributed by FILE, not by walking back to the enclosing
    /// type: the two override lines are textually IDENTICAL
    /// (`WebDAVFileSystem.swift:417` and `S3FileSystem.swift:927` differ in
    /// nothing but their file), so any search that located a line's owner by
    /// matching its text would be matching on something that is not unique.
    /// A file that declares two conformers and overrides in one would read as
    /// that file overriding — which is red here, and a human then looks. That
    /// is the intended outcome, not a gap.
    @Test func exactlyTheseTypesConformAndExactlyTheseFilesOverride() throws {
        var conformers: Set<String> = []
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
            for line in code.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line)
                if let name = Self.conformerName(in: text) { conformers.insert(name) }
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

    /// The declared type name on a line that CONFORMS to `RemoteFileSystem`,
    /// or `nil`.
    ///
    /// `extension` is in the keyword list on purpose: a conformance added as
    /// `extension Foo: RemoteFileSystem {}` is exactly the seventh conformer
    /// this guard exists to notice, and a scan that only knew
    /// `class`/`struct`/`actor` would miss it while the set check above still
    /// passed — a negative check going stale in silence. The protocol's own
    /// default-providing `extension RemoteFileSystem {`
    /// (`RemoteFileSystem.swift:161`) carries no `:` and is therefore not
    /// counted, which the test below pins.
    private static func conformerName(in line: String) -> String? {
        guard line.contains("RemoteFileSystem"), line.contains(":"),
              line.contains("class ") || line.contains("struct ")
                || line.contains("actor ") || line.contains("extension ")
        else { return nil }
        let parts = line.components(separatedBy: " ")
        guard let keyword = parts.firstIndex(where: {
            $0 == "class" || $0 == "struct" || $0 == "actor" || $0 == "extension"
        }) else { return nil }
        let nameIndex = parts.index(after: keyword)
        guard nameIndex < parts.endIndex else { return nil }
        let name = parts[nameIndex].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return name.isEmpty || name == "RemoteFileSystem" ? nil : name
    }

    /// The positive companion to `conformerName`'s exclusions: it really does
    /// read a conformance off a declaration line, and really does ignore the
    /// protocol's own extension. Without this, a `conformerName` that returned
    /// `nil` for everything would leave the set check comparing two empty
    /// sets — which is not how a set equality fails, but is how a typo in the
    /// keyword list would read if the expected set were ever emptied too.
    @Test func theConformerScannerReadsDeclarationsAndNotTheProtocolsOwnExtension() {
        #expect(Self.conformerName(
            in: "public final class S3FileSystem: RemoteFileSystem, S3RequestBuilder {")
            == "S3FileSystem")
        #expect(Self.conformerName(in: "public struct LocalFileSystem: RemoteFileSystem {")
            == "LocalFileSystem")
        #expect(Self.conformerName(in: "extension Foo: RemoteFileSystem {") == "Foo")
        #expect(Self.conformerName(in: "extension RemoteFileSystem {") == nil)
        #expect(Self.conformerName(in: "public protocol RemoteFileSystem: Sendable {") == nil)
    }
}
