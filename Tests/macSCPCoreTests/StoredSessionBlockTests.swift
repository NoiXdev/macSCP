import Foundation
import Testing
@testable import macSCPCore

/// The per-backend blocks of a `StoredSession`, taken as a set.
///
/// Two functions each listed the blocks by hand and each missed `ftp`
/// (`SessionDuplication.copy`, `SessionListViewModel.save`). The exhaustive
/// `switch` in `StoredSession.clearBackendBlocks()` / `copyBackendBlocks(from:)`
/// is the structural half of the fix; this suite is the other half, for the
/// block the switch cannot see.
@Suite("StoredSession backend blocks")
struct StoredSessionBlockTests {
    private func fullSession() -> StoredSession {
        StoredSession(
            name: "all", kind: .ssh,
            ssh: StoredSSHConfig(host: "h", username: "u"),
            s3: StoredS3Config(
                accessKeyID: "AK", region: "r", endpoint: "https://e.example.com",
                bucket: "b", usePathStyle: false),
            webdav: StoredWebDAVConfig(
                baseURL: "https://d.example.com", username: "u", useNextcloudPath: false),
            ftp: StoredFTPConfig(host: "f.example.com", port: 21, username: "u", security: .plain))
    }

    /// EVERY stored property of `StoredSession`, by label, in declaration
    /// order.
    ///
    /// A Mirror over a value, because the thing being asked is "what does the
    /// type declare", which no `ConnectionKind` switch can answer: a block
    /// keyed by nothing would pass every switch in the project.
    ///
    /// **Every label, not the ones whose type NAME looks like a block.**
    /// Until fix round 4 this helper kept only the children whose reflected
    /// type was `Optional<Stored…Config>`, and the re-review of 2026-11-05
    /// measured with a probe what that cannot see: `var sftp: SFTPBlock?`
    /// reflects as `Optional<SFTPBlock>`, and a non-optional
    /// `var sftp: StoredSFTPConfig` as `StoredSFTPConfig`. Neither matches the
    /// pattern, the surviving label set still equalled the four, and the guard
    /// passed -- on precisely the block the `ConnectionKind` switch cannot see
    /// either, so both totality mechanisms were blind to the same thing. An
    /// equality over ALL the labels is reddened by ANY new property, whatever
    /// it is named and whatever its type.
    ///
    /// (Withdrawn wording, verbatim: "Its positive companion is the assertion
    /// below that the four known labels are found at all, so a reflection that
    /// stopped seeing properties cannot pass by returning an empty set that
    /// happens to equal an empty expectation." The reason did not follow: the
    /// expectation it sat beside was an equality against four named labels, so
    /// an empty set already failed it -- and `fullSession()` populates all
    /// four blocks, so there was no nil-versus-populated case for it to be
    /// about. The positive checks below are kept for what they DO buy, stated
    /// at the call site. For the record, measured by the same re-review: a nil
    /// Optional property does reflect under its `Optional<…>` type, so a
    /// fixture leaving a block nil would not have hidden it either.)
    private func storedPropertyLabels() -> [String] {
        Mirror(reflecting: fullSession()).children.compactMap(\.label)
    }

    /// Measured sensitive in fix round 4 by the command below, whose plant is
    /// deliberately the shape the old pattern could NOT see --
    /// `String(describing:)` reports `Optional<PaneVisibility>`, which does
    /// not begin `Optional<Stored` -- and which printed `RESULT: RED — 1
    /// test(s) ran, and the plant was caught by:` this test:
    ///
    ///     scripts/mutation-probe --filter 'everyStoredPropertyIsAccountedFor' --apply "perl -pi -e 's{^    public var paneVisibility: PaneVisibility = .filesOnly\$}{    public var sftp: PaneVisibility? = nil\n    public var paneVisibility: PaneVisibility = .filesOnly}' Sources/macSCPCore/Sessions/StoredSession.swift"
    @Test func everyStoredPropertyIsAccountedFor() {
        let labels = storedPropertyLabels()
        // The positives beside the equality. First: the reflection sees
        // properties at all, so a Mirror that came back empty is not a pass.
        // Second: it still sees the four blocks under the labels the rest of
        // the project writes them by -- a block RENAMED rather than added
        // reddens the equality below as well, but this says which half moved.
        #expect(labels.isEmpty == false)
        #expect(Set(["ssh", "s3", "webdav", "ftp"]).isSubset(of: Set(labels)))
        #expect(labels == [
            "id", "name", "groupID", "position", "loginSetID", "kind",
            "ssh", "s3", "webdav", "ftp",
            "paneVisibility", "tags", "importSource", "importID", "importedAt",
        ], """
            `StoredSession` declares a stored property this rule has not been told about \
            (found: \(labels)). Classify it, then do one of two things.

            If it is a PER-BACKEND BLOCK, it has to be wired into ALL of these, and only \
            the first is checked by the compiler: the `switch` over `ConnectionKind` in \
            `StoredSession.clearBackendBlock(for:)` and `copyBackendBlock(for:from:)` \
            (so `SessionListViewModel.save` clears it on a kind change and \
            `SessionDuplication.copy` carries it), then `CodingKeys` and `init(from:)` \
            there, the memberwise `init`, the descriptor's `apply`, `sessionValues` and \
            `hasStoredConfiguration`, `SessionCatalog.target(for:)`, the overview facts, \
            and the export codec.

            If it is ANYTHING ELSE -- a fact about the session rather than about the \
            protocol it speaks, as `groupID`, `tags` and `paneVisibility` are -- nothing \
            above applies to it.

            Either way it then goes into the list here, in declaration order. This list is \
            deliberately every label and not a type-name pattern: a pattern cannot see a \
            block whose type is spelled differently, which is exactly the block the \
            `ConnectionKind` switch cannot see.
            """)
    }

    @Test func clearingEmptiesEveryBlockAndTouchesNothingElse() {
        var session = fullSession()
        session.tags = ["keep"]
        session.clearBackendBlocks()
        #expect(session.ssh == nil && session.s3 == nil && session.webdav == nil && session.ftp == nil)
        #expect(session.tags == ["keep"])
        #expect(session.name == "all")
    }

    @Test func copyingTakesEveryBlockFromTheOtherSession() {
        var target = StoredSession(name: "target", kind: .ftp)
        let source = fullSession()
        target.copyBackendBlocks(from: source)
        #expect(target.ssh == source.ssh)
        #expect(target.s3 == source.s3)
        #expect(target.webdav == source.webdav)
        #expect(target.ftp == source.ftp)
        #expect(target.name == "target")
        #expect(target.kind == .ftp)
    }
}
