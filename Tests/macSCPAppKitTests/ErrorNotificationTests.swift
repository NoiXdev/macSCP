import Foundation
import MacSCPTestSupport
import Testing
import UserNotifications

@testable import MacSCPAppKit
@testable import macSCPCore

/// macOS notifications for a lost connection, a failed transfer and a failed
/// forwarding (next build of 2026-09-17, Task 7).
///
/// Nothing here reaches `UNUserNotificationCenter`: every notifier below is
/// built over `RecordingPoster`, and the live poster is never constructed.
/// The decisions — whether to post, whether an event is a repeat, which
/// text — are `ErrorNotificationPlan`'s, tested as tables; the three hooks
/// are driven through the real functions that own them
/// (`ContentView.handleLivenessGiveUp(_:)`,
/// `ContentView.notifyTransferFailures()`, `TunnelManager`'s state mirror).
@Suite("Error notifications", .timeLimit(.minutes(1)))
@MainActor
struct ErrorNotificationTests {

    // MARK: - Fakes and fixtures

    @MainActor
    final class RecordingPoster: UserNotificationPosting {
        struct Posted: Equatable {
            let title: String
            let body: String
        }
        private(set) var posted: [Posted] = []
        func post(title: String, body: String) {
            posted.append(Posted(title: title, body: body))
        }
    }

    @MainActor
    final class NameRecorder {
        var names: [String] = []
    }

    /// The app is frontmost unless a test says otherwise, so a post in a
    /// test is caused by the window rule, not by an inactive test runner.
    @MainActor
    final class AppActivity {
        var isActive = true
    }

    private static func notifier(
        _ poster: RecordingPoster, activity: AppActivity = AppActivity()
    ) -> ErrorNotifier {
        ErrorNotifier(poster: poster, appIsActive: { activity.isActive })
    }

    private static func title(_ event: ErrorNotificationEvent) -> String {
        ErrorNotificationPlan.text(for: event, name: "x").title
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-notify-\(label)-\(UUID().uuidString)")
    }

    /// A `ContentView` isolated the way `LivenessGiveUpOrderingTests` builds
    /// one, with a recording notifier and its settings store handed back.
    /// `poster: nil` hands in no notifier at all, the way every other suite
    /// builds one.
    private func makeContentView(poster: RecordingPoster?) -> (
        view: ContentView, settings: SettingsStore, sessions: SessionListViewModel,
        cleanup: () -> Void
    ) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let workDir = makeTempDirectory("sessions")
        let settings = SettingsStore(directory: settingsDir)
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: workDir),
            secrets: NothingStoredSecretStore(),
            auditStore: AuditLogStore(directory: workDir.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: workDir),
            keys: ManagedKeyStore(directory: workDir))
        let view = ContentView(
            settingsStore: settings,
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel,
            secretStore: NothingStoredSecretStore(),
            managedKeyStore: ManagedKeyStore(directory: workDir),
            errorNotifier: poster.map { Self.notifier($0) })
        return (view, settings, sessionListViewModel, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
            try? FileManager.default.removeItem(at: workDir)
        })
    }

    /// Same shape as `LivenessGiveUpOrderingTests.attachSession(to:)`.
    private func attachSession(to tab: SessionTab, storedSessionID: UUID? = nil) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        tab.activeStoredSessionID = storedSessionID
        tab.liveness = .connected
    }

    /// Enqueues a download whose source does not exist, so the transfer
    /// itself fails (`.failed`, "not found") — no network, and the only disk
    /// access is a failed open of a path under a fresh temporary directory.
    @discardableResult
    private func enqueueFailingTransfer(on tab: SessionTab, into directory: URL) -> UUID {
        let missing = directory.appendingPathComponent("missing-\(UUID().uuidString).txt")
        return tab.transferQueue.enqueue(
            fileName: missing.lastPathComponent, direction: .download,
            source: LocalFileSystem(), sourcePath: missing.path(percentEncoded: false),
            destination: LocalFileSystem(),
            destinationDirectory: directory.path(percentEncoded: false),
            onCompleted: nil)
    }

    // MARK: - The plan: whether to post

    /// Every row written out. `windowIsKey == nil` is an event no window
    /// owns (a forwarding): it posts only while the app is not frontmost.
    @Test func shouldPostTable() {
        struct Row {
            let enabled: Bool
            let appIsActive: Bool
            let windowIsKey: Bool?
            let posts: Bool
        }
        let rows: [Row] = [
            Row(enabled: true, appIsActive: false, windowIsKey: false, posts: true),
            Row(enabled: true, appIsActive: false, windowIsKey: true, posts: true),
            Row(enabled: true, appIsActive: false, windowIsKey: nil, posts: true),
            Row(enabled: true, appIsActive: true, windowIsKey: false, posts: true),
            Row(enabled: true, appIsActive: true, windowIsKey: true, posts: false),
            Row(enabled: true, appIsActive: true, windowIsKey: nil, posts: false),
            Row(enabled: false, appIsActive: false, windowIsKey: false, posts: false),
            Row(enabled: false, appIsActive: false, windowIsKey: true, posts: false),
            Row(enabled: false, appIsActive: false, windowIsKey: nil, posts: false),
            Row(enabled: false, appIsActive: true, windowIsKey: false, posts: false),
            Row(enabled: false, appIsActive: true, windowIsKey: true, posts: false),
            Row(enabled: false, appIsActive: true, windowIsKey: nil, posts: false),
        ]
        #expect(rows.count == 12)
        for row in rows {
            #expect(
                ErrorNotificationPlan.shouldPost(
                    enabled: row.enabled, appIsActive: row.appIsActive,
                    windowIsKey: row.windowIsKey) == row.posts,
                "enabled=\(row.enabled) active=\(row.appIsActive) key=\(String(describing: row.windowIsKey))")
        }
    }

    // MARK: - The plan: repeats

    @Test func aForwardingNotifiesOnlyOnTheTransitionIntoFailed() {
        let failed = TunnelState.failed(.connectionLost)
        let otherFailure = TunnelState.failed(.portInUse(port: 8080))
        #expect(ErrorNotificationPlan.entersFailure(from: nil, to: failed))
        #expect(ErrorNotificationPlan.entersFailure(from: .stopped, to: failed))
        #expect(ErrorNotificationPlan.entersFailure(from: .active(connections: 1), to: failed))
        #expect(ErrorNotificationPlan.entersFailure(from: .reconnecting(attempt: 3), to: failed))
        #expect(ErrorNotificationPlan.entersFailure(from: .needsConfirmation, to: failed))
        // Still failed, with the same or another kind: a repeat.
        #expect(ErrorNotificationPlan.entersFailure(from: failed, to: failed) == false)
        #expect(ErrorNotificationPlan.entersFailure(from: failed, to: otherFailure) == false)
        // Not a failure at all.
        #expect(ErrorNotificationPlan.entersFailure(from: failed, to: .stopped) == false)
        #expect(ErrorNotificationPlan.entersFailure(from: nil, to: .reconnecting(attempt: 1)) == false)
        #expect(ErrorNotificationPlan.entersFailure(from: .active(connections: 0), to: .needsConfirmation) == false)
    }

    /// The maintainer's unit (Task 7 fix round 1): at most one "transfer
    /// failed" notification per tab until that tab's window next becomes
    /// key. Failures arriving across separate checks do not post again
    /// while the latch holds, and they are answered for: releasing the
    /// latch does not replay them.
    @Test func theTransferLatchPostsOnceUntilTheWindowBecomesKey() {
        var latch = ErrorNotificationPlan.TransferFailureLatch()
        var answers: [Bool] = []
        answers.append(latch.takeFailures(count: 0))   // nothing failed
        answers.append(latch.takeFailures(count: 1))   // posts
        latch.notificationPosted()
        answers.append(latch.takeFailures(count: 2))   // held
        answers.append(latch.takeFailures(count: 7))   // held
        latch.windowBecameKey()
        answers.append(latch.takeFailures(count: 7))   // nothing new since
        answers.append(latch.takeFailures(count: 8))   // posts again
        latch.notificationPosted()
        answers.append(latch.takeFailures(count: 9))   // held
        #expect(answers == [false, true, false, false, false, true, false])
    }

    /// A check that did not post — the setting off, or the window key —
    /// does not hold the latch: nobody was told, so the next new failure
    /// may post. The failures of that check are still answered for.
    @Test func theTransferLatchHoldsOnlyAfterAPost() {
        var latch = ErrorNotificationPlan.TransferFailureLatch()
        var answers: [Bool] = []
        answers.append(latch.takeFailures(count: 3))   // offered, not posted
        answers.append(latch.takeFailures(count: 3))   // answered for already
        answers.append(latch.takeFailures(count: 4))   // offered again
        answers.append(latch.takeFailures(count: 2))   // never goes back
        #expect(answers == [true, false, true, false])
    }

    // MARK: - The plan: text

    /// The title is the event's catalogue entry, and the body is the name
    /// and nothing else.
    @Test func theBodyIsTheNameAndTheTitleComesFromTheCatalogue() {
        let expectedTitles: [ErrorNotificationEvent: String] = [
            .connectionLost: L10n.string("notifications.connectionLost.title", "Connection lost"),
            .transferFailed: L10n.string("notifications.transferFailed.title", "Transfer failed"),
            .forwardingFailed: L10n.string(
                "notifications.forwardingFailed.title", "Port forwarding failed"),
        ]
        #expect(expectedTitles.count == ErrorNotificationEvent.allCases.count)
        for event in ErrorNotificationEvent.allCases {
            let text = ErrorNotificationPlan.text(for: event, name: "Staging box")
            #expect(text.title == expectedTitles[event])
            #expect(text.body == "Staging box")
        }
    }

    /// No stored session means no name: the body is a catalogue sentence,
    /// never the tab's "user@host" title.
    @Test func withoutANameTheBodyIsTheUnsavedConnectionEntry() {
        let unsaved = L10n.string("notifications.body.unsavedConnection", "Unsaved connection")
        #expect(ErrorNotificationPlan.text(for: .connectionLost, name: nil).body == unsaved)
        #expect(ErrorNotificationPlan.text(for: .transferFailed, name: "").body == unsaved)
    }

    // MARK: - The notifier

    @Test func theNotifierPostsThePlansTextOnce() {
        let poster = RecordingPoster()
        let activity = AppActivity()
        activity.isActive = false
        let notifier = Self.notifier(poster, activity: activity)

        notifier.notify(.forwardingFailed, name: "db tunnel", enabled: true, windowIsKey: nil)

        #expect(poster.posted == [
            .init(title: Self.title(.forwardingFailed), body: "db tunnel"),
        ])
    }

    @Test func theNotifierPostsNothingWithTheSettingOff() {
        let poster = RecordingPoster()
        let activity = AppActivity()
        activity.isActive = false
        let notifier = Self.notifier(poster, activity: activity)

        for event in ErrorNotificationEvent.allCases {
            notifier.notify(event, name: "n", enabled: false, windowIsKey: false)
        }
        #expect(poster.posted.isEmpty)

        // Positive control: the same calls with the setting on do post.
        for event in ErrorNotificationEvent.allCases {
            notifier.notify(event, name: "n", enabled: true, windowIsKey: false)
        }
        #expect(poster.posted.count == ErrorNotificationEvent.allCases.count)
    }

    @Test func theNotifierPostsNothingForTheKeyWindowOfTheFrontmostApp() {
        let poster = RecordingPoster()
        let notifier = Self.notifier(poster)   // app active

        notifier.notify(.connectionLost, name: "n", enabled: true, windowIsKey: true)
        notifier.notify(.forwardingFailed, name: "n", enabled: true, windowIsKey: nil)
        #expect(poster.posted.isEmpty)

        notifier.notify(.connectionLost, name: "n", enabled: true, windowIsKey: false)
        #expect(poster.posted.count == 1)
    }

    // MARK: - The live poster's foreground presentation

    /// Without a delegate answering `willPresent`, macOS shows nothing while
    /// the app is frontmost — and the plan posts for a background window of
    /// the frontmost app. The presenter answers banner plus list, and it
    /// really is the witness of the Objective-C requirement: an optional
    /// requirement a near-miss signature would leave unimplemented in
    /// silence, so this asks the runtime rather than the source.
    @Test func thePresenterShowsBannersWhileTheAppIsFrontmost() {
        #expect(ForegroundNotificationPresenter.presentationOptions == [.banner, .list])
        let selector = #selector(
            UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        #expect(ForegroundNotificationPresenter().responds(to: selector))
    }

    // MARK: - The default notifier

    /// A `ContentView` built without a notifier — every test that does not
    /// hand one in — gets a silent one, so no test reaches the live poster
    /// by omission. `MacSCPApp` hands the live one in.
    @Test func aContentViewBuiltWithoutANotifierIsSilent() {
        let (view, _, _, cleanup) = makeContentView(poster: nil)
        defer { cleanup() }
        let isSilent = view.errorNotifier.poster is SilentNotificationPoster
        #expect(isSilent)
        let isLive = view.errorNotifier.poster is UserNotificationCenterPoster
        #expect(isLive == false)
    }

    // MARK: - Hook 1: a lost connection

    @Test func givingUpPostsOneConnectionLostNotificationWithTheSessionName() async {
        let poster = RecordingPoster()
        let (view, _, sessions, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let stored = sessions.save(name: "Staging box", values: FieldValues(), password: "")
        #expect(stored != nil)
        let tab = view.tabsModel.activeTab
        attachSession(to: tab, storedSessionID: stored?.id)

        await view.handleLivenessGiveUp(tab)

        #expect(tab.liveness == .lost)
        #expect(poster.posted == [
            .init(title: Self.title(.connectionLost), body: "Staging box"),
        ])
    }

    @Test func givingUpOnAnUnsavedConnectionNamesNoHost() async {
        let poster = RecordingPoster()
        let (view, _, _, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let tab = view.tabsModel.activeTab
        attachSession(to: tab)
        tab.titleName = "tester@example.invalid"

        await view.handleLivenessGiveUp(tab)

        #expect(poster.posted.count == 1)
        let body = poster.posted.first?.body ?? ""
        let namesTheHost = body.contains("example.invalid")
        #expect(namesTheHost == false)
        #expect(body == L10n.string("notifications.body.unsavedConnection", "Unsaved connection"))
    }

    @Test func givingUpWithTheSettingOffPostsNothing() async {
        let poster = RecordingPoster()
        let (view, settings, _, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        settings.notificationsEnabled = false
        let tab = view.tabsModel.activeTab
        attachSession(to: tab)

        await view.handleLivenessGiveUp(tab)

        #expect(tab.liveness == .lost)   // the event happened
        #expect(poster.posted.isEmpty)
    }

    /// The drop marks the queue's items failed; the "transfer failed" hook
    /// must not answer for them a second time.
    @Test func aDropPostsConnectionLostAndNoTransferFailure() async {
        let poster = RecordingPoster()
        let (view, _, _, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let directory = makeTempDirectory("drop")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = view.tabsModel.activeTab
        attachSession(to: tab)
        let itemID = enqueueFailingTransfer(on: tab, into: directory)

        await view.handleLivenessGiveUp(tab)
        view.notifyTransferFailures()

        let status = tab.transferQueue.items.first { $0.id == itemID }?.status
        #expect(status == .failed(.connectionLost))
        #expect(tab.transferQueue.totalFailureCount == 1)
        #expect(poster.posted.map(\.title) == [Self.title(.connectionLost)])
    }

    // MARK: - Hook 2: a failed transfer

    @Test func aFailedTransferPostsOnceAndARepeatedCheckDoesNotRepost() async throws {
        let poster = RecordingPoster()
        let (view, _, sessions, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let directory = makeTempDirectory("transfer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = sessions.save(name: "Build server", values: FieldValues(), password: "")
        let tab = view.tabsModel.activeTab
        attachSession(to: tab, storedSessionID: stored?.id)

        enqueueFailingTransfer(on: tab, into: directory)
        try await pollUntil("the transfer failed") {
            tab.transferQueue.failureCountExcludingConnectionLoss == 1
        }
        view.notifyTransferFailures()
        view.notifyTransferFailures()

        #expect(poster.posted == [
            .init(title: Self.title(.transferFailed), body: "Build server"),
        ])

        // More failures, each seen by its own check — a folder transfer's
        // items failing across many updates: the latch holds, no repost.
        for expected in 2...4 {
            enqueueFailingTransfer(on: tab, into: directory)
            try await pollUntil("transfer \(expected) failed") {
                tab.transferQueue.failureCountExcludingConnectionLoss == expected
            }
            view.notifyTransferFailures()
        }
        #expect(poster.posted.count == 1)
    }

    /// The window becoming key is the user having seen it: the next failure
    /// posts again, and the failures before the release are not replayed.
    @Test func aFailureAfterTheWindowWasKeyPostsAgain() async throws {
        let poster = RecordingPoster()
        let (view, _, sessions, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let directory = makeTempDirectory("transfer-key")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = sessions.save(name: "Build server", values: FieldValues(), password: "")
        let tab = view.tabsModel.activeTab
        attachSession(to: tab, storedSessionID: stored?.id)

        for expected in 1...2 {
            enqueueFailingTransfer(on: tab, into: directory)
            try await pollUntil("transfer \(expected) failed") {
                tab.transferQueue.failureCountExcludingConnectionLoss == expected
            }
            view.notifyTransferFailures()
        }
        #expect(poster.posted.count == 1)

        view.transferNotificationWindowBecameKey()
        view.notifyTransferFailures()
        #expect(poster.posted.count == 1)   // nothing new since the release

        enqueueFailingTransfer(on: tab, into: directory)
        try await pollUntil("transfer 3 failed") {
            tab.transferQueue.failureCountExcludingConnectionLoss == 3
        }
        view.notifyTransferFailures()
        #expect(poster.posted == [
            .init(title: Self.title(.transferFailed), body: "Build server"),
            .init(title: Self.title(.transferFailed), body: "Build server"),
        ])
    }

    /// The latch is per tab: a second tab's failure posts its own
    /// notification while the first tab's latch holds.
    @Test func aSecondTabPostsItsOwnTransferFailure() async throws {
        let poster = RecordingPoster()
        let (view, _, sessions, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let directory = makeTempDirectory("transfer-tabs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = view.tabsModel.activeTab
        attachSession(
            to: first,
            storedSessionID: sessions.save(name: "Build server", values: FieldValues(), password: "")?.id)
        let second = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in throw CancellationError() }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
        view.tabsModel.addTab(second)
        attachSession(
            to: second,
            storedSessionID: sessions.save(name: "Mirror", values: FieldValues(), password: "")?.id)

        enqueueFailingTransfer(on: first, into: directory)
        try await pollUntil("the first tab's transfer failed") {
            first.transferQueue.failureCountExcludingConnectionLoss == 1
        }
        view.notifyTransferFailures()
        enqueueFailingTransfer(on: second, into: directory)
        try await pollUntil("the second tab's transfer failed") {
            second.transferQueue.failureCountExcludingConnectionLoss == 1
        }
        view.notifyTransferFailures()

        #expect(poster.posted == [
            .init(title: Self.title(.transferFailed), body: "Build server"),
            .init(title: Self.title(.transferFailed), body: "Mirror"),
        ])
    }

    @Test func aFailedTransferWithTheSettingOffPostsNothingLater() async throws {
        let poster = RecordingPoster()
        let (view, settings, _, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let directory = makeTempDirectory("transfer-off")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.notificationsEnabled = false
        let tab = view.tabsModel.activeTab
        attachSession(to: tab)

        enqueueFailingTransfer(on: tab, into: directory)
        try await pollUntil("the transfer failed") {
            tab.transferQueue.failureCountExcludingConnectionLoss == 1
        }
        view.notifyTransferFailures()
        #expect(poster.posted.isEmpty)

        // Turning the setting on afterwards does not replay the old failure.
        settings.notificationsEnabled = true
        view.notifyTransferFailures()
        #expect(poster.posted.isEmpty)

        // And the silent check held nothing (fix round 1): nobody was told,
        // so the next failure posts without waiting for the window to be key.
        enqueueFailingTransfer(on: tab, into: directory)
        try await pollUntil("the second transfer failed") {
            tab.transferQueue.failureCountExcludingConnectionLoss == 2
        }
        view.notifyTransferFailures()
        #expect(poster.posted.map(\.title) == [Self.title(.transferFailed)])
    }

    @Test func aCancelledTransferPostsNothing() async {
        let poster = RecordingPoster()
        let (view, _, _, cleanup) = makeContentView(poster: poster)
        defer { cleanup() }
        let directory = makeTempDirectory("cancel")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = view.tabsModel.activeTab
        attachSession(to: tab)
        let itemID = enqueueFailingTransfer(on: tab, into: directory)

        await tab.transferQueue.cancelAll(reason: .userRequested)
        view.notifyTransferFailures()

        // Positive half: the item really was there and really was cancelled.
        #expect(tab.transferQueue.items.first { $0.id == itemID }?.status == .cancelled)
        #expect(poster.posted.isEmpty)
    }

    // MARK: - Hook 3: a failed forwarding

    @Test func aForwardingPostsOnceOnEnteringFailedAndAgainAfterLeavingIt() async throws {
        let directory = makeTempDirectory("tunnels")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TunnelStore(directory: directory)
        let log = TunnelManagerTests.RunnerLog()
        let recorder = NameRecorder()
        let manager = TunnelManager(
            store: store,
            makeRunner: { profile in
                let runner = TunnelManagerTests.FakeTunnelRunner(profile: profile)
                log.record(runner)
                return runner
            },
            sessionIDs: { nil },
            notifyForwardingFailed: { name in recorder.names.append(name) })
        let profile = TunnelProfile(
            sessionID: UUID(), name: "db tunnel",
            kind: .local(bind: "127.0.0.1", localPort: 5432, host: "internal", remotePort: 5432))
        try await manager.save(profile)
        await manager.start(profile, decider: .asking { _ in true })
        let runner = try #require(log.runners[profile.id])
        try await pollUntil("active") { manager.state(of: profile.id) == .active(connections: 0) }
        #expect(recorder.names.isEmpty)

        runner.emit(.failed(.connectionLost))
        runner.emit(.failed(.portInUse(port: 5432)))
        try await pollUntil("the second failure reached the mirror") {
            manager.state(of: profile.id) == .failed(.portInUse(port: 5432))
        }
        #expect(recorder.names == ["db tunnel"])

        runner.emit(.reconnecting(attempt: 1))
        runner.emit(.failed(.connectionLost))
        try await pollUntil("failed again") {
            manager.state(of: profile.id) == .failed(.connectionLost)
        }
        #expect(recorder.names == ["db tunnel", "db tunnel"])
    }
}

/// Stores nothing and answers nothing — the same stand-in
/// `LivenessGiveUpOrderingTests` keeps privately, so no test here reaches
/// the real Keychain.
private struct NothingStoredSecretStore: SecretStore {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? { nil }
    func deletePassword(for sessionID: UUID) throws {}
}
