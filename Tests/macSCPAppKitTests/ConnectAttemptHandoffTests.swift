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
/// afterward. `ContentView.init` now takes optional `sessionListViewModel`/
/// `secretStore`/`managedKeyStore` parameters (all defaulting to `nil`,
/// which preserves the real Keychain-backed construction byte for byte —
/// see that initializer's own doc comment) — every test below passes a
/// fresh `SessionListViewModel` backed by a temporary directory and
/// `RecordingSecretStore`, an in-memory `SecretStore`.
///
/// **Isolation, round 3 — the snapshot itself was vacuous.** The FIRST
/// version of `theRealSessionsFileIsNeverTouched` compared the real
/// session file's raw bytes before and after, using fixed save names
/// ("handoff-stored", "adhoc-handoff-save"). That is exactly what the
/// round-2 incident had already written into the real file BY THOSE SAME
/// NAMES — and `SessionListViewModel.save(name:...)` upserts by NAME,
/// reusing the existing entry's id and overwriting it with the identical
/// field values this suite always sends. Measured directly: a broken seam
/// re-running against the real store produced byte-IDENTICAL JSON while a
/// real secret was written under that reused id — the exact incident the
/// test exists to catch, passing vacuously through it. Every save name
/// below now embeds a fresh `UUID` per test run, so a real write — if the
/// seam were ever bypassed — can never land on a name the real file
/// already has; it can only ever APPEND a new, distinct entry, which no
/// byte comparison can mistake for "nothing changed".
/// `theSaveNamesUsedByThisRunNeverAppearInTheRealFile` below checks that
/// directly, by NAME, as a second, independent signal
/// from the byte comparison — parsed via `SessionStore`'s own real reader,
/// which is a READ, not a write, and therefore safe regardless of what a
/// broken seam did.
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

    /// Read as raw bytes, not parsed — a byte-for-byte comparison is a
    /// strong general-purpose claim ("nothing whatsoever changed"), and it
    /// costs nothing extra over parsing. `nil` (file absent) is itself a
    /// valid, comparable snapshot: a fresh machine or CI runner that has
    /// never saved a session has no such file, and that absence must
    /// survive this suite too. NOT sufficient on its own against an
    /// upsert-by-name rewrite that happens to reproduce identical bytes —
    /// see this file's own top-level doc comment, "Isolation, round 3" —
    /// which is why every save name below is unique per run and a second,
    /// name-based check runs alongside this one.
    private func snapshotRealSessionsFile() -> Data? {
        try? Data(contentsOf: Self.realSessionsFileURL)
    }

    /// A run-unique save name — every scenario below uses one of these
    /// instead of a fixed string, specifically so a real write (if the
    /// seam were ever bypassed) cannot land on a name the real file
    /// already has and disappear into an upsert. See this file's own
    /// top-level doc comment, "Isolation, round 3".
    private func uniqueSaveName(_ label: String) -> String {
        "\(label)-\(UUID().uuidString)"
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    /// Same shape as `LivenessGiveUpOrderingTests.makeContentView()`, plus
    /// the isolation seam: a fresh `SessionListViewModel` pointed entirely
    /// at a temporary directory and `secrets`, and `secrets`/a temp-
    /// directory `ManagedKeyStore` ALSO passed as `ContentView.init`'s own
    /// `secretStore:`/`managedKeyStore:` parameters (fix round 3, review
    /// item "the seam is only half there") — one shared isolated secret
    /// store for the whole window, not two that could silently disagree.
    /// Passed to `ContentView.init` so all three become the `@State`
    /// property's (and the two `let` properties') INITIAL values rather
    /// than a later reassignment (see this file's own top-level doc
    /// comment for why that distinction is what makes the seam actually
    /// work). No live window or rendering involved; `body` is never
    /// called, only plain methods (`connect(in:stored:)`,
    /// `handleAdHocConnected`, `teardown(_:)`).
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
            sessionListViewModel: sessionListViewModel,
            secretStore: secrets,
            managedKeyStore: ManagedKeyStore(directory: storeDirectory))
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

    /// Runs BOTH end-to-end scenarios below (they are otherwise
    /// independent — duplicating the run here would just mean the fix
    /// runs twice for one proof) and confirms the one file this suite
    /// must never write is byte-for-byte identical before and after,
    /// using `Data`'s own `Equatable` conformance across BOTH states a
    /// real machine can be in: the file already exists (a developer's
    /// machine with saved sessions, matching what the fix-round-2 incident
    /// actually hit) and the file does not exist yet (a fresh CI runner) —
    /// snapshotting `nil` in the second case and comparing `nil == nil`
    /// afterward covers it too.
    ///
    /// A general-purpose signal, not the whole proof by itself — see
    /// `theSaveNamesUsedByThisRunNeverAppearInTheRealFile` below for the
    /// targeted one this file's own incident required.
    @Test func theRealSessionsFileIsNeverTouched() async {
        let before = snapshotRealSessionsFile()
        _ = await runStoredSessionHandoffScenario()
        _ = await runAdHocHandoffScenario()
        let after = snapshotRealSessionsFile()
        #expect(before == after, """
            the real on-disk session store changed while this suite ran — \
            exactly the fix-round-2 incident this test exists to catch. \
            `before` had \(before?.count.description ?? "no file"), \
            `after` had \(after?.count.description ?? "no file").
            """)
    }

    /// The targeted proof fix round 3 added: parses the REAL session file
    /// through `SessionStore`'s own reader (a READ, never a write — safe
    /// regardless of what a broken seam did) and confirms neither run-
    /// unique save name this suite generated appears in it. Unlike a raw
    /// byte comparison, this cannot be defeated by an upsert that happens
    /// to reproduce identical bytes — see this file's own top-level doc
    /// comment, "Isolation, round 3", for the exact incident that made
    /// this check necessary rather than merely thorough.
    @Test func theSaveNamesUsedByThisRunNeverAppearInTheRealFile() async {
        let storedName = await runStoredSessionHandoffScenario()
        let adHocName = await runAdHocHandoffScenario()
        let realNames = Set((try? SessionStore(directory: SessionStore.defaultDirectory).all().map(\.name)) ?? [])
        #expect(!realNames.contains(storedName), """
            the stored-session scenario's run-unique save name \
            "\(storedName)" appears in the real session store — a real \
            write reached it.
            """)
        #expect(!realNames.contains(adHocName), """
            the ad-hoc scenario's run-unique save name "\(adHocName)" \
            appears in the real session store — a real write reached it.
            """)
    }

    // MARK: - The three end-to-end proofs

    @Test func cancelDuringHomeDirectoryLookupPreventsTheStoredSessionHandoff() async {
        _ = await runStoredSessionHandoffScenario()
    }

    @Test func cancelDuringHomeDirectoryLookupPreventsTheAdHocHandoffAndAnyKeychainWrite() async {
        _ = await runAdHocHandoffScenario()
    }

    /// Positive proof for the fix-round-4 seam (review item "the seam still
    /// has a hole, on the path your own suite drives"): `ContentView
    /// .fillForm(_:from:)`'s private-key-auth branch used to build its own
    /// `ManagedKeyStore(directory: SessionStore.defaultDirectory)`/
    /// `KeychainSecretStore()` inline, reachable through `connect(in:
    /// stored:)` — the same call path `runStoredSessionHandoffScenario`
    /// drives, just not with `.privateKey` auth, which is why that test
    /// alone never exercised this branch. This test resolves a managed
    /// key's passphrase end to end THROUGH the injected `managedKeyStore`/
    /// `secretStore` `makeContentView` supplies and confirms the resolved
    /// value is the one planted in `RecordingSecretStore` — proving data
    /// actually flows through the seam, not merely that nothing crashes.
    /// Calls `fillForm` directly (a plain, non-`async`, throwing method) —
    /// no need for the hang/cancel machinery the other two tests use, since
    /// this fix is entirely inside that one function.
    @Test func fillFormResolvesAManagedKeyPassphraseThroughTheInjectedStoresOnly() throws {
        let workDir = makeTempDirectory("managed-key-seam")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let secrets = RecordingSecretStore()
        let (view, cleanup) = makeContentView(secrets: secrets, storeDirectory: workDir)
        defer { cleanup() }

        // Planted directly into the SAME temp directory `makeContentView`
        // gave `view`'s own `managedKeyStore` — a second `ManagedKeyStore`
        // value sharing that directory's on-disk files, the same way two
        // `SessionStore` values sharing a directory already do elsewhere in
        // this suite.
        let managedKeyStore = ManagedKeyStore(directory: workDir)
        let keyFileName = "seam-test-key"
        let key = ManagedKey(
            name: "seam test key", comment: "", type: .ed25519,
            fingerprint: "SHA256:seam-test", publicKeyOpenSSH: "ssh-ed25519 AAAAseamtest",
            createdAt: Date(), hasPassphrase: true, fileName: keyFileName)
        try managedKeyStore.add(key)
        try secrets.savePassword("seam-managed-passphrase", for: key.id)

        let keyPath = managedKeyStore.keyDirectory.appendingPathComponent(keyFileName).path(percentEncoded: false)
        let stored = StoredSession(
            name: uniqueSaveName("managed-key-seam"), kind: .ssh,
            ssh: StoredSSHConfig(
                host: "example.com", username: "tim", authKind: .privateKey, keyPath: keyPath))
        let form = ConnectionViewModel(connector: { _, _ in
            fatalError("not exercised by this test — fillForm never dials")
        })

        _ = try view.fillForm(form, from: stored)

        #expect(form.password == "seam-managed-passphrase", """
            fillForm's private-key branch must resolve the managed key's             passphrase through the INJECTED managedKeyStore/secretStore             ContentView.init now takes, not the real ones it built inline             before this fix.
            """)
    }

    // MARK: - Scenarios (shared by the isolation-proof tests and their own direct tests)

    /// Returns the run-unique save name this scenario used, so a caller
    /// can check for its absence from the real store.
    @discardableResult
    private func runStoredSessionHandoffScenario() async -> String {
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
        let name = uniqueSaveName("handoff-stored")
        let stored = StoredSession(
            name: name, kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))

        view.connect(in: tab, stored: stored)

        guard await waitUntil("homeDirectoryPath() must be reached", {
            await gate.callCount == 1
        }) else {
            continuation.finish()
            return name
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
        }) else { return name }

        #expect(tab.session == nil, "a cancelled attempt must not set a session")
        #expect(tab.activeStoredSessionID == nil, "a cancelled attempt must not adopt the stored session's id")
        #expect(tab.isReconnecting == false, "the reconnect lock must not be left stuck after Cancel")
        #expect(view.sessionListViewModel.sessions.isEmpty, "a cancelled attempt must not persist a StoredSession")
        #expect(secrets.storedIDs.isEmpty, "a cancelled attempt must not write a keychain-equivalent secret")
        #expect(await gate.disconnectCount == 1, """
            the refused hand-off must close the connection it abandons — \
            left open, it would stay connected to the remote host until \
            the whole process exits (fix round 3, review-measured).
            """)
        return name
    }

    /// Returns the run-unique save name this scenario used, so a caller
    /// can check for its absence from the real store.
    @discardableResult
    private func runAdHocHandoffScenario() async -> String {
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
        // whether the guard below holds, and safe against the real store
        // specifically because `name` is run-unique — this is precisely
        // what makes a real red/green mutation experiment against THIS
        // test safe, unlike fix round 2's first attempt.
        form.shouldSaveSession = true
        let name = uniqueSaveName("adhoc-handoff-save")
        form.saveName = name

        // The ad-hoc form's own two-step hand-off (`ConnectionFormView`'s
        // Connect button, then `ContentView.detail`'s `onConnected`
        // closure), reproduced in the exact order and with the exact
        // capture-before-the-dial shape the real code uses (fix round 3:
        // `ConnectionFormView.currentReconnectAttempt` is read before
        // `viewModel.connect()` starts, not after — see that property's
        // own doc comment for why). What actually runs the guard is the
        // REAL `handleAdHocConnected`, not a copy of its logic.
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
            return name
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
        #expect(await gate.disconnectCount == 1, """
            the refused hand-off must close the connection it abandons — \
            left open, it would stay connected to the remote host until \
            the whole process exits (fix round 3, review-measured).
            """)
        return name
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
    /// How many times `HangingHomeDirectoryFileSystem.disconnect()` has
    /// been called — fix round 3 (review item "the gate discards a live
    /// connection without closing it"): the scenarios below assert this
    /// reaches exactly 1 after a cancelled hand-off, proving the refusal
    /// path actually closes the connection it abandons rather than merely
    /// not crashing.
    private(set) var disconnectCount = 0
    func markCalled() { callCount += 1 }
    func markReturned() { returnCount += 1 }
    func markDisconnected() { disconnectCount += 1 }
}

/// A `RemoteFileSystem` whose `homeDirectoryPath()` hangs on `stream` until
/// the test finishes it — the exact window (connect() already returned
/// successfully, the caller's own remaining `await` still running) the
/// fix-round-2 review measured. Every other requirement is unreached by
/// the tests in this file and traps if ever called, so a future change
/// that routes through one of them fails loudly instead of silently
/// passing — same idiom as `LivenessProbeRaceTests.NeverRespondingFileSystem`.
///
/// Fix round 3 (review item "the gate discards a live connection without
/// closing it"): `disconnect()` is deliberately NOT a `fatalError` here —
/// both `ContentView.handleAdHocConnected` and `ContentView.connect(in:
/// stored:)` now call it on the refusal path, and this suite's own
/// scenarios exercise exactly that path and assert on `gate
/// .disconnectCount` directly, proving the abandoned connection is
/// actually closed rather than merely not crashing.
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

    func disconnect() async {
        await gate.markDisconnected()
    }
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
