import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The per-connection permission editor's App wiring (Ruling T7.1 of the FTP
/// plan): the answer to `PermissionsAvailability.isOffered(for:on:)` is asked
/// of the connection once, written onto the session it was asked about, and
/// read from there by the synchronous view body.
///
/// The Core half is measured in `FTPFileSystemTests` against a real FTP
/// server; what these cases hold is the half Core cannot see: where the
/// answer lands, and that it lands only on the session that was asked.
@Suite("Permission editing on the session")
@MainActor
struct PermissionEditingRecordTests {
    /// A connection that answers the probe with a fixed `Bool` and does
    /// nothing else. Nothing here performs I/O through it.
    private struct ProbedFileSystem: RemoteFileSystem, PermissionEditingProbe {
        let answer: Bool

        func offersPermissionEditing() async -> Bool { answer }

        func list(path: String) async throws -> [RemoteFileItem] { fatalError("not exercised") }
        func stat(path: String) async throws -> RemoteFileItem { fatalError("not exercised") }
        func readStream(
            path: String, fromOffset offset: UInt64
        ) async throws -> AsyncThrowingStream<Data, Error> { fatalError("not exercised") }
        func write(
            path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
        ) async throws { fatalError("not exercised") }
        func delete(path: String) async throws { fatalError("not exercised") }
        func createDirectory(at path: String) async throws { fatalError("not exercised") }
        func rename(from: String, to: String) async throws { fatalError("not exercised") }
        func setPermissions(path: String, permissions: UInt32) async throws {
            fatalError("not exercised")
        }
        func deleteTree(at path: String) async throws { fatalError("not exercised") }
        func homeDirectoryPath() async throws -> String { fatalError("not exercised") }
        func disconnect() async {}
    }

    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Attaches a session over `fileSystem` and returns its id. The shape
    /// `ContentView.startSession` builds, with a local file system standing
    /// in for the local side.
    private func attachSession(to tab: SessionTab, over fileSystem: any RemoteFileSystem) -> UUID {
        let sessionID = UUID()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: fileSystem,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fileSystem, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        return sessionID
    }

    private func built(over fileSystem: any RemoteFileSystem, tab: SessionTab) -> BrowserSession {
        BrowserSession(
            id: UUID(),
            localFS: LocalFileSystem(),
            remoteFS: fileSystem,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fileSystem, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: UUID(), queue: tab.transferQueue),
            homePath: "/")
    }

    /// Installing a session is what asks the connection: there is no way to
    /// install one through `adopt` and not ask, which is the structural half of
    /// Ruling T7.1 (a task wrapped in a condition inside `startSession` was
    /// invisible to every test, Task 8 review, finding 3). The answer lands on
    /// the session that was installed.
    @Test func installingASessionAsksTheConnectionAndRecordsItsAnswer() async {
        let tab = makeTab()
        let session = built(over: ProbedFileSystem(answer: false), tab: tab)
        tab.adopt(session, over: ProbedFileSystem(answer: false), kind: .ftp)
        #expect(tab.session?.id == session.id)

        await tab.permissionProbe?.value

        #expect(tab.permissionProbe != nil)
        #expect(tab.session?.permissionEditing == false)
    }

    /// The same install over a connection that will take a change leaves the
    /// offer standing: the asking changes nothing it should not.
    @Test func installingASessionOverAnAcceptingConnectionKeepsTheOffer() async {
        let tab = makeTab()
        let fileSystem = ProbedFileSystem(answer: true)
        tab.adopt(built(over: fileSystem, tab: tab), over: fileSystem, kind: .ftp)

        await tab.permissionProbe?.value

        #expect(tab.session?.permissionEditing == true)
    }

    /// A second install replaces the first, and the first one's answer, if it
    /// arrives late, is not written onto the second.
    @Test func aSecondInstallIsNotAnsweredForByTheFirst() async {
        let tab = makeTab()
        let first = ProbedFileSystem(answer: false)
        tab.adopt(built(over: first, tab: tab), over: first, kind: .ftp)
        let firstProbe = tab.permissionProbe
        let second = ProbedFileSystem(answer: true)
        tab.adopt(built(over: second, tab: tab), over: second, kind: .ftp)

        await firstProbe?.value
        await tab.permissionProbe?.value

        #expect(tab.session?.permissionEditing == true)
    }

    /// A fresh session offers the editor, as every session did before the
    /// probe existed; the answer can only take the offer away.
    @Test func aFreshSessionOffersTheEditorUntilTheConnectionHasAnswered() {
        let tab = makeTab()
        _ = attachSession(to: tab, over: ProbedFileSystem(answer: false))
        #expect(tab.session?.permissionEditing == true)
    }

    /// A server with no `SITE CHMOD` shows no editor: its answer reaches the
    /// session.
    @Test func aConnectionThatWillNotTakeAChangeTakesTheOfferAway() async {
        let tab = makeTab()
        let fileSystem = ProbedFileSystem(answer: false)
        let id = attachSession(to: tab, over: fileSystem)

        await tab.recordPermissionEditing(of: fileSystem, kind: .ftp, forSession: id)

        #expect(tab.session?.permissionEditing == false)
    }

    @Test func aConnectionThatWillTakeAChangeKeepsTheOffer() async {
        let tab = makeTab()
        let fileSystem = ProbedFileSystem(answer: true)
        let id = attachSession(to: tab, over: fileSystem)

        await tab.recordPermissionEditing(of: fileSystem, kind: .ftp, forSession: id)

        #expect(tab.session?.permissionEditing == true)
    }

    /// The capability is read before the probe, so a backend with no POSIX
    /// model answers `false` whatever its connection says. WebDAV has none.
    @Test func theCapabilityIsReadBeforeTheConnectionsOwnAnswer() async {
        let tab = makeTab()
        let fileSystem = ProbedFileSystem(answer: true)
        let id = attachSession(to: tab, over: fileSystem)

        await tab.recordPermissionEditing(of: fileSystem, kind: .webdav, forSession: id)

        #expect(tab.session?.permissionEditing == false)
    }

    /// An answer about a connection that has since been replaced is dropped:
    /// it must not hide, or offer, an editor on the new one.
    @Test func anAnswerAboutAnotherSessionIsNotWrittenOntoThisOne() async {
        let tab = makeTab()
        let old = ProbedFileSystem(answer: false)
        let oldID = attachSession(to: tab, over: old)
        _ = attachSession(to: tab, over: ProbedFileSystem(answer: true))
        #expect(tab.session?.id != oldID)

        await tab.recordPermissionEditing(of: old, kind: .ftp, forSession: oldID)

        #expect(tab.session?.permissionEditing == true)
    }

    /// With no session at all there is nothing to write onto, and the call
    /// does not invent one.
    @Test func anAnswerForATabWithNoSessionIsDropped() async {
        let tab = makeTab()
        await tab.recordPermissionEditing(
            of: ProbedFileSystem(answer: false), kind: .ftp, forSession: UUID())
        #expect(tab.session == nil)
    }
}
