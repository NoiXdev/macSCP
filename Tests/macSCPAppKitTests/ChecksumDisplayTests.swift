import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What the surface SAYS for each answer a backend can give.
///
/// This is the whole decidable part of the display, extracted so it can be
/// read without a view: `ChecksumDisplay.of(_:)` is a pure function from
/// one `ChecksumRequestResult` to the three pieces of text a row shows.
///
/// The value under test is the one the design hangs on. An object store's
/// multipart ETag is a well-formed MD5 that is not the file's hash, and it
/// turns up on exactly the large files someone wants to check. Its
/// qualification is therefore compared against the single-part one
/// DIRECTLY, rather than against a catalogue string: a check that only
/// asserted "some text is there" would stay green if both cases produced
/// the same sentence, which is precisely the lie this feature exists to
/// prevent.
@Suite("Checksum display")
struct ChecksumDisplayTests {
    private static let sha256Hex = String(repeating: "a", count: 64)
    private static let md5Hex = String(repeating: "b", count: 32)

    private static func remote() throws -> FileChecksum {
        try #require(FileChecksum.computedOnRemote(.sha256, hex: sha256Hex))
    }
    private static func local() throws -> FileChecksum {
        try #require(FileChecksum.computedLocally(.sha256, hex: sha256Hex))
    }
    private static func singlePartETag() throws -> FileChecksum {
        try #require(FileChecksum.objectStorageETag("\"\(md5Hex)\""))
    }
    private static func multipartETag() throws -> FileChecksum {
        try #require(FileChecksum.objectStorageETag("\"\(md5Hex)-3\""))
    }

    // MARK: - The digest itself

    /// Whatever the origin, the value line is the digest and nothing else:
    /// it is what somebody copies out to compare, so no prefix, no label
    /// and no ellipsis may end up in it.
    @Test func theValueLineIsTheBareDigest() throws {
        #expect(ChecksumDisplay.of(.checksum(try Self.remote())).value == Self.sha256Hex)
        #expect(ChecksumDisplay.of(.checksum(try Self.local())).value == Self.sha256Hex)
        #expect(ChecksumDisplay.of(.checksum(try Self.singlePartETag())).value == Self.md5Hex)
        #expect(ChecksumDisplay.of(.checksum(try Self.multipartETag())).value == Self.md5Hex)
    }

    /// Every digest is qualified. A value that arrived with no statement
    /// about where it came from is the state this whole feature exists to
    /// make impossible.
    @Test func everyDigestCarriesAQualification() throws {
        for checksum in [
            try Self.remote(), try Self.local(),
            try Self.singlePartETag(), try Self.multipartETag(),
        ] {
            let display = ChecksumDisplay.of(.checksum(checksum))
            #expect(!display.qualification.isEmpty, """
                a digest with provenance \(checksum.provenance) reached the display with \
                nothing said about where it came from
                """)
        }
    }

    /// The algorithm is named beside the digest, and it is the value's own
    /// — not the one that was asked for. S3 substitutes MD5 for a SHA-256
    /// request, and the substitution is only honest if the label follows
    /// the value.
    @Test func theQualificationNamesTheAlgorithmTheValueActuallyHas() throws {
        #expect(ChecksumDisplay.of(.checksum(try Self.remote()))
            .qualification.contains(ChecksumAlgorithm.sha256.displayName))
        #expect(ChecksumDisplay.of(.checksum(try Self.singlePartETag()))
            .qualification.contains(ChecksumAlgorithm.md5.displayName))
        #expect(ChecksumDisplay.of(.checksum(try Self.multipartETag()))
            .qualification.contains(ChecksumAlgorithm.md5.displayName))
    }

    // MARK: - The four origins are four different sentences

    /// Computed on the far side, computed here, and read off an ETag are
    /// three different facts about a value, and each gets its own sentence
    /// — otherwise "where did this come from" is answered by a shrug.
    @Test func theThreeOriginsThatDescribeContentAreStillDistinguishable() throws {
        let sentences = [
            ChecksumDisplay.of(.checksum(try Self.remote())).qualification,
            ChecksumDisplay.of(.checksum(try Self.local())).qualification,
            ChecksumDisplay.of(.checksum(try Self.singlePartETag())).qualification,
        ]
        #expect(Set(sentences).count == sentences.count, """
            two different origins produced the same sentence: \(sentences)
            """)
    }

    /// **The central one.** A multipart ETag must not read like a file
    /// hash. Compared against the single-part sentence rather than against
    /// a catalogue key, so no rewording of either can make them collapse
    /// into one without this failing.
    @Test func aMultipartETagIsSaidDifferentlyFromAFileHash() throws {
        let multipart = ChecksumDisplay.of(.checksum(try Self.multipartETag()))
        let singlePart = ChecksumDisplay.of(.checksum(try Self.singlePartETag()))

        #expect(multipart.qualification != singlePart.qualification, """
            a multipart ETag was qualified exactly like an ETag that IS the object's MD5. \
            The two hexes are indistinguishable by eye; the sentence beside them is the \
            only thing that says one of them will never match the file's checksum.
            """)
        #expect(multipart.severity == .caution)
        #expect(singlePart.severity == .plain)
    }

    /// The severity follows the value's own account of itself, so a
    /// fourth provenance added later cannot land on `.plain` by omission.
    @Test func severityFollowsWhetherTheValueDescribesTheFile() throws {
        for checksum in [try Self.remote(), try Self.local(), try Self.singlePartETag()] {
            #expect(checksum.describesFileContent)
            #expect(ChecksumDisplay.of(.checksum(checksum)).severity == .plain)
        }
        let multipart = try Self.multipartETag()
        #expect(!multipart.describesFileContent)
        #expect(ChecksumDisplay.of(.checksum(multipart)).severity == .caution)
    }

    // MARK: - The answers that are not digests

    /// "This server does not provide checksums" is an answer, so it stands
    /// where the digest would stand — plainly, not as an error.
    @Test func aConnectionThatCannotAnswerSaysSoInPlaceOfTheDigest() {
        let display = ChecksumDisplay.of(.unavailableOnThisConnection)

        #expect(display.value == L10n.string("checksum.unavailable", "ZZ-UNRESOLVED-ZZ"))
        #expect(display.value != "ZZ-UNRESOLVED-ZZ")
        #expect(display.qualification.isEmpty)
        #expect(display.severity == .plain)
    }

    /// A failure about one file is a failure: it reads as one, and it does
    /// not claim the connection has no checksums at all.
    @Test func aFailureAboutOneFileReadsAsAFailure() {
        let display = ChecksumDisplay.of(.failed("the far side answered nothing"))

        #expect(display.value.contains("the far side answered nothing"))
        #expect(display.severity == .failure)
        #expect(display.value != ChecksumDisplay.of(.unavailableOnThisConnection).value)
    }

    /// The algorithm names are the standards' own spelling and are
    /// deliberately not localized — "SHA-256" is a name, like "KB/s"
    /// elsewhere in this app, and translating it would make a published
    /// figure harder to compare against, not easier.
    @Test func theAlgorithmNamesAreTheStandardsOwnSpelling() {
        #expect(ChecksumAlgorithm.sha256.displayName == "SHA-256")
        #expect(ChecksumAlgorithm.sha1.displayName == "SHA-1")
        #expect(ChecksumAlgorithm.md5.displayName == "MD5")
    }
}
