import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("UpdateAlertContent")
struct UpdateAlertContentTests {
    /// Every result must produce a non-empty title and message, except the
    /// `nil` case which is the "nothing to show" state. A missing catalog
    /// key would surface here as the raw key or an empty string.
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
    /// would read as if the installed build were the new one.
    @Test func theUpdateMessageNamesBothVersions() throws {
        let current = try #require(AppVersion("1.1.0"))
        let latest = try #require(AppVersion("1.2.0"))
        let url = try #require(URL(string: "https://example.invalid/releases"))

        let message = UpdateAlertContent.message(
            for: .updateAvailable(latest: latest, current: current, url: url))

        #expect(message.contains(latest.description))
        #expect(message.contains(current.description))
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
