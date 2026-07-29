import Foundation

/// A parsed release version in the minimal SemVer-style shape this app's
/// tags use: `major.minor.patch` with an optional pre-release identifier
/// and optional build metadata (spec §1).
///
/// Parsing accepts a leading `v` (dropped), truncates anything after a
/// `+` (build metadata — ignored entirely, never compared), and requires
/// exactly three numeric dot-separated fields before an optional `-`
/// pre-release suffix. Anything else — empty, non-numeric fields, too few
/// or too many fields — fails to parse (`init?` returns `nil`).
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The raw text after `-`, before any build metadata was dropped
    /// (e.g. `"beta.1"` for `"1.2.0-beta.1+abc"`). `nil` for a plain
    /// release version.
    public let preRelease: String?

    public init?(_ string: String) {
        var remainder = Substring(string)
        if remainder.hasPrefix("v") {
            remainder = remainder.dropFirst()
        }

        // Build metadata (after "+") is dropped and never examined again —
        // it plays no part in parsing or comparison (spec §1).
        if let plusIndex = remainder.firstIndex(of: "+") {
            remainder = remainder[remainder.startIndex..<plusIndex]
        }

        var preRelease: String?
        if let dashIndex = remainder.firstIndex(of: "-") {
            let candidate = String(remainder[remainder.index(after: dashIndex)...])
            guard !candidate.isEmpty else { return nil }
            // The pre-release identifier comes straight from a GitHub tag —
            // unbounded free text there could otherwise render attacker-
            // controlled content inside the "Version %@ is available"
            // dialog (M11b final review, Finding M3). Restricted at parse
            // time to `[0-9A-Za-z.-]`, max 32 characters; anything else
            // fails to parse just like any other malformed tag.
            guard candidate.count <= 32, candidate.allSatisfy(Self.isAllowedPreReleaseCharacter)
            else { return nil }
            preRelease = candidate
            remainder = remainder[remainder.startIndex..<dashIndex]
        }

        let fields = remainder.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        guard let major = Int(fields[0]), let minor = Int(fields[1]), let patch = Int(fields[2]),
            major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// Normalized form without the `v` prefix or build metadata, e.g.
    /// `"1.2.3"` or `"1.2.0-beta.1"`.
    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard let preRelease else { return base }
        return "\(base)-\(preRelease)"
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            // Same major.minor.patch: a pre-release is older than the
            // final release (spec §1).
            return true
        case (nil, .some):
            return false
        case (.some(let left), .some(let right)):
            return Self.comparePreRelease(left, right)
        }
    }

    /// Field-wise pre-release comparison: fields are split on `.`; a field
    /// that's purely numeric on both sides compares numerically, otherwise
    /// lexicographically; if all shared fields are equal, fewer fields
    /// sorts first (spec §1).
    private static func comparePreRelease(_ lhs: String, _ rhs: String) -> Bool {
        let lhsFields = lhs.split(separator: ".").map(String.init)
        let rhsFields = rhs.split(separator: ".").map(String.init)

        for index in 0..<min(lhsFields.count, rhsFields.count) {
            let left = lhsFields[index]
            let right = rhsFields[index]
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber
            }
            return left < right
        }
        return lhsFields.count < rhsFields.count
    }

    /// Whether `character` is one of `[0-9A-Za-z.-]` — the allowed alphabet
    /// for a pre-release identifier (Finding M3 above).
    private static func isAllowedPreReleaseCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isNumber || character.isLetter || character == "." || character == "-")
    }
}
