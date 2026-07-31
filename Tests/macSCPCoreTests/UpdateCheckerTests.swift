import Foundation
import Testing
@testable import macSCPCore

/// Fetcher stand-in that counts calls and returns/throws whatever a test
/// stages — used to prove `UpdateChecker` never touches the network when
/// the local version is unknown (spec §2).
private final class CountingMockFetcher: ReleaseFetcher, @unchecked Sendable {
    var callCount = 0
    var result: Result<ReleaseInfo, Error>

    init(result: Result<ReleaseInfo, Error>) {
        self.result = result
    }

    func latestRelease() async throws -> ReleaseInfo {
        callCount += 1
        return try result.get()
    }
}

/// `UpdateChecker.check()` (spec §2): unknown local version skips the
/// network entirely; otherwise the fetcher is consulted and its tag
/// compared against the local version.
@Suite("UpdateChecker")
struct UpdateCheckerTests {
    private static let releaseURL = URL(string: "https://example.com/releases/v1.1.0")!

    @Test(arguments: [nil, "dev"] as [String?])
    func unknownLocalVersionSkipsNetwork(_ currentVersion: String?) async throws {
        let fetcher = CountingMockFetcher(
            result: .success(ReleaseInfo(tag: "v1.1.0", url: Self.releaseURL)))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: currentVersion)

        let result = await checker.check()
        #expect(result == .unknownLocalVersion)
        #expect(fetcher.callCount == 0)
    }

    @Test func detectsNewerRelease() async throws {
        let fetcher = CountingMockFetcher(
            result: .success(ReleaseInfo(tag: "v1.1.0", url: Self.releaseURL)))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.0.0")

        let result = await checker.check()
        let current = try #require(AppVersion("1.0.0"))
        let latest = try #require(AppVersion("1.1.0"))
        #expect(result == .updateAvailable(latest: latest, current: current, url: Self.releaseURL))
    }

    @Test(arguments: ["v1.0.0", "v0.9.0"])
    func sameOrOlderIsUpToDate(_ tag: String) async throws {
        let fetcher = CountingMockFetcher(
            result: .success(ReleaseInfo(tag: tag, url: Self.releaseURL)))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.0.0")

        let result = await checker.check()
        let current = try #require(AppVersion("1.0.0"))
        #expect(result == .upToDate(current: current))
    }

    @Test func malformedTagFails() async throws {
        let fetcher = CountingMockFetcher(
            result: .success(ReleaseInfo(tag: "release-xyz", url: Self.releaseURL)))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.0.0")

        let result = await checker.check()
        #expect(result == .failed(.malformedResponse))
    }

    @Test(arguments: [UpdateCheckError.rateLimited, UpdateCheckError.httpStatus(500)])
    func fetcherTypedErrorsPropagate(_ thrown: UpdateCheckError) async throws {
        let fetcher = CountingMockFetcher(result: .failure(thrown))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.0.0")

        let result = await checker.check()
        #expect(result == .failed(thrown))
    }

    @Test func foreignErrorMapsToOffline() async throws {
        struct SomeOtherError: Error {}
        let fetcher = CountingMockFetcher(result: .failure(SomeOtherError()))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.0.0")

        let result = await checker.check()
        #expect(result == .failed(.offline))
    }
}
