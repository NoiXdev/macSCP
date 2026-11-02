import Crypto
import Foundation

/// What a downloaded old version is called on disk: the object's own file name
/// with the version's id folded in BEFORE the extension, so two versions of
/// one key can sit side by side and each still opens with the right
/// application. A lower-case, UUID-shaped id (the test rig's shape) is shown
/// as it is: `doc (3f2c9a10-0b7e-4c1d).txt`. An id with upper case, `+`, `/` or
/// anything else outside the whitelist below (a real AWS version id is mixed
/// case, so it always takes this path) is digested:
/// `doc (3HL4kqtJvjVB~4ce1d782d7517756).txt` for the id
/// `3HL4kqtJvjVBH40Nrjfkd`, the readable part being the id's first twelve
/// permitted characters.
///
/// **A version id is opaque text the store supplied.** Nothing here may assume
/// it is a path-safe token: it is cut into a file name, so it is held to a
/// WHITELIST and a length, not screened for the one separator somebody
/// thought of. The id is used verbatim only when it is already inside the
/// whitelist; anything else is represented by what survives of its start plus
/// a digest of the WHOLE id (`~` and 16 hex digits), so
/// - two ids that sanitize to the same readable text still get different names
///   (the digest sees the bytes the readable part dropped), which is the
///   collision this type exists to prevent arriving through the sanitizer
///   instead of through the id. What distinguishes two digested ids is the
///   first 16 hex digits (64 bits) of the SHA-256 of the WHOLE id, nothing
///   more: a collision between two ids of one key is possible in principle
///   and not a practical concern, and it is not excluded structurally;
/// - the digest marker `~` is outside the whitelist, so a verbatim id can
///   never equal a digested one's tag;
/// - the verbatim whitelist is lower-case only, so two ids that differ only in
///   case (distinct to a store, one name to a default APFS volume) cannot both
///   pass through; the digested form differs in its hex either way.
///
/// The suffix goes before the extension, an extension being what follows the
/// last dot of a name that has a stem before it (`.bashrc` has none). When the
/// result would overflow a path component (255 bytes on APFS) the STEM gives
/// way, cut at a character boundary; the extension and the id's tag are kept.
///
/// `fileName` is not sanitized: it is a listing's file name and every
/// download already trusts those. It is only shortened if it must be.
public enum VersionLocalName {
    /// The longest file name APFS accepts, in bytes of UTF-8. A path component
    /// is bounded in bytes, not characters.
    public static let maxComponentBytes = 255

    /// A verbatim tag is at most this many characters; a UUID is 36.
    private static let maxVerbatimCharacters = 40
    /// How much of an unsafe id's start survives into the readable part.
    private static let readableCharacters = 12
    /// Hex digits of the digest of the whole id: 64 bits.
    private static let digestHexDigits = 16
    /// An extension longer than this is not treated as one: the name is cut as
    /// a whole instead, so a hostile tail cannot take the room the tag needs.
    private static let maxExtensionBytes = 64

    public static func forDownload(fileName: String, versionId: String) -> String {
        let tag = tag(for: versionId)
        let (stem, ext) = split(fileName)
        let affix = " (\(tag))"
        let room = maxComponentBytes - affix.utf8.count - ext.utf8.count
        return shortened(stem, toBytes: room) + affix + ext
    }

    // MARK: - The tag

    private static func tag(for versionId: String) -> String {
        if isVerbatim(versionId) { return versionId }
        let readable = String(versionId.unicodeScalars.lazy.filter(isReadable).prefix(readableCharacters).map(Character.init))
        let digest = SHA256.hash(data: Data(versionId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(digestHexDigits)
        return readable + "~" + digest
    }

    /// `a-z`, `0-9`, `-` and `_` only. No dot (so no `..` and no leading dot
    /// is possible in the tag), no separator, no control character, no
    /// upper case, nothing outside ASCII.
    private static func isVerbatim(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.count <= maxVerbatimCharacters
            && id.unicodeScalars.allSatisfy { isLowerCaseSafe($0) }
    }

    private static func isLowerCaseSafe(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
    }

    /// What may appear in the readable part of a digested tag: the verbatim
    /// set plus upper case. Case is kept here because it is only legibility;
    /// the digest carries the identity.
    private static func isReadable(_ scalar: Unicode.Scalar) -> Bool {
        isLowerCaseSafe(scalar) || (scalar >= "A" && scalar <= "Z")
    }

    // MARK: - The name

    /// `fileName` as (stem, extension-with-its-dot). A dot at the start is no
    /// extension (`.bashrc`), a name with no dot has none, and a tail longer
    /// than `maxExtensionBytes` is part of the stem.
    private static func split(_ fileName: String) -> (stem: String, ext: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, "")
        }
        let ext = String(fileName[dot...])
        guard ext.utf8.count <= maxExtensionBytes else { return (fileName, "") }
        return (String(fileName[..<dot]), ext)
    }

    /// `text` cut from the end, a whole character at a time, until it fits
    /// `bytes` bytes of UTF-8.
    private static func shortened(_ text: String, toBytes bytes: Int) -> String {
        var result = text
        while result.utf8.count > bytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}
