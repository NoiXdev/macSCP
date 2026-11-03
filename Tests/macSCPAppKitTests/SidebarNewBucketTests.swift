import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The connection manager's one entry, "Connect and Create Bucket…" (S3
/// metadata and ACLs plan, Task 6; spec section 6.6).
///
/// Two halves, and they are different kinds of claim.
///
/// **Whether the entry is offered** is a function of a STORED connection, which
/// has no tab and no listing to ask. It is `ConnectionActionRoute.isOffered
/// (onStored:)`, and the rule inside it is not spelled again there: the
/// contribution is found in the backend's own descriptor (never by
/// `ConnectionKind`) and `CreateBucketModel.isOffered` supplies the verdict, so
/// "a bucket made in a connection rooted in one bucket would be invisible" has
/// one author.
///
/// **What choosing it does** is driven on a REAL `ContentView`, with a
/// connector that hands back a bucket-list file system. The sheet itself is
/// `@State`, and a `ContentView` built outside a SwiftUI hierarchy drops writes
/// to those (measured in `ConnectAttemptHandoffTests`' "Isolation, round 2"),
/// so what is asserted is everything BEFORE the sheet: that the connection is
/// owned by a tab, that the hand-off waits for the bucket list, and that it is
/// made exactly once and to the route. That the sheet then appears is the one
/// part no test of this project can see.
///
/// **No clock decides anything.** Every wait is a `pollUntil` on a fact the tab
/// itself publishes, and nothing asserts how long anything took.
@Suite("Sidebar: connect and create bucket", .timeLimit(.minutes(5)))
@MainActor
struct SidebarNewBucketTests {
    // MARK: - Whether the entry is offered

    private static func s3(startsAtBucketList: Bool) -> StoredSession {
        StoredSession(
            name: "store", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "key-id", region: "region-1", endpoint: "https://store.invalid",
                bucket: startsAtBucketList ? "" : "one-bucket", usePathStyle: true,
                startsAtBucketList: startsAtBucketList))
    }

    @Test func theEntryIsOfferedForAStoredS3ConnectionInBucketListMode() {
        #expect(ConnectionActionRoute.createBucket.isOffered(onStored: Self.s3(startsAtBucketList: true)))
    }

    /// Review Focus 5. The first half restricted create-bucket to bucket-list
    /// mode because a bucket created in a connection rooted in one bucket would
    /// be invisible, and a stored connection configured that way inherits the
    /// reason unchanged. The positive above is this test's control: the same
    /// kind, the same descriptor, the same contribution, and the one thing that
    /// differs is the mode.
    @Test func theEntryIsNotOfferedInSingleBucketMode() {
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: Self.s3(startsAtBucketList: false)))
    }

    /// An S3 record whose block is missing says nothing about its mode, and a
    /// connection that cannot say it starts at a bucket list is not offered
    /// an action that is only safe there.
    @Test func theEntryIsNotOfferedForAnS3ConnectionWithNoS3Block() {
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: StoredSession(name: "bare", kind: .s3)))
    }

    @Test func theEntryIsNotOfferedForSftpOrWebdav() {
        let ssh = StoredSession(
            name: "host", kind: .ssh, ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        let webdav = StoredSession(name: "dav", kind: .webdav)
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: ssh))
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: webdav))
    }

    /// The route is keyed by the backend's own contribution and never by
    /// `ConnectionKind`. The shape that would break that is a record of another
    /// kind that still carries a bucket-list block (an import, or a kind edited
    /// after the fact): offering the entry there would be reading the block
    /// instead of the backend.
    @Test func aBucketListBlockOnAnotherKindOfRecordDoesNotOfferIt() {
        var ssh = StoredSession(
            name: "host", kind: .ssh, ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        ssh.s3 = Self.s3(startsAtBucketList: true).s3
        var webdav = StoredSession(name: "dav", kind: .webdav)
        webdav.s3 = Self.s3(startsAtBucketList: true).s3
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: ssh))
        #expect(!ConnectionActionRoute.createBucket.isOffered(onStored: webdav))
    }

    /// Exactly one action goes on this surface (spec 6.6). The three bucket-level
    /// actions need a bucket, and a stored connection stands in none.
    @Test func onlyCreateBucketIsOfferedOnAStoredConnection() {
        let stored = Self.s3(startsAtBucketList: true)
        for route in ConnectionActionRoute.allCases {
            #expect(route.isOffered(onStored: stored) == (route == .createBucket), "\(route)")
        }
    }

    // MARK: - The entry's title

    /// The entry connects before it does anything, and connecting is not
    /// silent (it can raise a host-key prompt or a credential prompt), so the
    /// title says both. It is not `connection.action.createBucket`, which names
    /// the toolbar row on a connection that is already open.
    @Test func theTitleNamesTheConnectingAsWellAsTheCreating() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        for locale in ["en", "de", "fr", "pl"] {
            let title = L10n.$localeOverride.withValue(locale) {
                L10n.string("sidebar.connectAndCreateBucket", sentinel)
            }
            let toolbar = L10n.$localeOverride.withValue(locale) {
                L10n.string("connection.action.createBucket", sentinel)
            }
            let connect = L10n.$localeOverride.withValue(locale) {
                L10n.string("sidebar.connect", sentinel)
            }
            #expect(title != sentinel, "\(locale)")
            #expect(title != toolbar, "\(locale): the title is the toolbar row's, which does not say it connects")
            #expect(title.hasPrefix(connect), "\(locale): the title does not begin with the verb the row's own Connect uses")
        }
    }

    // MARK: - What choosing it does

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func makeContentView(
        storeDirectory: URL, sidebarTabFactory: (@MainActor () -> SessionTab)? = nil
    ) -> (view: ContentView, secrets: InMemoryBucketSecretStore, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let secrets = InMemoryBucketSecretStore()
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
            managedKeyStore: ManagedKeyStore(directory: storeDirectory),
            sidebarTabFactory: sidebarTabFactory)
        return (view, secrets, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
        })
    }

    /// A tab whose dial hands back `fs`, or throws when `fs` is `nil`.
    private func makeTab(dialing fs: BucketListFileSystem?, dials: DialCounter = DialCounter()) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                dials.increment()
                guard let fs else { throw RemoteFSError.protocolError(reason: "dial refused") }
                return fs
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Replaces the window's own tab (which carries the real connector) with
    /// one this suite controls.
    private func installControlledTab(in view: ContentView, dialing fs: BucketListFileSystem?)
        -> (tab: SessionTab, dials: DialCounter)
    {
        let dials = DialCounter()
        let controlled = makeTab(dialing: fs, dials: dials)
        let original = view.tabsModel.activeTab
        view.tabsModel.addTab(controlled)
        view.tabsModel.closeTab(original.id)
        return (controlled, dials)
    }

    /// A stored S3 connection in bucket-list mode, with the secret the dial's
    /// own pre-flight validation asks for kept in the in-memory store.
    private func storeSession(
        in directory: URL, view: ContentView, secrets: InMemoryBucketSecretStore
    ) -> StoredSession {
        let stored = Self.s3(startsAtBucketList: true)
        try? SessionStore(directory: directory).upsert(stored)
        try? secrets.savePassword("placeholder", for: stored.id)
        view.sessionListViewModel.reload()
        return stored
    }

    /// The connection is owned by a TAB: the one the window already holds, or
    /// a fresh one when the front tab is connected, and in both cases the file
    /// system the dial produced is the one that tab's session holds. That is
    /// the whole content of "a real tab rather than an ownerless connection"
    /// (spec 6.6), stated as an identity rather than as a count.
    @Test func choosingItOpensATabRatherThanAnOwnerlessConnection() async throws {
        let workDir = makeTempDirectory("new-bucket-owner")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, dials) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)

        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(dials.count == 1, "one choice must make exactly one dial")
        #expect(view.tabsModel.tabs.contains { $0.id == tab.id })
        let held = try #require(tab.session?.remoteFS as? BucketListFileSystem)
        #expect(held === fs, "the session the tab holds is not the connection the dial made")
        #expect(tab.activeStoredSessionID == stored.id)
        #expect(tab.pendingCreateBucket != nil, """
            nothing was armed on the tab, so the connect would end with no sheet — and the \
            checks below would be satisfied by an entry that only connects.
            """)
    }

    /// The tab rule is the ordinary one: a connected front tab is never torn
    /// down by a sidebar start, so the entry opens a FRESH tab beside it and
    /// the request is armed there, not on the connection already on screen.
    @Test func aConnectedFrontTabIsLeftAloneAndAFreshOneIsOpened() async throws {
        let workDir = makeTempDirectory("new-bucket-fresh")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let freshFS = BucketListFileSystem()
        let freshDials = DialCounter()
        var made: [SessionTab] = []
        let (view, secrets, cleanup) = makeContentView(
            storeDirectory: workDir,
            sidebarTabFactory: {
                let tab = self.makeTab(dialing: freshFS, dials: freshDials)
                made.append(tab)
                return tab
            })
        defer { cleanup() }
        let connectedFS = BucketListFileSystem()
        let (front, _) = installControlledTab(in: view, dialing: connectedFS)
        view.startSession(in: front, with: connectedFS, storedName: "front", startPath: "/")
        let other = Self.s3(startsAtBucketList: true)
        front.activeStoredSessionID = other.id
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        #expect(front.isConnected, "the control is not connected, so the tab rule would not apply")

        view.createBucketFromSidebar(stored)

        let fresh = try #require(made.first, "no fresh tab was made for a connected front tab")
        try await pollUntil("the fresh tab to hold a session") { fresh.session != nil }
        #expect(made.count == 1)
        #expect(fresh.id != front.id)
        #expect(front.session?.remoteFS as? BucketListFileSystem === connectedFS)
        #expect(front.pendingCreateBucket == nil, "the request was armed on the connection already on screen")
        #expect(fresh.pendingCreateBucket != nil)
        #expect(connectedFS.disconnects == 0, "the connected front tab was torn down by a sidebar start")
    }

    /// The hand-off is made when the tab is connected, in front, AND its bucket
    /// list has loaded -- and not before, because the sheet takes a snapshot of
    /// the pane's listing to check names against, and a snapshot taken while
    /// the list is loading says "not loaded" for ever.
    @Test func theHandOffWaitsForTheBucketListAndIsMadeOnce() async throws {
        let workDir = makeTempDirectory("new-bucket-waits")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        let session = try #require(tab.session)

        // Connected and in front, but the pane has not listed anything yet.
        #expect(session.remote.state == .loading, "the control: the list has not loaded")
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        #expect(tab.pendingCreateBucket != nil, "a request that is waiting must stay armed")

        await session.remote.load()
        #expect(session.remote.state == .loaded)
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        #expect(tab.pendingCreateBucket == nil, "the request survived its own hand-off")

        // Exactly once: the observer fires for every later change of the facts
        // it watches, and a dismissed sheet must not come back.
        #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed)
    }

    /// Cancelling the sheet is `createBucketSheetItem = nil`, which no test here
    /// can perform. What can be measured is that nothing the entry armed
    /// outlives its hand-off, so a dismissed sheet leaves a tab that is just a
    /// connected tab: it holds its session, names its stored connection, owes
    /// nobody a sheet, and closes the way every tab closes -- through the one
    /// teardown, which disconnects the connection it owns, once.
    @Test func cancellingTheSheetLeavesAnOrdinaryConnectedTab() async throws {
        let workDir = makeTempDirectory("new-bucket-cancel")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
        // ... the sheet is shown and cancelled here; the observer keeps firing.
        for _ in 0..<3 { #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed) }

        #expect(tab.isConnected)
        #expect(tab.activeStoredSessionID == stored.id)
        #expect(tab.pendingCreateBucket == nil)
        #expect(fs.disconnects == 0, "nothing may close the connection merely because the sheet went")

        await view.teardown(tab, reason: .userRequested)
        #expect(fs.disconnects == 1, "the one teardown must close the connection the tab owns, once")
        #expect(tab.session == nil)
    }

    /// A dial that fails leaves nothing armed: a request left behind would
    /// open the sheet on whatever this tab connects to next.
    @Test func aFailedConnectDropsTheRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-failed")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, dials) = installControlledTab(in: view, dialing: nil)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        #expect(tab.pendingCreateBucket != nil, "the control: the request was armed")
        try await pollUntil("the failed dial to settle") { !tab.isReconnecting }

        #expect(dials.count == 1, "the dial was supposed to be attempted")
        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.session == nil)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// A bucket list that FAILED to load drops the request instead of waiting
    /// for ever: nothing will make it `.loaded` by itself, the pane says why,
    /// and the toolbar's menu is still there. The `.waiting` before the load is
    /// this test's control.
    @Test func aBucketListThatFailedToLoadDropsTheRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-list-failed")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let (tab, _) = installControlledTab(in: view, dialing: BucketListFileSystem(listFails: true))
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)

        await tab.session?.remote.load()
        guard case .failed = tab.session?.remote.state else {
            Issue.record("the control: the list was supposed to fail to load")
            return
        }
        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// A tab that ends up on a different stored connection than the one the
    /// request was made for drops it, rather than offering to create a bucket
    /// in an account the user did not pick.
    @Test func aTabConnectedToAnotherStoredConnectionDropsTheRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-other")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        tab.activeStoredSessionID = UUID()

        #expect(view.deliverPendingCreateBucket(on: tab) == .dropped)
        #expect(tab.pendingCreateBucket == nil)
    }

    /// A tab behind the front one keeps its request until it is in front: the
    /// sheet is the window's, and presenting it over another tab's pane would
    /// offer to create a bucket in a connection the user is not looking at.
    @Test func aRequestOnABackgroundTabWaitsUntilItIsInFront() async throws {
        let workDir = makeTempDirectory("new-bucket-background")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        let elsewhere = makeTab(dialing: nil)
        view.tabsModel.addTab(elsewhere)
        view.tabsModel.activate(elsewhere.id)

        #expect(view.deliverPendingCreateBucket(on: tab) == .waiting)
        #expect(tab.pendingCreateBucket != nil)
        view.tabsModel.activate(tab.id)
        #expect(view.deliverPendingCreateBucket(on: tab) == .handedToTheRoute)
    }

    /// The teardown drops an armed request on its way out, for the reason it
    /// drops a pending snippet: every route into it is leaving this connection
    /// on purpose, and the connection the request was armed for is the one
    /// being left.
    @Test func teardownDropsAnArmedRequest() async throws {
        let workDir = makeTempDirectory("new-bucket-teardown")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(tab.pendingCreateBucket != nil, "the control: the request was armed")

        await view.teardown(tab, reason: .userRequested)

        #expect(tab.pendingCreateBucket == nil)
    }

    /// The request is dropped BEFORE the teardown's first suspension point, not
    /// after the connection has closed. The hand-off needs only a session, a
    /// loaded list and the front tab, and the session stays attached while the
    /// terminal shuts down and the connection closes, so a request still armed
    /// there is one the runner could act on mid-teardown. The state is read
    /// while `disconnect()` is parked, which is the only moment the order shows.
    @Test func anArmedRequestIsGoneBeforeTheConnectionStartsClosing() async throws {
        let workDir = makeTempDirectory("new-bucket-midteardown")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem(holdsDisconnect: true)
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.createBucketFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        await tab.session?.remote.load()
        #expect(tab.pendingCreateBucket != nil, "the control: armed, with everything the hand-off needs")

        let teardown = Task { await view.teardown(tab, reason: .userRequested) }
        _ = await fs.disconnectEntered.wait()
        // Parked inside `disconnect()`: the session is still attached.
        let stillAttached = tab.session != nil
        let armed = tab.pendingCreateBucket != nil
        let delivery = view.deliverPendingCreateBucket(on: tab)
        fs.disconnectRelease.signal()
        await teardown.value

        #expect(stillAttached, "the control: the teardown had already detached the session")
        #expect(!armed, "the request was still armed while the connection was closing")
        #expect(delivery == .notArmed)
    }

    /// The already-open question carries the request, so "Open Anyway" starts
    /// what was asked for. The answer is a function of the request alone.
    @Test func theAlreadyOpenQuestionCarriesTheRequestAndOpenAnywayArmsIt() async throws {
        let workDir = makeTempDirectory("new-bucket-query")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, dials) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)
        let holder = makeTab(dialing: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(tab.id)

        let request = try #require(view.createBucketFromSidebar(stored))
        #expect(request.createsBucket, "the question dropped what was asked for")
        #expect(dials.count == 0, "asking must not dial")
        #expect(tab.pendingCreateBucket == nil, "asking must not arm anything")

        view.startWithoutAsking(
            request.stored, paneVisibility: request.paneVisibility,
            pendingSnippet: request.pendingSnippet, createsBucket: request.createsBucket)
        #expect(tab.pendingCreateBucket != nil, "Open Anyway started a plain connect")
        try await pollUntil("the dial to settle") { tab.session != nil }
    }

    /// An ordinary connect carries no such request: the flag has to be a thing
    /// this entry sets, not a default every start inherits.
    @Test func anOrdinaryConnectArmsNothing() async throws {
        let workDir = makeTempDirectory("new-bucket-ordinary")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, secrets, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let fs = BucketListFileSystem()
        let (tab, _) = installControlledTab(in: view, dialing: fs)
        let stored = storeSession(in: workDir, view: view, secrets: secrets)

        view.connectFromSidebar(stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }

        #expect(tab.pendingCreateBucket == nil)
        #expect(view.deliverPendingCreateBucket(on: tab) == .notArmed)
    }

    // MARK: - The wiring

    /// The hand-off goes THROUGH the route (`openCreateContainerSheet`, which
    /// asks the backend's descriptor and `handleConnectionAction`) and builds
    /// no sheet of its own. A source scan of comment-free text, with a positive
    /// control beside every negative: a scan for an absent thing that cannot
    /// find the present one is a comment that runs.
    @Test func theHandOffGoesThroughTheRouteAndBuildsNoSheetOfItsOwn() throws {
        let contentView = try SourceCorpus.text(of: Self.contentViewFile)
        let body = try Self.functionBody(named: "func deliverPendingCreateBucket(", in: contentView)
        #expect(body.contains("openCreateContainerSheet(in: tab, session: session)"), """
            the hand-off no longer calls `openCreateContainerSheet(in:session:)` -- a sheet \
            presented any other way is a second copy of the rule that decides whether it is \
            possible.
            """)
        #expect(!body.contains("CreateBucketSheetItem("), "the hand-off builds the sheet item itself")
        #expect(!body.contains("createBucketSheetItem"), "the hand-off writes the sheet's state itself")
        // The control: the scan can see the one place the item IS built.
        let actions = try SourceCorpus.text(of: Self.menuActionsFile)
        #expect(actions.contains("createBucketSheetItem = CreateBucketSheetItem("))
    }

    /// The sidebar holds no connection of its own: it names no file system,
    /// no connector and no session, only the effect value and the input.
    @Test func theSidebarOwnsNoConnection() throws {
        let sidebar = try SourceCorpus.text(of: Self.sidebarFile)
        for forbidden in ["BrowserSession", "RemoteFileSystem", "ConnectionViewModel", "S3FileSystem"] {
            #expect(!sidebar.contains(forbidden), "SessionSidebar.swift names \(forbidden)")
        }
        // The control: the file does name the effect type it was handed.
        #expect(sidebar.contains("SessionRowCreateBucketEffect"))
    }

    /// The runner is mounted once per tab, beside the snippet one, so a request
    /// armed on a tab that is not in front is still delivered when it comes
    /// forward.
    @Test func theRunnerIsMountedPerTab() throws {
        let detail = try SourceCorpus.text(of: Self.detailFile)
        #expect(detail.contains("PendingCreateBucketRunner("), """
            ContentView+Detail.swift no longer mounts PendingCreateBucketRunner( -- a request \
            armed by the sidebar entry would connect and then never open the sheet.
            """)
        #expect(detail.contains("deliverPendingCreateBucket(on: $0)"))
        // What wakes the runner is what the delivery reads. The one fact the
        // snippet runner does not carry is the pane's load state, and without
        // it a request waiting for the list would never be woken by the list.
        let runner = try Self.functionBody(named: "struct PendingCreateBucketRunner: View {", in: detail)
        for fact in [
            "tab.pendingCreateBucket", "tab.session?.remote.state", "tab.session?.id",
            "tab.isReconnecting", "tab.activeStoredSessionID", "activeTabID: activeTabID",
        ] {
            #expect(runner.contains(fact), "the runner's signal no longer carries `\(fact)`")
        }
    }

    /// "Open Anyway" starts what was asked for. The answer lives in a view
    /// modifier no test can press, so the pass-through is read from source:
    /// the dialog hands `request.createsBucket` on, and builds no sheet.
    @Test func openAnywayPassesTheRequestOnAndBuildsNoSheet() throws {
        let sheets = try SourceCorpus.text(of: Self.sheetsFile)
        let answer = try Self.functionBody(
            named: "Button(L10n.string(\"tabs.alreadyOpen.openAnyway\"", in: sheets)
        #expect(answer.contains("createsBucket: request.createsBucket"), """
            the "Open Anyway" answer no longer hands the create-bucket request on -- it \
            would start a plain connect and the sheet would never open.
            """)
        #expect(!answer.contains("CreateBucketSheetItem("))
        // The control: the scan found the answer it was meant to read.
        #expect(answer.contains("startWithoutAsking("))
    }

    /// The row offers the entry only where the route says so. The `if` and the
    /// question it asks are both read: a row that showed the entry on every
    /// connection would dial an account that has nothing to create a bucket in.
    @Test func theRowOffersTheEntryOnlyWhereTheRouteSaysSo() throws {
        let sidebar = try SourceCorpus.text(of: Self.sidebarFile)
        let lines = sidebar.components(separatedBy: "\n")
        let carrier = try #require(lines.firstIndex { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.contains(".newBucketMenuEntry")
        }, "no line forwards `.newBucketMenuEntry`")
        #expect(
            lines[carrier - 1].trimmingCharacters(in: .whitespaces) == "if newBucketOffered {",
            "the entry is not directly inside `if newBucketOffered {`")
        let question = try Self.functionBody(named: "private var newBucketOffered: Bool {", in: sidebar)
        #expect(question.contains("ConnectionActionRoute.createBucket.isOffered(onStored: session)"))
    }

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")
    private static let menuActionsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+MenuActions.swift")
    private static let sheetsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Sheets.swift")
    private static let sidebarFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private struct ScanFailure: Error { let anchor: String }

    /// The comment-free text of the `{ ... }` block opened by the first line
    /// containing `marker`, by brace counting.
    private static func functionBody(named marker: String, in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else {
            throw ScanFailure(anchor: marker)
        }
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[start...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("//") { collected.append(line) }
            for character in line {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return collected.joined(separator: "\n")
    }
}

// MARK: - Doubles

/// Counts dials from a connector closure, which is `@Sendable`.
private final class DialCounter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var count: Int { state.withLock { $0 } }
}

/// A connected bucket-list file system: the root lists buckets, the bucket
/// settings capability is present (the route's availability reads both), and
/// `disconnect()` is counted so a test can tell the connection was closed, and
/// by whom, without a clock.
private final class BucketListFileSystem: RemoteFileSystem, S3BucketSettings, Sendable {
    private let settings = FakeBucketSettings()
    private let closed = Mutex(0)
    private let holdsDisconnect: Bool
    private let listFails: Bool
    /// Raised when `disconnect()` is entered; only meaningful when it holds.
    let disconnectEntered = AsyncSignal()
    /// Releases a held `disconnect()`.
    let disconnectRelease = AsyncSignal()

    /// `holdsDisconnect` parks `disconnect()` until the test releases it, so a
    /// test can stand between the start of a teardown and its end without a
    /// clock.
    ///
    /// `listFails` makes the bucket list itself fail to load.
    init(holdsDisconnect: Bool = false, listFails: Bool = false) {
        self.holdsDisconnect = holdsDisconnect
        self.listFails = listFails
    }

    var disconnects: Int { closed.withLock { $0 } }

    nonisolated var rootIsContainerList: Bool { true }

    func list(path: String) async throws -> [RemoteFileItem] {
        if listFails { throw RemoteFSError.protocolError(reason: "list refused") }
        return [
            RemoteFileItem(name: "first-bucket", path: "/first-bucket", kind: .directory, isBucket: true),
            RemoteFileItem(name: "second-bucket", path: "/second-bucket", kind: .directory, isBucket: true),
        ]
    }

    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {
        closed.withLock { $0 += 1 }
        guard holdsDisconnect else { return }
        disconnectEntered.signal()
        _ = await disconnectRelease.wait()
    }

    func stat(path: String) async throws -> RemoteFileItem { fatalError("not exercised by this test") }
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("not exercised by this test")
    }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        fatalError("not exercised by this test")
    }
    func delete(path: String) async throws { fatalError("not exercised by this test") }
    func createDirectory(at path: String) async throws { fatalError("not exercised by this test") }
    func rename(from: String, to: String) async throws { fatalError("not exercised by this test") }
    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }
    func deleteTree(at path: String) async throws { fatalError("not exercised by this test") }

    // The bucket settings capability: present, and answered by the shared fake.
    func createBucket(_ bucket: String, protection: BucketProtection) async throws {
        try await settings.createBucket(bucket, protection: protection)
    }
    func versioning(ofBucket bucket: String) async throws -> BucketVersioning {
        try await settings.versioning(ofBucket: bucket)
    }
    func setVersioning(_ state: BucketVersioning, ofBucket bucket: String) async throws {
        try await settings.setVersioning(state, ofBucket: bucket)
    }
    func cors(ofBucket bucket: String) async throws -> BucketCORS? {
        try await settings.cors(ofBucket: bucket)
    }
    func setCORS(_ rules: [CORSRule], ofBucket bucket: String) async throws {
        try await settings.setCORS(rules, ofBucket: bucket)
    }
    func hasObjectLock(ofBucket bucket: String) async throws -> Bool {
        try await settings.hasObjectLock(ofBucket: bucket)
    }
    func objectLockDefault(ofBucket bucket: String) async throws -> (days: Int, mode: RetentionMode)? {
        try await settings.objectLockDefault(ofBucket: bucket)
    }
    func setObjectLockDefault(days: Int, mode: RetentionMode, ofBucket bucket: String) async throws {
        try await settings.setObjectLockDefault(days: days, mode: mode, ofBucket: bucket)
    }
    func retention(ofKey key: String, inBucket bucket: String, versionId: String?) async throws
        -> ObjectRetention?
    {
        try await settings.retention(ofKey: key, inBucket: bucket, versionId: versionId)
    }
    func setRetention(
        _ retention: ObjectRetention, ofKey key: String, inBucket bucket: String, versionId: String?
    ) async throws {
        try await settings.setRetention(retention, ofKey: key, inBucket: bucket, versionId: versionId)
    }
    func legalHold(ofKey key: String, inBucket bucket: String, versionId: String?) async throws -> Bool {
        try await settings.legalHold(ofKey: key, inBucket: bucket, versionId: versionId)
    }
    func setLegalHold(_ on: Bool, ofKey key: String, inBucket bucket: String, versionId: String?) async throws {
        try await settings.setLegalHold(on, ofKey: key, inBucket: bucket, versionId: versionId)
    }
}

/// In-memory `SecretStore`: the point of passing one at all is that no test in
/// this file can reach the real Keychain.
private final class InMemoryBucketSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
