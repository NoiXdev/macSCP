/// Why one side's content cannot be shown as a line diff.
///
/// This refuses the CONTENT diff only. The folder comparison does not consult
/// it: a binary or oversized pair is still classified by size and checksum,
/// and telling the user that two binaries differ is exactly what that is for.
public enum DiffRefusal: Equatable, Sendable {
    case binary
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
    /// It bounds a single side because the diff's working table grows with
    /// the PRODUCT of the two line counts, so each side is limited on its own
    /// before the two are ever combined.
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
    /// 2. **A NUL byte** in the first `nulWindowBytes` bytes. A NUL later in
    ///    the file does not make it binary by this rule; it is valid UTF-8
    ///    and the third check lets it through.
    /// 3. **Not valid UTF-8**, anywhere in the content. This is strict: a
    ///    lone continuation byte, a sequence cut off at the end of the
    ///    buffer, an overlong encoding and a surrogate half are all refused.
    ///    A byte order mark is valid and is not refused.
    ///
    /// An empty buffer is eligible.
    public static func refusal(forBytes bytes: [UInt8]) -> DiffRefusal? {
        if bytes.count > ceilingBytes {
            return .tooLarge(bytes: bytes.count, ceiling: ceilingBytes)
        }
        if bytes.prefix(nulWindowBytes).contains(0x00) { return .binary }
        if String(validating: bytes, as: UTF8.self) == nil { return .binary }
        return nil
    }
}
