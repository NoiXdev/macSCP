import ArgumentParser
import macSCPCore

/// `ConnectionKind` lives in Core (shared with the GUI's own backend
/// dispatch), so it cannot itself import `ArgumentParser` — the conformance
/// that lets `--kind` parse straight into the enum lives here instead, in
/// the one target that already depends on both. Same reasoning as
/// `ConflictAction+ArgumentParser.swift`, kept as a sibling file rather than
/// added to it: the two enums share nothing but this pattern.
extension ConnectionKind: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
