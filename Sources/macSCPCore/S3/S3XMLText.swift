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
    static func escaped(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
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
}
