import Foundation

/// The low 12 POSIX permission bits as a value type the permissions sheet
/// binds to (M7b): rwx grid and octal field stay in sync through it.
public struct PosixPermissions: Equatable, Sendable {
    public enum Class: CaseIterable, Sendable { case owner, group, other }
    public enum Right: CaseIterable, Sendable { case read, write, execute }

    public private(set) var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & 0o7777
    }

    /// 3–4 digit octal form ("640", "4755"). Never padded beyond 3 digits.
    public var octalString: String {
        let s = String(rawValue, radix: 8)
        return s.count < 3 ? String(repeating: "0", count: 3 - s.count) + s : s
    }

    /// Parses a 1–4 digit octal string; nil for anything else.
    public init?(octalString: String) {
        guard (1...4).contains(octalString.count),
              octalString.allSatisfy({ "01234567".contains($0) }),
              let value = UInt32(octalString, radix: 8) else { return nil }
        self.init(rawValue: value)
    }

    private static func mask(_ c: Class, _ r: Right) -> UInt32 {
        let shift: UInt32 = c == .owner ? 6 : (c == .group ? 3 : 0)
        let bit: UInt32 = r == .read ? 0o4 : (r == .write ? 0o2 : 0o1)
        return bit << shift
    }

    public subscript(c: Class, r: Right) -> Bool {
        get { rawValue & Self.mask(c, r) != 0 }
        set {
            if newValue { rawValue |= Self.mask(c, r) }
            else { rawValue &= ~Self.mask(c, r) }
        }
    }

    /// Derives directory-appropriate bits from a file's raw permissions
    /// (M11c/T1): in each of the three rwx triads, sets execute WHENEVER
    /// read is already set there (needed to traverse/list the directory),
    /// leaves read/write untouched, and carries the special bits
    /// (setuid/setgid/sticky, the top four bits of the low 12) through
    /// unchanged. E.g. 0o644 -> 0o755, 0o600 -> 0o700, 0o640 -> 0o750,
    /// 0o2644 -> 0o2755 (setgid preserved), 0o000 -> 0o000 (no read anywhere,
    /// nothing added). Used by the permissions sheet (T3) to prefill the
    /// directory grid when the recursive "separate" mode is picked. Static
    /// rather than an instance property/method (the plan assumes static;
    /// nothing here needs `self`'s stored `rawValue` beyond the `raw`
    /// parameter, so a pure function reads clearer at the call site).
    public static func directoryDefault(from raw: UInt32) -> UInt32 {
        var result = raw & 0o7777
        for c in Class.allCases where result & mask(c, .read) != 0 {
            result |= mask(c, .execute)
        }
        return result
    }
}
