import Foundation

/// Puts a custom S3 metadata value on the wire as pure ASCII and reads it
/// back, using RFC 2047 encoded words. An `x-amz-meta-*` header value may
/// carry only ASCII: a raw non-ASCII byte makes the request signature
/// disagree between client and store, and the store answers
/// `SignatureDoesNotMatch`.
///
/// What is known about stores. AWS's documentation says the service returns a
/// non-ASCII user-defined metadata value RFC 2047-encoded; that is a reading
/// of the documentation and was not measured here. What was measured, on the
/// rig's RustFS 1.0.4 on 2026-11-04 and 2026-11-10: a value written as raw
/// UTF-8 bytes by another tool is reported back as an encoded word. No client
/// tool's behaviour is claimed.
///
/// Both functions are **total**: neither throws and neither returns `nil`. A
/// codec that threw would push a decision about malformed input into every
/// caller, and the decision is already made here: leave it alone.
///
/// Not applied, deliberately: RFC 2047's 75-character limit on one encoded
/// word. A long value is written as ONE word of any length. No store has been
/// measured to care. The decoder, for its part, accepts adjacent words, so a
/// value that another tool split into several still reads as one string.
enum RFC2047 {
    /// The wire form of one value.
    ///
    /// A value is encoded, as ONE `UTF-8` / `B` (base64) word, when it
    /// contains a non-ASCII unicode scalar **or** the two-character sequence
    /// equals sign followed by question mark. Every other value, including
    /// the empty string and one made only of whitespace, is returned
    /// unchanged.
    ///
    /// The second condition is the reason this is not simply "encode what is
    /// not ASCII". An ASCII value that is itself spelled like an encoded word
    /// would otherwise go out as it is, and `decoded(_:)` would turn it into
    /// the text it carries instead of returning what the person typed. Such a
    /// value is encoded, so the word the decoder sees on the way back is the
    /// outer one and the typed text inside it is read as text.
    static func encodedWord(_ value: String) -> String {
        let needsEncoding = value.unicodeScalars.contains { $0.value >= 0x80 }
            || value.contains("=?")
        guard needsEncoding else { return value }
        return "=?UTF-8?B?" + Data(value.utf8).base64EncodedString() + "?="
    }

    /// Reads a value as a store answered it.
    ///
    /// A run bracketed as an encoded word (charset, encoding and text, each
    /// ended by a question mark) is decoded when its charset is UTF-8
    /// (compared without regard to case), its encoding is `B` (base64) or `Q`
    /// (quoted-printable, where an underscore means a space; compared without
    /// regard to case) and its payload decodes to valid UTF-8. A run that
    /// fails any of those tests is left exactly as it stands, character for
    /// character, and so is everything outside a word: text that is not an
    /// encoded word is passed through unchanged.
    ///
    /// The input is a `String`, which the transport has already made from the
    /// header's bytes. How `URLSession` makes it from raw non-ASCII bytes
    /// (UTF-8 or another charset) is unmeasured, so whether a store's raw
    /// header reaches this function as the text the store kept is unmeasured
    /// too.
    ///
    /// A leading U+FEFF in a decoded word is kept as text, not stripped as a
    /// byte-order mark.
    ///
    /// Whitespace between two adjacent decoded words is dropped (RFC 2047
    /// section 6.2). Text between two words, and whitespace beside a run that
    /// was not decoded, is kept verbatim.
    static func decoded(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        var heldGap = String.UnicodeScalarView()
        var afterWord = false
        var index = 0

        while index < scalars.count {
            if let word = word(in: scalars, at: index) {
                if !afterWord { output.append(contentsOf: heldGap) }
                heldGap.removeAll()
                output.append(contentsOf: word.text.unicodeScalars)
                afterWord = true
                index = word.end
                continue
            }
            let scalar = scalars[index]
            if afterWord, isGap(scalar) {
                heldGap.append(scalar)
            } else {
                output.append(contentsOf: heldGap)
                heldGap.removeAll()
                output.append(scalar)
                afterWord = false
            }
            index += 1
        }
        output.append(contentsOf: heldGap)
        return String(output)
    }

    private static func isGap(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
    }

    /// One encoded word starting exactly at `start`, or `nil` when what stands
    /// there is not a word this codec reads. `end` is the index just past it.
    private static func word(
        in scalars: [Unicode.Scalar], at start: Int
    ) -> (text: String, end: Int)? {
        guard start + 1 < scalars.count,
            scalars[start] == "=", scalars[start + 1] == "?"
        else { return nil }

        // Three fields, each ended by a question mark, then "?=" closes the
        // word. No field may hold whitespace or a question mark, so a word
        // can never swallow text that follows it.
        var fields: [[Unicode.Scalar]] = []
        var cursor = start + 2
        var current: [Unicode.Scalar] = []
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == "?" {
                if fields.count == 2 {
                    guard cursor + 1 < scalars.count, scalars[cursor + 1] == "=" else {
                        return nil
                    }
                    fields.append(current)
                    cursor += 2
                    break
                }
                fields.append(current)
                current = []
            } else if isGap(scalar) || scalar.value >= 0x80 {
                return nil
            } else {
                current.append(scalar)
            }
            cursor += 1
        }
        guard fields.count == 3 else { return nil }

        let charset = String(String.UnicodeScalarView(fields[0]))
        let encoding = String(String.UnicodeScalarView(fields[1]))
        let payload = fields[2]
        guard charset.lowercased() == "utf-8", !payload.isEmpty else { return nil }

        let bytes: Data?
        switch encoding.lowercased() {
        case "b": bytes = Data(base64Encoded: String(String.UnicodeScalarView(payload)))
        case "q": bytes = qDecoded(payload)
        default: bytes = nil
        }
        // Not `String(data:encoding:)`: that strips a leading U+FEFF as a
        // byte-order mark, and the read-back would then disagree with a
        // value that starts with one.
        guard let bytes, let text = String(validating: bytes, as: UTF8.self) else { return nil }
        return (text, cursor)
    }

    /// Quoted-printable as RFC 2047 section 4.2 uses it: `=XX` is one byte,
    /// an underscore is a space, any other scalar stands for itself. A `=`
    /// not followed by two hex digits makes the whole payload undecodable.
    private static func qDecoded(_ payload: [Unicode.Scalar]) -> Data? {
        var bytes = Data()
        var index = 0
        while index < payload.count {
            let scalar = payload[index]
            if scalar == "=" {
                guard index + 2 < payload.count,
                    let high = hexValue(payload[index + 1]),
                    let low = hexValue(payload[index + 2])
                else { return nil }
                bytes.append(UInt8(high << 4 | low))
                index += 3
            } else if scalar == "_" {
                bytes.append(0x20)
                index += 1
            } else {
                bytes.append(UInt8(scalar.value))
                index += 1
            }
        }
        return bytes
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: UInt8(scalar.value - 0x30)
        case 0x41...0x46: UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: UInt8(scalar.value - 0x61 + 10)
        default: nil
        }
    }
}
