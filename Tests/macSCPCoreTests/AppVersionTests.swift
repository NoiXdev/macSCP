import Foundation
import Testing
@testable import macSCPCore

/// `AppVersion` parsing and ordering (spec §1): a minimal SemVer-style
/// parser (major.minor.patch, optional pre-release, build metadata
/// dropped) with numeric-aware comparison.
@Suite("AppVersion")
struct AppVersionTests {
    @Test func parsesPlainAndPrefixed() throws {
        let plain = try #require(AppVersion("1.2.3"))
        let prefixed = try #require(AppVersion("v1.2.3"))
        #expect(plain == prefixed)
        #expect(plain.description == "1.2.3")
    }

    @Test func parsesPreReleaseAndDropsBuildMetadata() throws {
        let preRelease = try #require(AppVersion("1.2.0-beta.1+abc"))
        #expect(preRelease.preRelease == "beta.1")

        let withBuildMetadata = try #require(AppVersion("1.2.0+abc"))
        let withoutBuildMetadata = try #require(AppVersion("1.2.0"))
        #expect(withBuildMetadata == withoutBuildMetadata)
    }

    @Test(arguments: ["", "abc", "1.2", "1.2.x", "v"])
    func rejectsGarbage(_ raw: String) throws {
        #expect(AppVersion(raw) == nil)
    }

    @Test func ordersByNumericFields() throws {
        let v123 = try #require(AppVersion("1.2.3"))
        let v1100 = try #require(AppVersion("1.10.0"))
        let v200 = try #require(AppVersion("2.0.0"))
        #expect(v123 < v1100)
        #expect(v1100 < v200)
    }

    @Test func preReleaseIsOlderThanRelease() throws {
        let preRelease = try #require(AppVersion("1.2.0-beta.1"))
        let release = try #require(AppVersion("1.2.0"))
        #expect(preRelease < release)
    }

    @Test func preReleaseFieldsCompare() throws {
        let alpha = try #require(AppVersion("1.2.0-alpha"))
        let beta = try #require(AppVersion("1.2.0-beta"))
        #expect(alpha < beta)

        let beta2 = try #require(AppVersion("1.2.0-beta.2"))
        let beta10 = try #require(AppVersion("1.2.0-beta.10"))
        #expect(beta2 < beta10)

        let betaNoField = try #require(AppVersion("1.2.0-beta"))
        let beta1 = try #require(AppVersion("1.2.0-beta.1"))
        #expect(betaNoField < beta1)
    }
}
