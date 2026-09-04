import Foundation
import Testing
@testable import macSCPCore

@Suite("AuditRecorder")
@MainActor
struct AuditRecorderTests {
    private func makeStore() -> (AuditLogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditRecorderTests-\(UUID().uuidString)", isDirectory: true)
        return (AuditLogStore(directory: dir), dir)
    }

    /// Builds a queue item directly via the (internal, `@testable`-visible)
    /// memberwise init — the simpler route than driving a real queue/FS pair
    /// through to a terminal state for every mapping case.
    private func makeItem(
        fileName: String = "report.pdf",
        direction: TransferDirection = .upload,
        status: TransferQueueViewModel.Item.Status,
        destinationTabID: UUID? = nil,
        isEditUpload: Bool = false,
        destinationDirectory: String = "/dest"
    ) -> TransferQueueViewModel.Item {
        TransferQueueViewModel.Item(
            id: UUID(), fileName: fileName, direction: direction, status: status,
            sourcePath: RemotePath.join("/source", fileName),
            destinationTabID: destinationTabID, isEditUpload: isEditUpload,
            destinationDirectory: destinationDirectory,
            destinationPath: RemotePath.join(destinationDirectory, fileName),
            destinationSupportsResume: true, crossRemote: false, crossBackendTarget: nil)
    }

    /// Spec M9b (binding, maintainer-approved) requires "Richtung, Name,
    /// Ziel" — its own example is `upload report.pdf → /var/www` (M9b/T4
    /// review, finding 3). This pins the exact detail shape, not just
    /// substring presence.
    @Test func finishedUploadRecordsTransferFinishedWithFileNameAndDestinationInDetail() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordTransfer(
            makeItem(fileName: "report.pdf", direction: .upload, status: .finished, destinationDirectory: "/var/www"),
            targetTitle: nil)

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .transferFinished)
        #expect(events[0].detail == "upload report.pdf → /var/www")
        #expect(events[0].isError == false)
    }

    @Test func finishedDownloadDetailSaysDownload() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordTransfer(makeItem(fileName: "photo.jpg", direction: .download, status: .finished), targetTitle: nil)

        let events = store.events(for: sessionID)
        #expect(events[0].detail.contains("download"))
        #expect(events[0].detail.contains("photo.jpg"))
    }

    @Test func finishedEditUploadRecordsEditUploadKind() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordTransfer(
            makeItem(fileName: "config.yml", status: .finished, isEditUpload: true), targetTitle: nil)

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .editUpload)
    }

    @Test func finishedCrossSessionWithTargetTitleRecordsCrossSessionTransferKind() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)
        let destinationTabID = UUID()

        recorder.recordTransfer(
            makeItem(fileName: "dump.sql.gz", status: .finished, destinationTabID: destinationTabID),
            targetTitle: "db-prod")

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .crossSessionTransfer)
        #expect(events[0].detail.contains("db-prod"))
        #expect(events[0].detail.contains("dump.sql.gz"))
    }

    @Test func finishedCrossSessionWithNilTargetTitleSaysUnknownSession() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)
        let destinationTabID = UUID()

        recorder.recordTransfer(
            makeItem(status: .finished, destinationTabID: destinationTabID), targetTitle: nil)

        let events = store.events(for: sessionID)
        #expect(events[0].kind == .crossSessionTransfer)
        #expect(events[0].detail.contains("unknown session"))
    }

    @Test func failedRecordsTransferFailedWithErrorMessage() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordTransfer(makeItem(status: .failed("boom")), targetTitle: nil)

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .transferFailed)
        #expect(events[0].isError == true)
        #expect(events[0].errorMessage == "boom")
    }

    @Test func cancelledRecordsTransferCancelled() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordTransfer(makeItem(status: .cancelled), targetTitle: nil)

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .transferCancelled)
        #expect(events[0].isError == false)
    }

    @Test func nonTerminalAndSilentStatusesRecordNothing() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordTransfer(makeItem(status: .queued), targetTitle: nil)
        recorder.recordTransfer(makeItem(status: .running(TransferProgress(bytesTransferred: 0, totalBytes: nil))), targetTitle: nil)
        recorder.recordTransfer(makeItem(status: .skipped), targetTitle: nil)
        recorder.recordTransfer(makeItem(status: .interrupted), targetTitle: nil)

        #expect(store.events(for: sessionID).isEmpty)
    }

    @Test func recordConnectedIncludesHostAndUsername() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordConnected(host: "example.com", username: "alice")

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .connected)
        #expect(events[0].detail.contains("example.com"))
        #expect(events[0].detail.contains("alice"))
    }

    /// Regression guard (M11e/T2): the no-jump detail must stay byte-identical
    /// to the pre-jump-context format — no trailing "via" clause appears when
    /// `viaJumpHost` is left at its default `nil`.
    @Test func connectedWithoutJumpKeepsDetail() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordConnected(host: "h", username: "u")

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].detail == "connected to h as u")
    }

    /// M11e/T2 spec §3/§4: a jump-hop connect names the bastion HOST only —
    /// no bastion username, no secret, no forced port. `contains("via")`
    /// plus the negative "no ' as ' after 'via'" check together pin both the
    /// exact suffix shape and the security property in one test.
    @Test func connectedWithJumpNamesTheHop() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordConnected(host: "h", username: "u", viaJumpHost: "bastion")

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].detail == "connected to h as u via bastion")
        let afterVia = events[0].detail.components(separatedBy: "via bastion").last ?? ""
        #expect(!afterVia.contains(" as "))
    }

    /// M22/T11: the `summary`-based overload is what the App layer now calls
    /// for every backend, routing through `BackendDescriptor.displaySummary`
    /// instead of the SSH-shaped `host`/`username` pair above -- that pair
    /// stayed "unused" for a stored S3 or WebDAV session, which is why the
    /// audit trail used to read "connected to unused as unused" for anything
    /// but SSH.
    @Test func recordConnectedWithSummaryIncludesTheWholeSummary() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordConnected(summary: "backups @ minio.local")

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .connected)
        #expect(events[0].detail == "connected to backups @ minio.local")
    }

    /// Mirrors `connectedWithJumpNamesTheHop` for the summary overload: the
    /// jump hop's host is the only extra detail, appended the same way.
    @Test func recordConnectedWithSummaryAndJumpNamesTheHop() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordConnected(summary: "alice@example.com", viaJumpHost: "bastion")

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].detail == "connected to alice@example.com via bastion")
    }

    /// The producer for `AuditEvent.Kind.connectFailed` (session overview
    /// plan, Task 2). The kind was added in Task 1 with nothing writing it;
    /// this is what writes it.
    ///
    /// `isError` is the half worth pinning beside the kind: the audit
    /// sheet's error filter and the overview's own red row both read it, and
    /// a failed connect recorded as an ordinary event would be invisible in
    /// both.
    ///
    /// The reason is stored VERBATIM and is the caller's — the App hands
    /// over `DialSupport.reason(for:)`'s fixed sentence, never an error's own
    /// text (see that function's doc comment for what free error text
    /// carries). Nothing here composes a sentence of its own, which is why
    /// the expectation is an equality rather than a `contains`.
    @Test func recordConnectFailedStoresTheReasonVerbatimAsAnError() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)
        let reason = DialSupport.reason(for: HostKeyError.rejectedByUser)

        recorder.recordConnectFailed(reason: reason)

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .connectFailed)
        #expect(events[0].detail == reason)
        #expect(events[0].isError)
    }

    @Test func recordDisconnectedRecordsDisconnectedKind() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordDisconnected()

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .disconnected)
    }

    @Test func recordActionAppendsThePassedEventVerbatim() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)
        let event = AuditEvent(kind: .rename, detail: "rename /a → b")

        recorder.recordAction(event)

        let events = store.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events[0].kind == .rename)
        #expect(events[0].detail == "rename /a → b")
    }
}
