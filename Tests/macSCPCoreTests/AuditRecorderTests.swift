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
            destinationTabID: destinationTabID, isEditUpload: isEditUpload,
            destinationDirectory: destinationDirectory)
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
