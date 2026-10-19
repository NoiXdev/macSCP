import Foundation

/// What is wrong with a proposed bucket name, as `S3BucketName.problem(with:)`
/// reports it. One problem per name: the first rule broken, in the order
/// documented on `problem(with:)`.
public enum BucketNameProblem: Equatable, Sendable {
    case tooShort, tooLong, uppercase
    /// A character that is not a lowercase letter, a digit, a hyphen or a
    /// dot. The payload is the first such character, as written.
    case invalidCharacter(Character)
    case looksLikeAnIPAddress
    /// The name starts or ends with something other than a letter or digit.
    case badEdge
}

/// macSCP's own check of a bucket name, run before a create request exists
/// (`S3BucketSettings.createBucket`) and by any UI that wants to say what is
/// wrong while the name is being typed.
///
/// The rules are the ones AWS states for a general-purpose bucket's name,
/// the subset that can be checked without asking a store: 3 to 63
/// characters, lowercase ASCII letters, digits, hyphens and dots only, a
/// letter or digit at both ends, and not the shape of an IPv4 address.
///
/// **Not checked, and the store is left to refuse:** two adjacent dots, a
/// dot beside a hyphen, the `xn--` and `sthree-` prefixes, the `-s3alias`
/// and `--ol-s3` suffixes, and whether the name is already taken. Those need
/// either a case in `BucketNameProblem` that nothing asked for or the store
/// itself.
public enum S3BucketName {
    /// The first rule `name` breaks, or `nil` when it breaks none.
    ///
    /// Checked in this order, so a UI that shows one problem shows the same
    /// one every time: length, then uppercase (before the character check,
    /// because lowercasing is the one-step fix), then any other character,
    /// then the two edges, then the address form.
    ///
    /// Length is counted in characters, which is what a person typing the
    /// name sees.
    public static func problem(with name: String) -> BucketNameProblem? {
        let length = name.count
        if length < 3 { return .tooShort }
        if length > 63 { return .tooLong }
        if name.contains(where: { isASCIIUppercase($0) }) { return .uppercase }
        if let bad = name.first(where: { !isAllowed($0) }) { return .invalidCharacter(bad) }
        if let first = name.first, !isLowercaseLetterOrDigit(first) { return .badEdge }
        if let last = name.last, !isLowercaseLetterOrDigit(last) { return .badEdge }
        if looksLikeAnIPv4Address(name) { return .looksLikeAnIPAddress }
        return nil
    }

    private static func isASCIIUppercase(_ c: Character) -> Bool {
        c.isASCII && c.isUppercase
    }

    private static func isLowercaseLetterOrDigit(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    private static func isAllowed(_ c: Character) -> Bool {
        isLowercaseLetterOrDigit(c) || c == "-" || c == "."
    }

    /// Four dot-separated groups of digits, nothing else: AWS's own
    /// formulation ("formatted as an IP address"), not a check that each
    /// group is at most 255.
    private static func looksLikeAnIPv4Address(_ name: String) -> Bool {
        let groups = name.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        return groups.allSatisfy { group in
            !group.isEmpty && group.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
