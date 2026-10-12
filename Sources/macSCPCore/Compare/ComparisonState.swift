import Foundation

/// Why a pair could not be settled. Carried in the state rather than shown
/// in a note above the table: a row that says "same" when nothing measured
/// it is the defect this type exists to prevent.
public enum UndeterminedReason: Equatable, Sendable {
    /// Neither side could produce a checksum. An SSH far side with no
    /// checksum tool answers this; so does every WebDAV connection; and so
    /// does a backend that is not a `RemoteChecksumProvider` at all.
    case checksumUnavailable
    /// The connection can hash, but not with the algorithm that was asked
    /// for. A different reason from the one above, and a different remedy:
    /// the user can change `SettingsStore.checksumAlgorithm`.
    case algorithmUnavailable(ChecksumAlgorithm)
    /// The two sides answered with DIFFERENT algorithms, so their hexes say
    /// nothing about each other.
    case algorithmsDiffer
    /// One side's value is an object store's multipart ETag, which is an
    /// MD5 over the parts' MD5s and not a hash of the file's bytes at all.
    /// Comparing it to anything would be meaningless.
    case etagIsNotAFileHash
    /// A symlink or an `other` entry: no content comparison is meaningful.
    case unsupportedKind
}

public enum ComparisonState: Equatable, Sendable {
    case onlyLeft
    case onlyRight
    /// Two files whose contents were compared and matched. This is the only
    /// meaning of `same`: a state nobody measured is never reported as it.
    case same
    case differs
    /// Both sides hold a directory at this path. Nothing about their
    /// contents has been measured, so this is NOT a match; the walk descends
    /// into the pair and reports its children rather than the pair itself.
    case bothDirectories
    case typeMismatch
    case undetermined(UndeterminedReason)
}

public enum ComparisonClassification {
    /// Classifies one pair.
    ///
    /// Order matters and is the cheap half of the design: a size difference
    /// settles the pair with no checksum at all. A checksum is asked for
    /// only where the sizes are EQUAL AND KNOWN — a `nil` size says the
    /// listing could not tell us, which is not the same as a match, so it
    /// falls through to the checksum rather than settling anything.
    public static func state(
        for pair: ComparisonPair,
        leftChecksum: @Sendable () async throws -> RemoteChecksumOutcome,
        rightChecksum: @Sendable () async throws -> RemoteChecksumOutcome
    ) async throws -> ComparisonState {
        guard let left = pair.left else { return .onlyRight }
        guard let right = pair.right else { return .onlyLeft }

        // A symlink or an `other` entry on EITHER side is settled before the
        // kinds are compared. A link may point at exactly the kind of thing
        // the other side holds, so "the types differ" would be a claim this
        // listing cannot back; no content comparison is meaningful either.
        if isUnsupported(left.kind) || isUnsupported(right.kind) {
            return .undetermined(.unsupportedKind)
        }
        if left.kind != right.kind { return .typeMismatch }
        if left.kind == .directory { return .bothDirectories }

        if let l = left.size, let r = right.size, l != r { return .differs }

        let a: FileChecksum
        switch try await leftChecksum() {
        case .checksum(let value): a = value
        case .unavailableOnThisConnection: return .undetermined(.checksumUnavailable)
        case .algorithmUnavailable(let algorithm):
            return .undetermined(.algorithmUnavailable(algorithm))
        }

        let b: FileChecksum
        switch try await rightChecksum() {
        case .checksum(let value): b = value
        case .unavailableOnThisConnection: return .undetermined(.checksumUnavailable)
        case .algorithmUnavailable(let algorithm):
            return .undetermined(.algorithmUnavailable(algorithm))
        }

        // A multipart ETag is "an MD5 over the parts' MD5s. Not the file's
        // hash, whatever it looks like" — `ChecksumProvenance`'s own words.
        // Two identical files can carry different multipart ETags (different
        // part sizes) and two different files could in principle carry the
        // same one, so this value settles nothing in either direction.
        if case .objectStorageETagMultipart = a.provenance {
            return .undetermined(.etagIsNotAFileHash)
        }
        if case .objectStorageETagMultipart = b.provenance {
            return .undetermined(.etagIsNotAFileHash)
        }

        // Two hexes from different algorithms say nothing about each other.
        // An S3 side answers with `.md5` from its ETag while a local side
        // computes the user's chosen algorithm, so this is the ordinary
        // case for a local↔S3 pair, not a corner.
        guard a.algorithm == b.algorithm else {
            return .undetermined(.algorithmsDiffer)
        }

        return a.hex == b.hex ? .same : .differs
    }

    private static func isUnsupported(_ kind: RemoteFileKind) -> Bool {
        kind == .symlink || kind == .other
    }
}
