import ArgumentParser
import macSCPCore

/// `DiagnosticScope` lives in Core (the App's diagnostics panel picks one
/// too), so it cannot itself import `ArgumentParser` — the conformance that
/// lets `--scope` parse straight into the enum lives here instead, in the one
/// target that already depends on both. Same reasoning as
/// `ConnectionKind+ArgumentParser.swift` and
/// `ConflictAction+ArgumentParser.swift`, and kept as a third sibling file
/// rather than folded into either: the three enums share nothing but this
/// pattern.
///
/// The conformance is what makes `diagnose --help` list the values, too.
/// ArgumentParser derives `allValueStrings` for a `CaseIterable`
/// `ExpressibleByArgument` whose `RawValue` is `String`, which
/// `DiagnosticScope` already is — so the help screen enumerates the scopes
/// from the enum rather than from a sentence someone has to keep in step
/// with it.
extension DiagnosticScope: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
