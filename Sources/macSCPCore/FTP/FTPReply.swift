import Foundation

/// One complete reply from an FTP server: a three-digit code and one or more
/// lines of text (RFC 959 section 4.2). `lines` holds the text only, with the
/// code and its separator removed from the first and the last line; the lines
/// in between are kept exactly as the server sent them.
struct FTPReply: Sendable, Equatable {
    let code: Int
    let lines: [String]

    // There is deliberately NO `isPositive` here — the 1xx ∪ 2xx ∪ 3xx union
    // RFC 959 section 4.2 calls a positive reply. It existed, and its last
    // call site was `USER`, which was blessed for it on the strength of its
    // 3xx arm; the 1xx arm came with it and admitted a preliminary reply to a
    // command that promises no second one. A call site that wants two of the
    // three classes now spells both (`FTPControlConnection`'s `USER` guard
    // says `isPositiveCompletion || isIntermediate`), so the union cannot be
    // reached for by a site that only meant one arm of it, and the violation
    // has no spelling left (fix round 2 of the FTP backend's Task 5, F3).

    /// 1xx: in progress. The command has been accepted and a further reply
    /// will follow — `150` before a transfer's bytes, `120` before a greeting.
    var isPreliminary: Bool { (100..<200).contains(code) }

    /// 2xx: the command completed and nothing more is needed. The predicate
    /// a call site wants unless it has a reason to accept one of the other
    /// two.
    var isPositiveCompletion: Bool { (200..<300).contains(code) }

    /// 3xx: accepted, and waiting for a further command — `331` for `PASS`,
    /// `332` for an account the backend does not supply.
    var isIntermediate: Bool { (300..<400).contains(code) }

    /// 4xx: refused for now; the same command may succeed later.
    var isTransient: Bool { (400..<500).contains(code) }

    /// 5xx: refused; repeating the command unchanged will not help.
    var isPermanent: Bool { (500..<600).contains(code) }
}

/// A line that cannot start a reply, or an open reply whose opening line
/// cannot be trusted.
///
/// **The payload is deliberately free of server-supplied text.** It names the
/// KIND of malformation and the length of the offending line in bytes, and
/// nothing else. This type lives on a control channel next to `PASS`, and
/// some servers quote the client's command line back in their replies, so a
/// desynchronised line can carry a credential; the default description of an
/// error prints its payload verbatim, and a failed `#expect` prints the
/// source text of its expression. Neither can leak what is not in the value.
/// Do not "improve" a case by adding the line, or a prefix of it, back --
/// whether a redacted line reaches a diagnostic log is a decision the
/// connection layer makes explicitly, not a consequence of this type's shape.
enum FTPReplyError: Error, Equatable, Sendable {
    /// `byteCount` is the UTF-8 length of the line that was refused (for
    /// `.unusableOpener`, of the stored opening line).
    case notAReply(Malformation, byteCount: Int)

    /// What was structurally wrong. Cases carry no payload on purpose.
    enum Malformation: Error, Sendable, Equatable {
        /// Fewer than the three bytes a code needs.
        case tooShort
        /// The first three bytes are not ASCII digits, or the code starts
        /// with zero.
        case notThreeDigits
        /// A code of three digits followed by something other than a space,
        /// a hyphen or the end of the line.
        case badSeparator
        /// The open reply's first stored line is not a `<code>-` opener, so
        /// the code that would close the reply is unknown.
        case unusableOpener
    }
}

/// Assembles replies from lines, one line at a time.
///
/// A pure function over one line plus the lines gathered so far: it owns no
/// connection and does no I/O. Splitting the byte stream into lines, and
/// dropping their CR LF terminators, is the caller's job.
///
/// RFC 959 section 4.2: a multiline reply opens with `<code>-` and closes
/// with the same code followed by a space, at the very start of a line. Every
/// line in between is free text -- it may begin with the same digits, with
/// other digits, or with nothing recognisable -- and never closes the reply
/// unless it is exactly `<code><space>...`.
enum FTPReplyAccumulator {
    /// Feeds one line. Returns the finished reply, or `nil` while a multiline
    /// reply is still open. `partial` carries the raw lines of the open reply
    /// (its first element is the opening line, which fixes the closing code)
    /// and is empty again once a reply has been returned.
    ///
    /// Throws `FTPReplyError.notAReply` for a line that has to start a reply
    /// and does not. `nil` is reserved for "still open", so a malformed line
    /// is never mistaken for a continuation. A refused first line leaves
    /// `partial` untouched (it is empty). The one case that does change it:
    /// a `partial` whose first element is not a valid `<code>-` opener --
    /// which this function never builds, only a caller can -- is discarded
    /// before throwing, so the accumulator cannot stay stuck refusing every
    /// line that follows.
    static func feed(_ line: String, into partial: inout [String]) throws -> FTPReply? {
        guard let opener = partial.first else {
            // Not inside a reply: this line must start one.
            let head: Head
            do {
                head = try parseHead(line)
            } catch {
                throw FTPReplyError.notAReply(error, byteCount: line.utf8.count)
            }
            if head.separator == .hyphen {
                partial = [line]
                return nil
            }
            return FTPReply(code: head.code, lines: [head.text])
        }

        // Inside a multiline reply. The opener was accepted by this function,
        // so its head parses; the guard keeps a hand-built `partial` from
        // trapping.
        guard let open = try? parseHead(opener), open.separator == .hyphen else {
            partial = []
            throw FTPReplyError.notAReply(.unusableOpener, byteCount: opener.utf8.count)
        }
        if let head = try? parseHead(line), head.code == open.code, head.separator == .space {
            let texts = [open.text] + partial.dropFirst() + [head.text]
            partial = []
            return FTPReply(code: open.code, lines: texts)
        }
        partial.append(line)
        return nil
    }

    private enum Separator { case space, hyphen, end }

    private struct Head {
        let code: Int
        let separator: Separator
        let text: String
    }

    /// Splits `<ddd><space|hyphen|end>text` into its parts, or throws the
    /// kind of malformation when the line does not have that shape. Digits
    /// are ASCII only, and a code never starts with zero.
    private static func parseHead(_ line: String) throws(FTPReplyError.Malformation) -> Head {
        let bytes = Array(line.utf8)
        guard bytes.count >= 3 else { throw .tooShort }
        var code = 0
        for (index, byte) in bytes.prefix(3).enumerated() {
            guard (0x30...0x39).contains(byte) else { throw .notThreeDigits }
            if index == 0, byte == 0x30 { throw .notThreeDigits }
            code = code * 10 + Int(byte - 0x30)
        }
        if bytes.count == 3 {
            return Head(code: code, separator: .end, text: "")
        }
        let separator: Separator
        switch bytes[3] {
        case 0x20: separator = .space
        case 0x2D: separator = .hyphen
        default: throw .badSeparator
        }
        // The text starts after a one-byte ASCII separator, so this index is
        // a character boundary.
        let text = String(decoding: bytes.dropFirst(4), as: UTF8.self)
        return Head(code: code, separator: separator, text: text)
    }
}
