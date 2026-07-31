import Foundation

/// Pure interval rule for the once-a-day automatic update check (spec §2)
/// — no I/O, no dependency on the fetcher or checker.
public enum UpdateSchedule {
    /// `enabled == false` always skips. A never-checked-before app (`lastCheck
    /// == nil`) always checks. Otherwise checks only once at least 24 hours
    /// have passed since the last attempt (successful or not — the caller
    /// updates the timestamp after every attempt, see Global Constraints).
    public static func shouldCheck(now: Date, lastCheck: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 24 * 3600
    }
}

/// The tag and release-page URL of the latest GitHub release.
public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var url: URL

    public init(tag: String, url: URL) {
        self.tag = tag
        self.url = url
    }
}

/// Fetches metadata for the latest release. Kept behind a protocol so
/// `UpdateChecker` can be exercised in tests without any real network
/// access — the production implementation is `GitHubReleaseFetcher`.
public protocol ReleaseFetcher: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

/// Typed failure reasons for an update check attempt — never a stringly
/// error (house style).
public enum UpdateCheckError: Error, Equatable, Sendable {
    /// The request could not reach the network (`URLError` at the
    /// transport level).
    case offline
    /// A non-200, non-rate-limited HTTP response.
    case httpStatus(Int)
    /// GitHub's REST API rate limit was hit (403/429 with
    /// `x-ratelimit-remaining: 0`).
    case rateLimited
    /// The response was 200 but its JSON didn't contain what was expected
    /// (missing fields, or an unparsable release tag).
    case malformedResponse
}

/// Outcome of one `UpdateChecker.check()` call (spec §1/§2).
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: AppVersion)
    case updateAvailable(latest: AppVersion, current: AppVersion, url: URL)
    /// The local version is missing or unparsable — an honest "unknown"
    /// result, never an update claim (Global Constraints). The network is
    /// never contacted in this case.
    case unknownLocalVersion
    case failed(UpdateCheckError)
}

/// Compares the running app's version against the latest GitHub release.
///
/// Core stays bundle-free: the current version arrives as a plain
/// `String?` that the App layer reads from `Bundle.main` and passes in —
/// `UpdateChecker` itself never touches `Bundle`.
public struct UpdateChecker: Sendable {
    private let fetcher: any ReleaseFetcher
    private let currentVersion: String?

    public init(fetcher: any ReleaseFetcher, currentVersion: String?) {
        self.fetcher = fetcher
        self.currentVersion = currentVersion
    }

    /// Runs one check. A missing or unparsable `currentVersion` short-circuits
    /// to `.unknownLocalVersion` WITHOUT calling the fetcher — there is
    /// nothing trustworthy to compare a fetched release against, so no
    /// network round trip is warranted (spec §2).
    public func check() async -> UpdateCheckResult {
        guard let currentVersion, let current = AppVersion(currentVersion) else {
            return .unknownLocalVersion
        }

        do {
            let release = try await fetcher.latestRelease()
            guard let latest = AppVersion(release.tag) else {
                return .failed(.malformedResponse)
            }
            if latest > current {
                return .updateAvailable(latest: latest, current: current, url: release.url)
            }
            return .upToDate(current: current)
        } catch let error as UpdateCheckError {
            // The fetcher already classified this failure — pass it through
            // unchanged.
            return .failed(error)
        } catch {
            // Any other thrown error (a fetcher implementation that doesn't
            // map to `UpdateCheckError`) is reported as offline rather than
            // leaking an untyped error (spec §2).
            return .failed(.offline)
        }
    }
}
