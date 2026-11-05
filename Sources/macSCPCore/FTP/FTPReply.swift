import Foundation

/// One complete reply from an FTP server: a three-digit code and one or more
/// lines of text (RFC 959 section 4.2). `lines` holds the text only, with the
/// code and its separator removed from the first and the last line; the lines
/// in between are kept exactly as the server sent them.
public struct FTPReply: Sendable, Equatable {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// 1xx, 2xx and 3xx: the command was accepted, or is in progress, or
    /// needs a further command.
    public var isPositive: Bool { (100..<400).contains(code) }

    /// 4xx: refused for now; the same command may succeed later.
    public var isTransient: Bool { (400..<500).contains(code) }

    /// 5xx: refused; repeating the command unchanged will not help.
    public var isPermanent: Bool { (500..<600).contains(code) }
}

/// A line that cannot start a reply: it does not begin with exactly three
/// ASCII digits (the first not zero) followed by a space, a hyphen or the end
/// of the line.
public enum FTPReplyError: Error, Equatable, Sendable {
    case notAReply(String)
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
public enum FTPReplyAccumulator {
    /// Feeds one line. Returns the finished reply, or `nil` while a multiline
    /// reply is still open. `partial` carries the raw lines of the open reply
    /// (its first element is the opening line, which fixes the closing code)
    /// and is empty again once a reply has been returned.
    ///
    /// Throws `FTPReplyError.notAReply` for a line that has to start a reply
    /// and does not. `nil` is reserved for "still open", so a malformed line
    /// is never mistaken for a continuation; `partial` is left untouched.
    public static func feed(_ line: String, into partial: inout [String]) throws -> FTPReply? {
        guard let opener = partial.first else {
            // Not inside a reply: this line must start one.
            guard let head = parseHead(line) else { throw FTPReplyError.notAReply(line) }
            if head.separator == .hyphen {
                partial = [line]
                return nil
            }
            return FTPReply(code: head.code, lines: [head.text])
        }

        // Inside a multiline reply. The opener was accepted by this function,
        // so its head parses; the guard keeps a hand-built `partial` from
        // trapping.
        guard let open = parseHead(opener), open.separator == .hyphen else {
            partial = []
            throw FTPReplyError.notAReply(opener)
        }
        if let head = parseHead(line), head.code == open.code, head.separator == .space {
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

    /// Splits `<ddd><space|hyphen|end>text` into its parts, or `nil` when the
    /// line does not have that shape. Digits are ASCII only, and a code never
    /// starts with zero.
    private static func parseHead(_ line: String) -> Head? {
        let bytes = Array(line.utf8)
        guard bytes.count >= 3 else { return nil }
        var code = 0
        for (index, byte) in bytes.prefix(3).enumerated() {
            guard (0x30...0x39).contains(byte) else { return nil }
            if index == 0, byte == 0x30 { return nil }
            code = code * 10 + Int(byte - 0x30)
        }
        if bytes.count == 3 {
            return Head(code: code, separator: .end, text: "")
        }
        let separator: Separator
        switch bytes[3] {
        case 0x20: separator = .space
        case 0x2D: separator = .hyphen
        default: return nil
        }
        // The text starts after a one-byte ASCII separator, so this index is
        // a character boundary.
        let text = String(decoding: bytes.dropFirst(4), as: UTF8.self)
        return Head(code: code, separator: separator, text: text)
    }
}
