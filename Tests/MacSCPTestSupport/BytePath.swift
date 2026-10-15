/// A path used as a dictionary key by its UTF-8 BYTES, not as a `String`.
///
/// **Why a test fake must not key on `String`.** Swift's `String` equality and
/// hashing are Unicode canonical equivalence: `"su\u{0308}b"` (NFD) and
/// `"s\u{00FC}b"` (NFC) are `==` and hash alike, so a `[String: Data]` fixture
/// answers an NFD lookup from its NFC entry and a `Set<String>` of paths
/// cannot hold both. A real backend does no such thing — it keys on the bytes
/// it was given, and a path in the wrong normalization form is simply not
/// there. A fake that folds the two forms together therefore CANNOT fail for
/// a path built out of the wrong side's spelling, which is the one defect the
/// comparison subsystem's two-pass pairing makes possible.
///
/// Measured 2026-10-15, on the diff-view branch: `FolderComparison.walk` built
/// one relative path from the LEFT side's name and joined it to both roots, so
/// a pair only the NFC pass could make was descended with a spelling the right
/// side does not have. Every test in the tree was green, because both fakes
/// keyed on `String`. The same fakes keyed on bytes turn the defect red at
/// once.
///
/// So this type exists to make a lookup across normalization forms impossible
/// to write. `ExpressibleByStringLiteral` keeps every dictionary literal in a
/// fixture spelled as it was; a lookup from a `String` the code under test
/// built has to say `BytePath(path)`, which is the conversion at the boundary
/// and the only place it happens.
public struct BytePath: Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    /// The path as it was spelled, for a message or a `RemoteFileItem`.
    public let path: String
    private let bytes: [UInt8]

    public init(_ path: String) {
        self.path = path
        self.bytes = Array(path.utf8)
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public static func == (lhs: BytePath, rhs: BytePath) -> Bool {
        lhs.bytes == rhs.bytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }

    public var description: String { path }
}
