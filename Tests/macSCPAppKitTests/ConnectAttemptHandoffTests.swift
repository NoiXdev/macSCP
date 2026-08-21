import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the Critical fix-round-2 finding end to end: cancelling a connect
/// attempt DURING the App-layer hand-off window — after `ConnectionViewModel
/// .connect()` has already returned successfully, while `await fs
/// .homeDirectoryPath()` is still running — must not set a session, must
/// not persist a `StoredSession`, and must not write a keychain secret.
///
/// The review that found this measured it precisely: `ConnectionViewModel
/// .state` reaches `.idle` the moment `connect()` returns (its own success
/// path), well before the caller's remaining work finishes, so
/// `cancelConnecting()`'s `state == .connecting` guard (fix round 1's
/// shape) made Cancel a no-op in this exact window — the abandoned dial's
/// own `fs` still reached `startSession` unconditionally, which (with
/// "save as session" on) persists a NEW `StoredSession` and writes its
/// secret to the keychain. Fix round 2 closes it on the App side with
/// `SessionTab.reconnectAttempt`, captured by the caller BEFORE this
/// window and checked immediately before `startSession` at both call
/// sites (`ContentView.connect(in:stored:)` and `ContentView
/// .handleAdHocConnected(_:in:attempt:)`, split out of the ad-hoc form's
/// `onConnected` closure specifically so this suite can drive it directly
/// — the same move `LivenessGiveUpOrderingTests` made for
/// `handleLivenessGiveUp(_:)`).
///
/// **Isolation, round 2.** An earlier version of this suite tried to
/// reassign `view.sessionListViewModel` (an ordinary, non-`private`
/// `@State` property) AFTER constructing `ContentView`, to redirect it away
/// from the real Keychain/session store. That reassignment silently did
/// not persist — reading it back, even with no intervening call, still
/// returned the value `ContentView.init` built — so the mutation-proof
/// pass for this suite's fix (deliberately removing the new guard to watch
/// the test go red) ran against the REAL, unmodified stores and wrote a
/// real entry into this machine's real `sessions-v2.json` and a real
/// keychain item under service `dev.noix.macSCP`, both cleaned up by hand
/// afterward. `ContentView.init` now takes an optional `sessionListViewModel`
/// parameter (defaulting to `nil`, which preserves the real Keychain-backed
/// construction byte for byte — see that initializer's own doc comment) —
/// every test below passes a fresh one backed by a temporary directory and
/// `RecordingSecretStore`, an in-memory `SecretStore`. With this seam the
/// real stores are never constructed by anything this suite runs, mutation
/// experiment included; `theRealSessionsFileIsNeverTouched` below proves
/// that empirically rather than resting on that architectural claim alone.
@Suite("Connect attempt hand-off")
@MainActor
struct ConnectAttemptHandoffTests {
    /// The ONE real, on-disk file this whole suite must never write —
    /// `~/Library/Application Support/macSCP/sessions-v2.json` (or
    /// `MACSCP_STORAGE_DIRECTORY`'s override, if the environment sets one —
    /// see `SessionStore.defaultDirectory`'s own doc comment; matching that
    /// exact resolution here is what makes this snapshot correct under a
    /// gated CI run too, not just on a developer machine).
    private static var realSessionsFileURL: URL {
        SessionStore.defaultDirectory.appendingPathComponent("sessions-v2.json")
    }

    /// Read as raw bytes, not parsed — a byte-for-byte comparison is the
    /// strongest available claim ("nothing whatsoever changed"), and it
    /// costs nothing extra over parsing. `nil` (file absent) is itself a
    /// valid, comparable snapshot: a fresh machine or CI runner that has
    /// never saved a session has no such file, and that absence must
    /// survive this suite too.
    private func snapshotRealSessionsFile() -> Data? {
        try? Data(contentsOf: Self.realSessionsFileURL)
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    /// Same shape as `LivenessGiveUpOrderingTests.makeContentView()`, plus
    /// the isolation seam: a fresh `SessionListViewModel` pointed entirely
    /// at a temporary directory and `secrets`, passed to `ContentView.init`
    /// so it becomes the `@State` property's INITIAL value rather than a
    /// later reassignment (see this file's own top-level doc comment for
    /// why that distinction is what makes the seam actually work). No live
    /// window or rendering involved; `body` is never called, only plain
    /// methods (`connect(in:stored:)`, `handleAdHocConnected`, `teardown(_:)`).
    private func makeContentView(secrets: RecordingSecretStore, storeDirectory: URL) -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: storeDirectory),
            secrets: secrets,
            auditStore: AuditLogStore(directory: storeDirectory.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: storeDirectory),
            keys: ManagedKeyStore(directory: storeDirectory))
        let view = ContentView(
            settingsStore: SettingsStore(directory: settingsDir),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel)
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
        })
    }

    /// Same shape as `LivenessGiveUpOrderingTests.makeTab()`, parameterized
    /// on the connector so each test can hand back its own `HangingHome
    /// DirectoryFileSystem`.
    private func makeTab(connector: @escaping ConnectionViewModel.Connector) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: connector),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Polls `condition` until it holds, failing with `description` after
    /// `timeout` rather than letting the run hang — same reasoning as
    /// `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`'s own
    /// `waitUntil` (not shared: separate test targets, `macSCPAppKitTests`
    /// does not depend on `macSCPCoreTests` — see `Package.swift`).
    @discardableResult
    private func waitUntil(
        _ description: Comment, timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var satisfied = await condition()
        while !satisfied, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            satisfied = await condition()
        }
        #expect(satisfied, description, sourceLocation: sourceLocation)
        return satisfied
    }

    // MARK: - Isolation proof, demonstrated rather than asserted

    /// Runs BOTH end-to-end tests below (they are otherwise independent —
    /// duplicating the run here would just mean the fix runs twice for one
    /// proof) and confirms the one file this suite must never write is
    /// byte-for-byte identical before and after, using `Data`'s own
    /// `Equatable` conformance across BOTH states a real machine can be in:
    /// the file already exists (a developer's machine with saved sessions,
    /// matching what fix round 2's incident actually hit) and the file does
    /// not exist yet (a fresh CI runner) — snapshotting `nil` in the second
    /// case and comparing `nil == nil` afterward covers it too.
    @Test func theRealSessionsFileIsNeverTouched() async {
        let before = snapshotRealSessionsFile()
        await runStoredSessionHandoffScenario()
        await runAdHocHandoffScenario()
        let after = snapshotRealSessionsFile()
        #expect(before == after, """
            the real on-disk session store changed while this suite ran — \
            exactly the fix-round-2 incident this test exists to catch. \
            `before` had \(before?.count.description ?? "no file"), \
            `after` had \(after?.count.description ?? "no file").
            """)
    }

    // MARK: - The two end-to-end proofs

    @Test func cancelDuringHomeDirectoryLookupPreventsTheStoredSessionHandoff() async {
        await runStoredSessionHandoffScenario()
    }

    @Test func cancelDuringHomeDirectoryLookupPreventsTheAdHocHandoffAndAnyKeychainWrite() async {
        await runAdHocHandoffScenario()
    }

    // MARK: - Scenarios (shared by the isolation-proof test and their own direct tests)

    private func runStoredSessionHandoffScenario() async {
        let workDir = makeTempDirectory("stored-handoff")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let secrets = RecordingSecretStore()
        let (view, cleanup) = makeContentView(secrets: secrets, storeDirectory: workDir)
        defer { cleanup() }

        let gate = HomeDirLookupGate()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let fs = HangingHomeDirectoryFileSystem(stream: stream, gate: gate)
        let tab = makeTab(connector: { _, _ in fs })
        // `authKind: .agent` needs neither a typed password nor a keychain
        // lookup to pass `ConnectionViewModel`'s own pre-dial validation —
        // see `ConnectionViewModelTests
        // .agentAuthSkipsPasswordAndKeyPathValidationAndBuildsAgentAuth`
        // (Core). A `.password` config here would fail validation before
        // ever reaching the connector, since this fresh `StoredSession`'s
        // random id has no entry in `secrets` — measured directly while
        // building this test (`fillForm` filled a blank password, and
        // `connect()` failed with "Password must not be empty." before the
        // fake connector was ever called).
        let stored = StoredSession(
            name: "handoff-stored", kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))

        view.connect(in: tab, stored: stored)

        guard await waitUntil("homeDirectoryPath() must be reached", {
            await gate.callCount == 1
        }) else {
            continuation.finish()
            return
        }

        // Cancel — the exact statements `ConnectingAttemptView`'s
        // `onCancel` runs (`ContentView+Detail.swift`), reproduced here
        // since there is no rendering harness to click the real button.
        tab.connectionViewModel.cancelConnecting()
        tab.reconnectAttempt = UUID()
        tab.isReconnecting = false
        await view.teardown(tab)

        // The abandoned dial "succeeds" now, in the true background.
        continuation.finish()
        guard await waitUntil("the abandoned attempt must finish resuming past its own await", {
            await gate.returnCount == 1
        }) else { return }

        #expect(tab.session == nil, "a cancelled attempt must not set a session")
        #expect(tab.activeStoredSessionID == nil, "a cancelled attempt must not adopt the stored session's id")
        #expect(tab.isReconnecting == false, "the reconnect lock must not be left stuck after Cancel")
        #expect(view.sessionListViewModel.sessions.isEmpty, "a cancelled attempt must not persist a StoredSession")
        #expect(secrets.storedIDs.isEmpty, "a cancelled attempt must not write a keychain-equivalent secret")
    }

    private func runAdHocHandoffScenario() async {
        let workDir = makeTempDirectory("adhoc-handoff")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let secrets = RecordingSecretStore()
        let (view, cleanup) = makeContentView(secrets: secrets, storeDirectory: workDir)
        defer { cleanup() }

        let gate = HomeDirLookupGate()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let fs = HangingHomeDirectoryFileSystem(stream: stream, gate: gate)
        let tab = makeTab(connector: { _, _ in fs })
        let form = tab.connectionViewModel
        form.host = "example.com"
        form.port = "22"
        form.username = "tim"
        form.password = "geheim-adhoc"
        // "Save as session" ON, with a password — the exact configuration
        // whose keychain-equivalent write this test exists to rule out.
        // Safe with the injected `secrets`/`workDir` above regardless of
        // whether the guard below holds — this is precisely what makes a
        // real red/green mutation experiment against THIS test safe, unlike
        // fix round 2's first attempt.
        form.shouldSaveSession = true
        form.saveName = "adhoc-handoff-save"

        // The ad-hoc form's own two-step hand-off (`ConnectionFormView`'s
        // Connect button, then `ContentView.detail`'s `onConnected`
        // closure), reproduced in the exact order and with the exact
        // capture-before-await shape the real code uses — see
        // `ContentView+Detail.swift`'s `onConnected` closure. What actually
        // runs the guard is the REAL `handleAdHocConnected`, not a copy of
        // its logic.
        let myAttempt = tab.reconnectAttempt
        let task = Task { @MainActor in
            guard let connectedFS = await form.connect() else { return }
            await view.handleAdHocConnected(connectedFS, in: tab, attempt: myAttempt)
        }

        guard await waitUntil("homeDirectoryPath() must be reached", {
            await gate.callCount == 1
        }) else {
            continuation.finish()
            _ = await task.value
            return
        }

        tab.connectionViewModel.cancelConnecting()
        tab.reconnectAttempt = UUID()
        tab.isReconnecting = false
        await view.teardown(tab)

        continuation.finish()
        _ = await task.value

        #expect(tab.session == nil, "a cancelled ad-hoc attempt must not set a session")
        #expect(view.sessionListViewModel.sessions.isEmpty, """
            a cancelled ad-hoc attempt must not persist a NEW StoredSession \
            — `shouldSaveSession` was on, so this is the assertion that \
            actually distinguishes the fix from the bug on this path.
            """)
        #expect(secrets.storedIDs.isEmpty, """
            a cancelled ad-hoc attempt must not write ANY keychain-equivalent \
            secret — the assertion the review named as the one that matters \
            most, now checkable against `RecordingSecretStore` instead of \
            the real Keychain.
            """)
    }
}

/// Counts how many times `HangingHomeDirectoryFileSystem.homeDirectoryPath()`
/// has been CALLED and how many times it has RETURNED (after the test
/// releases its stream) — an actor so both counters are safe to read from
/// the test's polling loop while the fake's own `async` method runs
/// concurrently with it.
private actor HomeDirLookupGate {
    private(set) var callCount = 0
    private(set) var returnCount = 0
    func markCalled() { callCount += 1 }
    func markReturned() { returnCount += 1 }
}

/// A `RemoteFileSystem` whose `homeDirectoryPath()` hangs on `stream` until
/// the test finishes it — the exact window (connect() already returned
/// successfully, the caller's own remaining `await` still running) the
/// fix-round-2 review measured. Every other requirement is unreached by
/// the tests in this file and traps if ever called, so a future change
/// that routes through one of them fails loudly instead of silently
/// passing — same idiom as `LivenessProbeRaceTests.NeverRespondingFileSystem`.
private struct HangingHomeDirectoryFileSystem: RemoteFileSystem {
    let stream: AsyncStream<Void>
    let gate: HomeDirLookupGate

    func list(path: String) async throws -> [RemoteFileItem] {
        fatalError("not exercised by this test")
    }

    func stat(path: String) async throws -> RemoteFileItem {
        fatalError("not exercised by this test")
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("not exercised by this test")
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        fatalError("not exercised by this test")
    }

    func delete(path: String) async throws {
        fatalError("not exercised by this test")
    }

    func createDirectory(at path: String) async throws {
        fatalError("not exercised by this test")
    }

    func rename(from: String, to: String) async throws {
        fatalError("not exercised by this test")
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }

    func deleteTree(at path: String) async throws {
        fatalError("not exercised by this test")
    }

    func homeDirectoryPath() async throws -> String {
        await gate.markCalled()
        for await _ in stream {}   // hangs until the test releases it
        await gate.markReturned()
        return "/home/handoff-test"
    }

    func disconnect() async {}
}

/// Test double for `SecretStore`, local to this file — `macSCPAppKitTests`
/// does not depend on `macSCPCoreTests` (separate SwiftPM test targets,
/// see `Package.swift`), so `Tests/macSCPCoreTests/InMemorySecretStore.swift`
/// is not importable here. Records every write so a test can assert NONE
/// happened, which is the one thing a lookup by id cannot prove on its
/// own — `storedIDs` answers "did anything get written anywhere", not just
/// "was this one specific id touched".
private final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[sessionID] = nil
    }

    var storedIDs: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(storage.keys)
    }
}
