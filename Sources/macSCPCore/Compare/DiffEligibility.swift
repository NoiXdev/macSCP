/// Why one side's content cannot be shown as a line diff.
///
/// This refuses the CONTENT diff only. The folder comparison does not consult
/// it: a binary or oversized pair is still classified by size and checksum,
/// and telling the user that two binaries differ is exactly what that is for.
public enum DiffRefusal: Equatable, Sendable {
    /// The first `DiffEligibility.nulWindowBytes` bytes contain a NUL. This
    /// case carries that one cause and nothing else: content that is merely
    /// not valid UTF-8 is `.notUTF8`, because a Latin-1 or Windows-1252 text
    /// file is text and must not be described to the user as binary.
    case binary
    /// The content is not valid UTF-8 and has no NUL in the leading window:
    /// typically text in another encoding, but this case does not claim to
    /// know which. It says only that the bytes cannot be read as UTF-8 lines.
    case notUTF8
    /// The content is larger than `ceiling` bytes. See
    /// `DiffEligibility.ceilingBytes` for what that bound does and does not
    /// bound.
    case tooLarge(bytes: Int, ceiling: Int)
}

public enum DiffEligibility {
    /// 4 MiB per side.
    ///
    /// **A STARTING VALUE, NOT A MEASUREMENT.** Nothing in this tree set a
    /// precedent for it, and a line diff's cost is dominated by the number
    /// of DIFFERENCES rather than by the file size, so this number is
    /// expected to move once the plan's own measurement exists. Until then,
    /// no comment, document or catalogue text here describes it as measured.
    ///
    /// It bounds the BYTES of one side. It does NOT bound the diff's working
    /// table: that table grows with the PRODUCT of the two line counts, and
    /// a side made of very short lines has many lines for its bytes:
    /// 2,097,152 lines of one byte and a newline fit within 4 MiB, and two
    /// such sides give a table of 4,398,050,705,409 entries. The bound that
    /// does limit the table belongs to Task 6, not to this constant.
    public static let ceilingBytes = 4 * 1024 * 1024

    /// How many leading bytes are searched for a NUL. This is git's own
    /// heuristic, adopted by name rather than invented here.
    static let nulWindowBytes = 8000

    /// Why this content cannot be shown as a line diff, or `nil` when it can.
    ///
    /// The checks run in this order, and the first to fire decides:
    ///
    /// 1. **Size.** An oversized file reports `.tooLarge` even when it is also
    ///    binary. The size is the cheaper fact (no byte is read to learn it),
    ///    it is the one the user can act on, and it keeps a huge buffer from
    ///    being scanned at all.
    /// 2. **A NUL byte** in the first `nulWindowBytes` bytes, reported as
    ///    `.binary`. A NUL later in the file does not make it binary by this
    ///    rule; it is valid UTF-8 and the third check lets it through.
    /// 3. **Not valid UTF-8**, anywhere in the content, reported as
    ///    `.notUTF8` and not as `.binary`. This is strict: a lone
    ///    continuation byte, a sequence cut off at the end of the buffer, an
    ///    overlong encoding and a surrogate half are all refused. A byte
    ///    order mark is valid and is not refused. Content with both a
    ///    leading NUL and invalid bytes is `.binary`, by the order.
    ///
    /// An empty buffer is eligible.
    public static func refusal(forBytes bytes: [UInt8]) -> DiffRefusal? {
        if bytes.count > ceilingBytes {
            return .tooLarge(bytes: bytes.count, ceiling: ceilingBytes)
        }
        if bytes.prefix(nulWindowBytes).contains(0x00) { return .binary }
        if String(validating: bytes, as: UTF8.self) == nil { return .notUTF8 }
        return nil
    }
}
