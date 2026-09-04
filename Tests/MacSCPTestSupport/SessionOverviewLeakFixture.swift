import Foundation

/// A fixture for `SessionOverviewWiringGuardTests`' two secret-leak checks,
/// added in Task 2's fix round 1: real, compiling Swift in exactly the shapes
/// those checks exist to catch on the session overview — a view holding the
/// backends' SECRET fields by name, and a value rendered through
/// `String(describing:)`.
///
/// The design's "Never in the overview" paragraph names both: no secret
/// value, no passphrase, no private key contents, no endpoint userinfo, and
/// the guard suite scans the view for the secret field ids and for
/// `String(describing:)` "the way the diagnostics guard does". Those checks
/// are negatives, and CLAUDE.md asks a negative for a positive beside it.
/// This file is that positive: the same scan run over this file must find
/// every pattern, so "the view contains none of them" reports an absence
/// somebody measured rather than a set of patterns that match nothing
/// anywhere.
///
/// Never called. It lives here beside `ErrorInterpolationFixture.swift`,
/// which does the identical job for the diagnostics module's own describing
/// rule, and for the identical reason: the guard reads `Sources/`, so a
/// fixture under `Tests/MacSCPTestSupport/` cannot be read back as an
/// offender the way one planted inside the guarded tree would be.
///
/// **The property names below are literals on purpose.** Everywhere else
/// this project derives an identifier rather than spelling it, and the same
/// rule points the other way here: a fixture IS the violation, so it has to
/// spell what a violation looks like. The check that reads it derives the
/// real ids from `BackendDescriptor` and requires this file to carry every
/// one — so a fourth secret field turns that check red, which is the loud
/// failure asking for this file to grow rather than a silent pass.
public struct SessionOverviewLeakFixture {
    /// SSH's two secrets, spelled as the schema spells them.
    public var password: String = ""
    public var passphrase: String = ""
    /// S3's, and the one whose sibling (`accessKeyID`) is deliberately NOT
    /// here: an access key id is an opaque credential but not a secret, and
    /// the overview may show it.
    public var secretAccessKey: String = ""

    public init() {}

    /// The describing shape, which reaches an arbitrary value's stored
    /// properties and prints them — the reason the rule exists at all, since
    /// a configuration value describes itself with whatever it was
    /// constructed from.
    public func demonstratesTheDescribingRender(_ value: Any) -> String {
        String(describing: value)
    }
}
