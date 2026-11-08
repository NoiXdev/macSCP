import ArgumentParser
import macSCPCore

/// `FTPSecurityMode` lives in Core (the App's connect form picks one too, and
/// it is the persisted value), so it cannot itself import `ArgumentParser` —
/// the conformance that lets `--security` parse straight into the enum lives
/// here instead, in the one target that already depends on both. Same
/// reasoning as `ConnectionKind+ArgumentParser.swift`,
/// `ConflictAction+ArgumentParser.swift`,
/// `DiagnosticScope+ArgumentParser.swift` and
/// `InternetSpeedService+ArgumentParser.swift`, and kept as a sibling file
/// rather than folded into any of them: the enums share nothing but this
/// pattern.
///
/// The RAW VALUES are the flag's values, so a mode typed on the command line
/// IS the value written into the session file — the same reason
/// `FTPFieldSchema`'s picker options are keyed by them rather than by a
/// mapping table. They are therefore camel-cased (`explicitTLS`) where a
/// hand-written flag would likely have been hyphenated; a second spelling
/// here would be a translation layer whose only job is to drift.
///
/// The conformance is also what makes `sessions add --help` list the modes
/// and the completion scripts offer them. ArgumentParser derives
/// `allValueStrings` for a `CaseIterable` `ExpressibleByArgument` whose
/// `RawValue` is `String`, which `FTPSecurityMode` already is — so the help
/// enumerates the modes from the enum rather than from a sentence someone
/// has to keep in step with it.
extension FTPSecurityMode: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
