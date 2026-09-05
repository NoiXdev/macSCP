import Foundation
import Testing

@testable import macSCPCore

/// The five tests that MUST touch `DiagnosticLog.shared`, because the
/// production code under test — `LocalFileSystem`, `TransferEngine`,
/// `ConnectionViewModel`, `RemoteBrowserViewModel` — logs through that
/// exact singleton and cannot be pointed at a private instance instead
/// (`DiagnosticLog.swift`'s own call sites spell `DiagnosticLog.shared.log(`
/// directly). Every other diagnostic-log test lives in
/// `DiagnosticLogTests.swift` against its own, private `DiagnosticLog()`.
///
/// `DiagnosticLogSharedSinkIsolationGuardTests` holds this split in place:
/// this is the ONE file its scan lets mention `DiagnosticLog.shared`, on
/// the strength of the two things below.
///
/// **`.serialized` is load-bearing** — two of these five tests running at
/// once would each see the other's `configure` call on the one shared
/// instance.
///
/// **Never `DiagnosticLog.shared.currentFileURL`.** Diagnostic-log plan,
/// final fix round 2: the re-review traced an intermittent empty-file read
/// (round 1's own final-fix-report named it, unexplained, in its
/// "Not fixed" section) to exactly this property. `currentFileURL` reads
/// the LIVE, process-wide `directory`/`fileDayKey` fields at the moment it
/// is called — fields any OTHER suite's `configure(...)` on the same
/// `.shared` instance can overwrite. `ConnectionViewModelTests`/
/// `LocalFileSystemTests`/`TransferEngineTests` run in parallel with this
/// suite and carry no serialization of their own; a test in one of them
/// calling `DiagnosticLog.shared.configure(...)` — this file's own tests
/// are not the only callers of that method, `MacSCPApp.swift`'s own launch
/// path and any other suite reaching it would do the same — landing in the
/// gap between one of these five tests' own `await flush()` and its
/// FOLLOW-UP read of `currentFileURL` would point that read at a directory
/// or day key this test never wrote to. `flush()` itself was never the
/// bug: `markFlushed` only advances after `writeRun`'s synchronous write
/// returns, so by the time `flush()` resumes, this test's own lines are
/// provably on disk — SOMEWHERE. The bug was asking the singleton, a
/// SECOND time, after the fact, which directory that "somewhere" was.
///
/// The fix: every test below computes the path its own lines went to, out
/// of data it already holds — the directory it configured, and the day
/// key for a `now` it FIXES itself (`dayKeyText(for:timeZone:)`, matching
/// `DiagnosticLog`'s own private `yyyy-MM-dd` formatting, documented on
/// its class-level doc comment as the file-naming contract) — never by
/// reading the live singleton's state back.
@Suite("DiagnosticLog shared sink", .serialized, .timeLimit(.minutes(1)))
struct DiagnosticLogSharedSinkTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticLogSharedSinkTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileContents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// `DiagnosticLog`'s own (private) day-key format, reproduced here
    /// rather than read off the live singleton — see this suite's own doc
    /// comment for why `currentFileURL` is exactly the property round 2
    /// stopped calling. `yyyy-MM-dd`, Gregorian calendar, `en_US_POSIX`
    /// locale: the file-naming contract stated in `DiagnosticLog`'s own
    /// class doc comment (`~/Library/Logs/macSCP/macSCP-<yyyy-MM-dd>.log`)
    /// and already relied on verbatim by `DiagnosticLogTests
    /// .rotationPrunesOldFiles`'s hardcoded file names.
    private func dayKeyText(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The path this test's OWN lines went to: `logDirectory` is this
    /// test's own, private temp directory (never shared with another
    /// test), and `fixedNow` is the SAME instant this test passed to
    /// `configure(now:)` — so the day key here is guaranteed to match the
    /// one `DiagnosticLog` itself stamped the line with, with no dependency
    /// on the real clock or on reading the singleton's state back.
    private func ownFileURL(directory: URL, fixedNow: Date) -> URL {
        directory.appending(path: "macSCP-\(dayKeyText(for: fixedNow, timeZone: .current)).log")
    }

    /// `LocalFileSystem.list`'s own instrumentation (Task 3 of the
    /// diagnostic-log plan) — added here, in this `.serialized` suite that
    /// owns the process-wide singleton, rather than in `LocalFileSystemTests`:
    /// that suite runs its tests in parallel and carries no serialization of
    /// its own.
    ///
    /// `.debug`, not `.info`: admitting `.debug` is what makes the absence
    /// assertion below actually test the threshold logic — at `.info` an
    /// `entry slow` line could never appear regardless of whether the
    /// threshold check is right, and the absence would be trivially true.
    /// Three PLAIN files read well under `LocalFileSystem.slowEntryThreshold`
    /// (500 ms), so the negative (no `entry slow`) sits beside the positive
    /// (`list start`/`list done` ARE present) rather than standing alone.
    @Test("LocalFileSystem.list writes list start/done, with no entry-slow line for fast entries")
    func localFileSystemListWritesStartAndDoneWithoutAnEntrySlowLine() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

        let listedDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: listedDirectory) }
        for name in ["eins.txt", "zwei.txt", "drei.txt"] {
            try Data("x".utf8).write(to: listedDirectory.appendingPathComponent(name))
        }
        let listedPath = listedDirectory.path(percentEncoded: false)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .debug, directory: logDirectory, now: { fixedNow })
        _ = try await LocalFileSystem().list(path: listedPath)
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("list start path=\(listedPath)"))
        #expect(contents.contains("list done path=\(listedPath) count=3"))
        #expect(!contents.contains("entry slow"))
    }

    /// `TransferEngine.copyFile`'s own instrumentation, driven against
    /// `MockRemoteFileSystem` (no rig needed — the `transfer` lines are
    /// written by the engine itself, above the SFTP layer). Lives here for
    /// the same singleton reason as the `LocalFileSystem` test above.
    @Test("TransferEngine.copyFile writes transfer start/done")
    func transferEngineWritesStartAndDoneLines() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

        let content = Data("hallo".utf8)
        let source = MockRemoteFileSystem(
            tree: [
                "/": [
                    RemoteFileItem(
                        name: "quelle.bin", path: "/quelle.bin", kind: .file,
                        size: UInt64(content.count))
                ]
            ],
            files: ["/quelle.bin": content])
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            direction: .upload,
            onProgress: { _ in })
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("transfer start direction=up path=/ziel/quelle.bin"))
        #expect(contents.contains("transfer done path=/ziel/quelle.bin"))
    }

    /// `ConnectionViewModel.connect()`'s own instrumentation, driven against
    /// a fake connector (same shape `ConnectionViewModelTests.makeVM` uses)
    /// — no rig needed, since the connector itself never dials anything
    /// real. Lives here for the same singleton reason as the two tests
    /// above; `@MainActor` on the test itself, since `ConnectionViewModel`
    /// is `@MainActor`-isolated and this suite otherwise is not.
    @MainActor
    @Test("ConnectionViewModel.connect() writes connect start/done")
    func connectionViewModelWritesConnectStartAndDoneLines() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "geheim"

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        _ = await vm.connect()
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("connect start host=example.com port=22 kind=ssh"))
        #expect(contents.contains("connect done"))
    }

    // MARK: - Fix round 1: a mapped RemoteFSError's own reason never leaks

    /// `RemoteFSError.connectionFailed(reason:)`/`.protocolError(reason:)`
    /// carry FREE TEXT — `S3FileSystem`/`WebDAVFileSystem` build it out of
    /// the endpoint the user typed, a field that takes
    /// `scheme://KEY:SECRET@host` as ordinary input. `RemoteBrowserViewModel
    /// .message(for:path:)`/`load()` both route through `DialSupport
    /// .reason(for:)`, which drops the reason for exactly these two cases.
    ///
    /// The planted secret lives in a named constant, and both checks below
    /// compute their `Bool` BEFORE the expectation (CLAUDE.md "A value a
    /// test must not leak has two exits"): `#expect` reports the SOURCE
    /// TEXT of the expression it checks, and Swift Testing's own rich diff
    /// prints the runtime VALUE of a failing subexpression — writing
    /// `#expect(!message.contains(secret))` directly would print `message`
    /// itself, secret included, into the failure output exactly when the
    /// test is red. `inMessage`/`inLog` carry only the answer, never the
    /// string that was searched.
    @MainActor
    @Test("a connectionFailed reason never reaches the browser message or the log")
    func connectionFailedReasonNeverReachesMessageOrLog() async throws {
        let secret = "AKIA:hunter2@example"
        let leakingReason = "Invalid S3 endpoint: https://\(secret)"
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

        let fs = MockRemoteFileSystem(tree: [:])
        await fs.setListFailure(RemoteFSError.connectionFailed(reason: leakingReason))
        let vm = RemoteBrowserViewModel(fs: fs, startPath: "/", logCategory: "browser.remote")

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        await vm.load()
        await DiagnosticLog.shared.flush()

        // The positive beside the negative below (CLAUDE.md, "Guards that
        // name what they watch"): without it, an `RemoteBrowserViewModel`
        // that stopped reaching `.failed` at all — the vacuous case this
        // `if`/`else` falls into — would still read `inMessage == false`
        // (`message` is `""`, and `""` never contains `secret`), passing
        // while the very state transition under test had silently broken.
        let stateIsFailed: Bool
        let message: String
        if case .failed(let bannerText) = vm.state {
            stateIsFailed = true
            message = bannerText
        } else {
            stateIsFailed = false
            message = ""
        }
        #expect(stateIsFailed)
        let inMessage = message.contains(secret)
        #expect(inMessage == false)

        let logText = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        let inLog = logText.contains(secret)
        #expect(inLog == false)
    }

    // MARK: - Final whole-plan review: the connect line drops endpoint userinfo

    /// Final whole-plan review, Critical: `ConnectionViewModel
    /// .connectLogFields` interpolated `s3.endpoint`/`webdav.baseURL`
    /// verbatim into `connect start host=…` — free text a user types into
    /// the endpoint field, which takes `scheme://KEY:SECRET@host` as
    /// ordinary input no schema here strips (`ConnectFailureSecrecyTests`).
    /// A stored S3 session whose endpoint carries a credential would
    /// otherwise write that credential straight into the diagnostic log's
    /// `connect start` line. The fix routes both `s3.endpoint` and
    /// `webdav.baseURL` through `URLText.withoutUserinfo` before they reach
    /// the log call; this test drives the S3 side end to end, through
    /// `ConnectionViewModel.connect()` itself, rather than the helper in
    /// isolation.
    ///
    /// The secret lives in a named constant, and both checks below compute
    /// their `Bool` before the expectation, for the same reason
    /// `connectionFailedReasonNeverReachesMessageOrLog` above does:
    /// `#expect` prints the source text of a failing expression, and
    /// `contents.contains(secret)` written directly would print `contents`
    /// — secret included — into the failure output exactly when the test
    /// is red. The negative sits beside a positive: the host name itself
    /// must still reach the line, or the fix would be indistinguishable
    /// from silently dropping `host=` altogether.
    @MainActor
    @Test("ConnectionViewModel.connect() drops the S3 endpoint's userinfo from the connect start line")
    func connectStartLineDropsS3EndpointUserinfo() async throws {
        let secret = "AKIAEXAMPLE:hunter2"
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.kind = .s3
        vm.s3AccessKeyID = "AKIAEXAMPLE"
        vm.s3SecretAccessKey = "shh-secret"
        vm.s3Region = "eu-central-1"
        vm.s3Endpoint = "https://\(secret)@s3.example.test"
        vm.s3Bucket = "my-bucket"
        vm.s3UsePathStyle = true

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        _ = await vm.connect()
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        let inLog = contents.contains(secret)
        #expect(inLog == false)

        let hostStillPresent = contents.contains("s3.example.test")
        #expect(hostStillPresent)
    }
}
