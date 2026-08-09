import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("UpdateAlertContent")
struct UpdateAlertContentTests {
    /// Every result must produce a non-empty title and message, except the
    /// `nil` case which is the "nothing to show" state. This guards against
    /// a hard-coded empty return or a branch whose formatting produces
    /// nothing — not against a missing catalog key, since `L10n.string`
    /// falls back to its own non-empty `defaultValue` when a key is absent,
    /// and not against a forgotten `UpdateCheckResult` case, since Swift's
    /// exhaustiveness checking already rejects that at compile time.
    @Test func everyResultProducesCopy() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        let results: [UpdateCheckResult] = [
            .updateAvailable(latest: latest, current: current, url: url),
            .upToDate(current: current),
            .unknownLocalVersion,
            .failed(.offline),
            .failed(.httpStatus(503)),
            .failed(.rateLimited),
            .failed(.malformedResponse),
        ]

        for result in results {
            #expect(UpdateAlertContent.title(for: result).isEmpty == false)
            #expect(UpdateAlertContent.message(for: result).isEmpty == false)
        }
    }

    /// No result may show the empty-state copy, and the no-result case must.
    @Test func theNilResultIsTheOnlyEmptyOne() {
        #expect(UpdateAlertContent.title(for: nil).isEmpty)
        #expect(UpdateAlertContent.message(for: nil).isEmpty)
    }

    /// The two versions are spec-mandated to BOTH appear, and in the right
    /// roles: an update alert that named only one version, or swapped them,
    /// would read as if the installed build were the new one. The
    /// `.contains` checks alone would not catch a transposition (both stay
    /// true either way).
    ///
    /// Comparing this rendering against the same call with `latest`/
    /// `current` swapped does NOT close that gap: permuting a two-argument
    /// function's inputs and permuting its output are the same operation,
    /// so `message(latest: a, current: b)` and `message(latest: b, current:
    /// a)` differ under a correct implementation for exactly the same
    /// reason they differ under one that swaps the two into the template —
    /// both are still "some function of two known-different values", so
    /// inequality holds either way. Verified empirically: swapping the
    /// substitution order in `UpdateAlertContent.message`'s
    /// `.updateAvailable` branch and re-running that comparison stayed
    /// green.
    ///
    /// What actually catches a transposition without hard-coding a word
    /// order (a translation is free to reorder the placeholders, e.g.
    /// `%2$@` before `%1$@`) is reconstructing the expected string from the
    /// same localized template, with `latest` then `current` fixed in the
    /// spec-mandated argument order, and comparing it to the real output
    /// for the SAME call — no input permutation involved, so there is
    /// nothing for a symmetric transposition to hide behind.
    @Test func theUpdateMessageNamesBothVersions() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        let message = UpdateAlertContent.message(
            for: .updateAvailable(latest: latest, current: current, url: url))

        #expect(message.contains(latest.description))
        #expect(message.contains(current.description))

        let template = L10n.string(
            "update.available.message %@ %@", "Version %@ is available (installed: %@)")
        let expected = String(format: template, latest.description, current.description)
        #expect(message == expected)
    }

    /// The HTTP status must reach the user — a generic failure message
    /// would make a 503 indistinguishable from a 404 in a bug report.
    @Test func theHTTPFailureMessageNamesItsStatusCode() {
        #expect(UpdateAlertContent.message(for: .failed(.httpStatus(503))).contains("503"))
    }

    /// The unknown-version case must never read like an update claim: the
    /// spec forbids building one on a version that could not be read.
    @Test func theUnknownVersionCopyDiffersFromTheUpdateCopy() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        #expect(
            UpdateAlertContent.message(for: .unknownLocalVersion)
                != UpdateAlertContent.message(
                    for: .updateAvailable(latest: latest, current: current, url: url)))
    }
}
