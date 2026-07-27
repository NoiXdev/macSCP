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
}
