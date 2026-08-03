import ArgumentParser
import macSCPCore

/// `ConflictAction` lives in Core (shared with a possible future GUI use of
/// `TransferPlan`), so it cannot itself import `ArgumentParser` — the
/// conformance that lets `--on-conflict` parse straight into the enum lives
/// here instead, in the one target that already depends on both (M20
/// Task 10).
extension ConflictAction: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
