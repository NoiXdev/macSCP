import Foundation

/// A fixture for `DiagnosticsNoDescribingGuardTests`'s second negative check,
/// added in the diagnostics-leak-route plan's final fix round: real,
/// compiling Swift code in the two shapes that check exists to catch — a
/// sentence built by describing an error, and a sentence built by
/// interpolating an error value bare. Both are the spellings the module's
/// own rule forbids, and both were invisible to the first check by
/// construction, because that one reads text a stripper has blanked string
/// literals out of, and blanking a literal takes its interpolation with it.
///
/// Never called. It exists only so the second negative check has a real
/// match to read instead of asserting its patterns against nothing —
/// CLAUDE.md, "Guards that name what they watch": a negative needs a
/// positive beside it. It lives here, beside `CeilingRegexFixture.swift`,
/// `PollUntil.swift` and `SleepingChildRegexFixture.swift` under
/// `Tests/MacSCPTestSupport/`, which the diagnostics guard never enumerates —
/// that guard reads one directory under `Sources/macSCPCore/`, so this file
/// cannot be read back as an offender the way a fixture planted inside the
/// guarded tree would be.
public enum ErrorInterpolationFixture {
    /// The shape a describing call takes once it reaches a sentence: the
    /// error's stored properties, rendered into text that a diagnosis row is
    /// written to carry into a public issue.
    public static func demonstratesTheDescribingInterpolation(_ error: any Error) -> String {
        "the connection failed: \(String(describing: error))"
    }

    /// The second shape, and the cheaper one to write by accident: the error
    /// value interpolated bare, which reaches the same description through
    /// the compiler's own conversion rather than through a named call.
    public static func demonstratesTheBareErrorInterpolation(_ error: any Error) -> String {
        "\(error)"
    }

    /// The suffix half of the rule rather than the exact-name half: an
    /// identifier that merely ENDS in the type's name interpolates the same
    /// value under a different spelling, and a check anchored on one name
    /// would buy this one.
    public static func demonstratesASuffixedErrorInterpolation(_ dialError: any Error) -> String {
        "\(dialError)"
    }
}
