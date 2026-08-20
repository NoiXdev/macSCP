import Foundation

/// Escaping text that goes into an XML element this project BUILDS.
///
/// Two request bodies are assembled as strings rather than by a serializer —
/// `DeleteObjects` (`S3FileSystem`) and `CompleteMultipartUpload`
/// (`S3MultipartXML`) — and both interpolate values this process did not
/// author: an object key comes from a listing, an ETag comes from the
/// server's `UploadPart` response header. Interpolating either into `<Key>`
/// or `<ETag>` unescaped lets a `<` or a `&` change the shape of the
/// document, so a name like `a&b.txt` is enough to produce a body S3 either
/// rejects or reads as something other than what was meant.
///
/// It lives here rather than as a private helper in one of the two because
/// it WAS a private helper in one of the two: the other interpolated its
/// value with no escaping at all, and a rule that exists in one copy is a
/// rule half the call sites do not follow.
enum S3XMLText {
    /// `string` with the five XML predefined entities replaced.
    ///
    /// One pass over `Unicode.Scalar`s, deliberately not a chain of
    /// `replacingOccurrences` calls. Two reasons, and the second is the one
    /// that made this worth writing this way: chained replacement has to
    /// order `&` first or it re-escapes the ampersands the later
    /// replacements introduce (a correctness trap that only ordering
    /// hides), and `replacingOccurrences` matches on extended grapheme
    /// clusters, so a value holding `&` or `<` followed by a combining mark
    /// is not an occurrence to it and goes into the request body unescaped.
    /// Deciding one scalar at a time has neither problem: the `default` arm
    /// appends the scalar unchanged, so nothing this produces is re-read.
    ///
    /// Escaping is transparent to the receiver — an XML parser turns
    /// `&quot;` back into `"` — so it does not break S3's byte-for-byte
    /// comparison of an ETag against what it stored.
    ///
    /// ## Why a control character is a refusal and not an escape
    ///
    /// XML 1.0 admits, below U+0020, only tab, line feed and carriage
    /// return; U+FFFE and U+FFFF are out too. There is no way to carry the
    /// others: a numeric reference to a forbidden character is forbidden as
    /// well. Measured, a value holding U+0001 produced a document a real
    /// `XMLParser` rejected outright — so passing one through builds a
    /// request no receiver can read.
    ///
    /// Dropping the character would produce a well-formed document and is
    /// the worse answer, which is why it is not the one taken here. These
    /// values are identities that have to match byte-for-byte: `a\u{1}b.txt`
    /// with the control removed is `ab.txt`, and `ab.txt` may well be a
    /// DIFFERENT object in the same bucket. A `DeleteObjects` body would
    /// then name a real object nobody asked to delete. Refusing turns an
    /// unrepresentable value into a failed request, which is what it
    /// already was.
    static func escaped(_ string: String) throws -> String {
        var escaped = ""
        escaped.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            guard isRepresentableInXML(scalar) else {
                // The reason names no value: an object key can be anything a
                // user typed into a rename field, and a reason string
                // reaches logs and error banners.
                throw RemoteFSError.protocolError(
                    reason: "S3 request body: a value contains a character XML cannot carry")
            }
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// The XML 1.0 `Char` production, decided one scalar at a time.
    /// Surrogates need no arm: `Unicode.Scalar` cannot hold one.
    private static func isRepresentableInXML(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: return true
        case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }
}
