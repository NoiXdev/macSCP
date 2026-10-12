import Testing
@testable import macSCPCore

@Suite struct ComparisonClassificationTests {
    private func pair(
        leftSize: UInt64?, rightSize: UInt64?,
        leftKind: RemoteFileKind = .file, rightKind: RemoteFileKind = .file
    ) -> ComparisonPair {
        ComparisonPair(
            name: "f",
            left: RemoteFileItem(
                name: "f", path: "/l/f", kind: leftKind, size: leftSize,
                modifiedAt: nil, permissions: nil, owner: nil, group: nil),
            right: RemoteFileItem(
                name: "f", path: "/r/f", kind: rightKind, size: rightSize,
                modifiedAt: nil, permissions: nil, owner: nil, group: nil))
    }

    /// `FileChecksum.init` is private and every factory returns an Optional,
    /// so this unwraps once, here, rather than at every call site.
    ///
    /// The factories accept only a digest of exactly the algorithm's length
    /// (`ChecksumAlgorithm.hexDigitCount`), so a short `seed` such as "aa" is
    /// repeated up to that length. Two different seeds stay different, two
    /// equal seeds stay equal, and an unpadded "aa" would make every
    /// `#require` below fail before the classification was reached.
    private func hash(
        _ seed: String, algorithm: ChecksumAlgorithm = .sha256
    ) throws -> @Sendable () async throws -> RemoteChecksumOutcome {
        let hex = String(repeating: seed, count: algorithm.hexDigitCount / seed.count)
        let value = try #require(FileChecksum.computedOnRemote(algorithm, hex: hex))
        return { .checksum(value) }
    }
    private func etag(_ raw: String) throws -> @Sendable () async throws -> RemoteChecksumOutcome {
        let value = try #require(FileChecksum.objectStorageETag(raw))
        return { .checksum(value) }
    }
    private let unavailable: @Sendable () async throws -> RemoteChecksumOutcome = {
        .unavailableOnThisConnection
    }

    @Test func differentSizesDifferWithoutAskingForAChecksum() async throws {
        let asked = Asked()
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 1, rightSize: 2),
            leftChecksum: { await asked.record(); return .unavailableOnThisConnection },
            rightChecksum: { await asked.record(); return .unavailableOnThisConnection })
        #expect(state == .differs)
        #expect(await asked.count == 0)
    }

    @Test func equalSizesAndEqualChecksumsAreTheSame() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa"), rightChecksum: hash("aa"))
        #expect(state == .same)
    }

    @Test func equalSizesAndDifferentChecksumsDiffer() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa"), rightChecksum: hash("bb"))
        #expect(state == .differs)
    }

    /// The spec's load-bearing case: WebDAV answers this for every file.
    @Test func equalSizesWithNoChecksumAvailableIsUndeterminedAndNeverSame() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa"), rightChecksum: unavailable)
        #expect(state == .undetermined(.checksumUnavailable))
        #expect(state != .same)
    }

    /// Review Focus 2: a missing size must not be read as a match.
    @Test func aMissingSizeFallsThroughToTheChecksumRatherThanMatching() async throws {
        let same = try await ComparisonClassification.state(
            for: pair(leftSize: nil, rightSize: nil),
            leftChecksum: hash("aa"), rightChecksum: hash("bb"))
        #expect(same == .differs)

        let unknown = try await ComparisonClassification.state(
            for: pair(leftSize: nil, rightSize: 7),
            leftChecksum: unavailable, rightChecksum: hash("aa"))
        #expect(unknown == .undetermined(.checksumUnavailable))
    }

    /// Review Focus 3.
    @Test func aSymlinkOnEitherSideIsItsOwnStateAndNotComparedByContent() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7, leftKind: .symlink),
            leftChecksum: hash("aa"), rightChecksum: hash("aa"))
        #expect(state == .undetermined(.unsupportedKind))

        // The right side, and against a kind that differs: a link may point
        // at exactly what the other side holds, so this is not a mismatch.
        let rightLink = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7, rightKind: .symlink),
            leftChecksum: hash("aa"), rightChecksum: hash("aa"))
        #expect(rightLink == .undetermined(.unsupportedKind))

        let linkAgainstFolder = try await ComparisonClassification.state(
            for: pair(leftSize: nil, rightSize: nil, leftKind: .directory, rightKind: .symlink),
            leftChecksum: unavailable, rightChecksum: unavailable)
        #expect(linkAgainstFolder == .undetermined(.unsupportedKind))

        let other = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7, rightKind: .other),
            leftChecksum: hash("aa"), rightChecksum: hash("aa"))
        #expect(other == .undetermined(.unsupportedKind))
    }

    @Test func aFolderAgainstAFileIsATypeMismatch() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: nil, rightSize: 7, leftKind: .directory),
            leftChecksum: unavailable, rightChecksum: hash("aa"))
        #expect(state == .typeMismatch)
    }

    /// Pre-flight finding F4, and the one a regression would make LIE.
    /// A multipart ETag is an MD5 over the parts' MD5s; two identical files
    /// uploaded with different part sizes carry different ones. Comparing it
    /// must never produce `differs`.
    @Test func aMultipartETagIsNeverComparedAndNeverReportsDiffers() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa"),
            rightChecksum: etag("\"d41d8cd98f00b204e9800998ecf8427e-3\""))
        #expect(state == .undetermined(.etagIsNotAFileHash))
        #expect(state != .differs)
        #expect(state != .same)
    }

    /// Pre-flight finding F4, the other half: a single-part ETag IS the
    /// file's MD5, but it is still MD5 where the other side computed sha256.
    @Test func twoDifferentAlgorithmsAreNotComparedByHex() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa", algorithm: .sha256),
            rightChecksum: hash("aa", algorithm: .sha1))
        #expect(state == .undetermined(.algorithmsDiffer))
    }

    /// The same algorithm on both sides is what makes each multipart check
    /// bite: the multipart ETag is MD5 like the other side's value, so
    /// without that check the pair would reach the hex compare and report
    /// `differs` for two files that may be identical. The value sits on
    /// the left in one order and on the right in the other, so deleting
    /// either side's check turns exactly one of these red.
    @Test func aMultipartETagOnEitherSideIsNeverComparedEvenAgainstTheSameAlgorithm() async throws {
        let multipart = "\"d41d8cd98f00b204e9800998ecf8427e-3\""
        let valueOnRight = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa", algorithm: .md5),
            rightChecksum: etag(multipart))
        #expect(valueOnRight == .undetermined(.etagIsNotAFileHash))

        let valueOnLeft = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: etag(multipart),
            rightChecksum: hash("aa", algorithm: .md5))
        #expect(valueOnLeft == .undetermined(.etagIsNotAFileHash))
    }

    /// The positive check beside the two `count == 0` assertions: `Asked`
    /// really does count, so those zeros mean something.
    @Test func equalSizesAskForBothChecksumsAndTheCounterSeesIt() async throws {
        let asked = Asked()
        let value = try #require(FileChecksum.computedOnRemote(.sha256, hex: String(repeating: "aa", count: 32)))
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: { await asked.record(); return .checksum(value) },
            rightChecksum: { await asked.record(); return .checksum(value) })
        #expect(state == .same)
        #expect(await asked.count == 2)
    }

    /// Pre-flight finding F2: the third outcome case carries its own reason,
    /// because the remedy differs — the user can change the algorithm.
    @Test func anUnavailableAlgorithmIsItsOwnReason() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: { .algorithmUnavailable(.sha1) },
            rightChecksum: hash("aa"))
        #expect(state == .undetermined(.algorithmUnavailable(.sha1)))
    }

    @Test func anUnavailableAlgorithmOnTheRightIsItsOwnReasonToo() async throws {
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: 7, rightSize: 7),
            leftChecksum: hash("aa"),
            rightChecksum: { .algorithmUnavailable(.md5) })
        #expect(state == .undetermined(.algorithmUnavailable(.md5)))
    }

    @Test func aPairPresentOnTheRightOnly() async throws {
        let onlyRight = ComparisonPair(
            name: "f",
            left: nil,
            right: RemoteFileItem(
                name: "f", path: "/r/f", kind: .file, size: 1,
                modifiedAt: nil, permissions: nil, owner: nil, group: nil))
        let state = try await ComparisonClassification.state(
            for: onlyRight, leftChecksum: unavailable, rightChecksum: unavailable)
        #expect(state == .onlyRight)
    }

    /// `.same` means two files whose contents were compared and matched, and
    /// nothing else. A folder pair has no content to measure here, so it is
    /// its own state; reporting it as `.same` would show a match nobody made.
    @Test func aFolderPairIsBothDirectoriesAndNeverSame() async throws {
        let asked = Asked()
        let state = try await ComparisonClassification.state(
            for: pair(leftSize: nil, rightSize: nil, leftKind: .directory, rightKind: .directory),
            leftChecksum: { await asked.record(); return .unavailableOnThisConnection },
            rightChecksum: { await asked.record(); return .unavailableOnThisConnection })
        #expect(state == .bothDirectories)
        #expect(state != .same)
        #expect(await asked.count == 0)
    }

    @Test func aPairPresentOnOneSideOnly() async throws {
        let onlyLeft = ComparisonPair(
            name: "f",
            left: RemoteFileItem(
                name: "f", path: "/l/f", kind: .file, size: 1,
                modifiedAt: nil, permissions: nil, owner: nil, group: nil),
            right: nil)
        let state = try await ComparisonClassification.state(
            for: onlyLeft, leftChecksum: unavailable, rightChecksum: unavailable)
        #expect(state == .onlyLeft)
    }
}

/// Counts how many times a checksum was asked for. An actor, so the test
/// never blocks the cooperative pool to read it.
private actor Asked {
    private(set) var count = 0
    func record() { count += 1 }
}
