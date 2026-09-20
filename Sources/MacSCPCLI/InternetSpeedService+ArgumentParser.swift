import ArgumentParser
import macSCPCore

/// `InternetSpeedService` lives in Core (Settings picks one too), so it
/// cannot itself import `ArgumentParser` — the conformance that lets
/// `--speed-service` parse straight into the enum lives here instead, a
/// fourth sibling beside `DiagnosticScope+ArgumentParser.swift`,
/// `ConnectionKind+ArgumentParser.swift` and
/// `ConflictAction+ArgumentParser.swift`, for the reason the first of them
/// states.
///
/// As there, the conformance is also what makes `diagnose --help` list the
/// values: ArgumentParser derives `allValueStrings` for a `CaseIterable`
/// `ExpressibleByArgument` whose `RawValue` is `String`, which this enum
/// already is — so a service added to the set appears in the help without
/// anyone editing a sentence.
extension InternetSpeedService: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
