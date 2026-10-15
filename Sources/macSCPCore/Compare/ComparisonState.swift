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
    /// A symlink on either side. A link's content is its target path, so
    /// comparing the bytes of what a fetch returns would answer a different
    /// question from the one the row asks, and the row is not settled by it.
    ///
    /// This case and the next one used to be one, `unsupportedKind`, whose
    /// comment read "A symlink or an `other` entry: no content comparison is
    /// meaningful." That is true of a link and false of an entry whose type
    /// was not reported, which is what `.other` is when a listing carries no
    /// type at all.
    case linkOnASide
    /// An `other` entry on a side and no symlink on either. `.other` is what a
    /// listing answers for a special file, and ALSO for an entry whose type it
    /// did not report (a server whose listing carries no permission bits, a
    /// network file system that does not populate `d_type`), so an ordinary
    /// file can land here. Unlike a link, a fetch can answer it.
    case kindNotReported
    /// Listing a directory, or classifying a pair, threw. The walk reports the
    /// path with this reason and carries on, because one unreadable directory
    /// must not discard the rest of the comparison; the row names the path, so
    /// nothing is hidden. A cancel is never reported this way: it ends the
    /// walk. The ROOT of either side is not covered either — with a chosen
    /// folder unreadable there is nothing to compare, and the walk throws.
    case unreadable
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
        // listing cannot back.
        //
        // The comment here used to end "no content comparison is meaningful
        // either". That is true of a link, whose content is its target path,
        // and false of `.other`, which is also what a listing answers when a
        // type was not reported at all: for that one a fetch can answer, and
        // the two reasons say which is which. A link is the stronger claim, so
        // it is checked first and wins when the other side is `.other`.
        if left.kind == .symlink || right.kind == .symlink {
            return .undetermined(.linkOnASide)
        }
        if left.kind == .other || right.kind == .other {
            return .undetermined(.kindNotReported)
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
}
