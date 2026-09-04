import Foundation
import Testing

@testable import macSCPCore

/// What the session overview's "recent connections" list is derived from:
/// the session's own audit log, and nothing else.
///
/// Every fixture below builds `AuditEvent`s by hand EXCEPT
/// `theVerbTheRecorderWritesIsTheVerbTheHistoryReads`, which drives the real
/// `AuditRecorder` — the producer of the only structural trace of a
/// transfer's direction an event carries. A hand-built fixture alone would
/// pin this file's own idea of what a detail looks like; that one test is
/// what ties the reader to the writer, so a change to either turns it red.
@Suite("Connection history")
@MainActor
struct ConnectionHistoryTests {
    /// A fixed instant. Nothing here reads the wall clock, so nothing here
    /// can be made red by a slow runner.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ offset: TimeInterval) -> Date {
        Self.epoch.addingTimeInterval(offset)
    }

    private func event(
        _ kind: AuditEvent.Kind, _ offset: TimeInterval, _ detail: String = "",
        isError: Bool = false
    ) -> AuditEvent {
        AuditEvent(timestamp: at(offset), kind: kind, detail: detail, isError: isError)
    }

    private func upload(_ offset: TimeInterval) -> AuditEvent {
        event(.transferFinished, offset, "upload report.pdf → /var/www")
    }

    private func download(_ offset: TimeInterval) -> AuditEvent {
        event(.transferFinished, offset, "download photo.jpg → /tmp")
    }

    private func failedTransfer(_ offset: TimeInterval) -> AuditEvent {
        event(.transferFailed, offset, "upload big.iso → /var/www", isError: true)
    }

    // MARK: - Pairing

    /// Two `connected` … `disconnected` pairs, three finished transfers
    /// inside the first and one failed transfer inside the second. Newest
    /// first, so the SECOND pair is row 0.
    @Test func twoPairedSessionsBecomeTwoRowsNewestFirst() {
        let first = event(.connected, 0, "connected to web-01 as deploy")
        let second = event(.connected, 100, "connected to web-01 as deploy")
        let events: [AuditEvent] = [
            first,
            upload(10), upload(20), download(30),
            event(.disconnected, 60, "disconnected"),
            second,
            failedTransfer(110),
            event(.disconnected, 130, "disconnected"),
        ]

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 2)
        #expect(rows[0].id == second.id)
        #expect(rows[0].startedAt == at(100))
        #expect(rows[0].outcome == .connected(duration: .seconds(30)))
        #expect(rows[0].uploads == 0)
        #expect(rows[0].downloads == 0)
        #expect(rows[0].failedTransfers == 1)

        #expect(rows[1].id == first.id)
        #expect(rows[1].startedAt == at(0))
        #expect(rows[1].outcome == .connected(duration: .seconds(60)))
        #expect(rows[1].uploads == 2)
        #expect(rows[1].downloads == 1)
        #expect(rows[1].failedTransfers == 0)
    }

    /// The still-open session: a `connected` with no `disconnected` after it
    /// is a row with no duration, and it still counts the transfers that
    /// happened inside it.
    @Test func anUnpairedTrailingConnectIsAnOpenRowWithNoDuration() {
        let open = event(.connected, 0, "connected to web-01 as deploy")
        let rows = ConnectionHistory.rows(from: [open, upload(5), download(6)])

        #expect(rows.count == 1)
        #expect(rows[0].id == open.id)
        #expect(rows[0].outcome == .connected(duration: nil))
        #expect(rows[0].uploads == 1)
        #expect(rows[0].downloads == 1)
    }

    /// A `connected` that is never closed and is followed by ANOTHER
    /// `connected` — the shape a crash leaves behind. Both are rows; the
    /// abandoned one has no duration either, because nothing recorded when
    /// it ended.
    @Test func anAbandonedConnectIsItsOwnRowWithNoDuration() {
        let abandoned = event(.connected, 0, "connected to web-01 as deploy")
        let later = event(.connected, 500, "connected to web-01 as deploy")
        let rows = ConnectionHistory.rows(
            from: [abandoned, upload(5), later, event(.disconnected, 520, "disconnected")])

        #expect(rows.count == 2)
        #expect(rows[0].id == later.id)
        #expect(rows[0].outcome == .connected(duration: .seconds(20)))
        #expect(rows[1].id == abandoned.id)
        #expect(rows[1].outcome == .connected(duration: nil))
        #expect(rows[1].uploads == 1)
    }

    // MARK: - Failed connects

    /// The reason is the event's own detail, verbatim — the FIXED sentence
    /// the diagnostics module produces (`DialSupport.reason(for:)`), never
    /// free error text this type invents.
    @Test func aFailedConnectIsAFailedRowCarryingTheEventsOwnSentence() {
        let sentence = "the host key is not known to this app and was not accepted"
        let failure = event(.connectFailed, 40, sentence, isError: true)
        let rows = ConnectionHistory.rows(from: [failure])

        #expect(rows.count == 1)
        #expect(rows[0].id == failure.id)
        #expect(rows[0].startedAt == at(40))
        #expect(rows[0].outcome == .failed(reason: sentence))
        #expect(rows[0].uploads == 0)
        #expect(rows[0].downloads == 0)
        #expect(rows[0].failedTransfers == 0)
    }

    @Test func aFailedConnectSitsBetweenTheSessionsItHappenedBetween() {
        let events: [AuditEvent] = [
            event(.connected, 0, "connected to web-01 as deploy"),
            event(.disconnected, 10, "disconnected"),
            event(.connectFailed, 20, "connection refused", isError: true),
            event(.connected, 30, "connected to web-01 as deploy"),
            event(.disconnected, 40, "disconnected"),
        ]

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 3)
        #expect(rows[0].startedAt == at(30))
        #expect(rows[1].outcome == .failed(reason: "connection refused"))
        #expect(rows[2].startedAt == at(0))
    }

    /// The shape a crash leaves behind, followed by the next launch: an
    /// unclosed `connected`, then a `connectFailed`. The failure is NEWER,
    /// so it is row 0 — and it is the case the derivation gets wrong when it
    /// orders rows by when a segment CLOSED rather than by when it OPENED,
    /// because the abandoned segment is only closed after the whole log has
    /// been walked.
    @Test func aFailedConnectInsideAnOpenSegmentIsStillOrderedNewestFirst() {
        let crashed = event(.connected, 0, "connected to web-01 as deploy")
        let failure = event(.connectFailed, 100, "connection refused", isError: true)

        let rows = ConnectionHistory.rows(from: [crashed, failure])

        #expect(rows.count == 2)
        #expect(rows[0].id == failure.id)
        #expect(rows[0].startedAt == at(100))
        #expect(rows[1].id == crashed.id)
        #expect(rows[1].outcome == .connected(duration: nil))
    }

    /// The same defect seen through the cut rather than through the order: an
    /// abandoned `connected` is the OLDEST attempt in this log, so it is the
    /// one the last-ten rule drops. Ordering by close instead keeps it and
    /// drops the oldest failure.
    @Test func theCutDropsTheOldestAttemptEvenWhenItIsTheOneStillOpen() {
        var events: [AuditEvent] = [event(.connected, 0, "connected to web-01 as deploy")]
        for index in 1...10 {
            events.append(
                event(.connectFailed, TimeInterval(index * 100), "connection refused \(index)",
                    isError: true))
        }

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 10)
        #expect(rows[0].startedAt == at(1000))
        #expect(rows[9].startedAt == at(100))
        let keptTheAbandonedOne = rows.contains { $0.startedAt == at(0) }
        #expect(keptTheAbandonedOne == false)
    }

    // MARK: - The cut

    @Test func elevenPairsKeepTheNewestTen() {
        var events: [AuditEvent] = []
        for index in 0..<11 {
            let base = TimeInterval(index * 100)
            events.append(event(.connected, base, "connected to web-01 as deploy"))
            events.append(event(.disconnected, base + 10, "disconnected"))
        }

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 10)
        // Newest first: the last pair opened at 1000, the oldest one KEPT
        // opened at 100 — the pair at 0 is the one that fell off.
        #expect(rows[0].startedAt == at(1000))
        #expect(rows[9].startedAt == at(100))
    }

    @Test func theLimitIsARequestNotACeiling() {
        var events: [AuditEvent] = []
        for index in 0..<5 {
            let base = TimeInterval(index * 100)
            events.append(event(.connected, base, "connected to web-01 as deploy"))
            events.append(event(.disconnected, base + 10, "disconnected"))
        }

        #expect(ConnectionHistory.rows(from: events, limit: 2).count == 2)
        #expect(ConnectionHistory.rows(from: events, limit: 50).count == 5)
    }

    // MARK: - What is counted, and what is not

    /// Transfers recorded before any `connected` belong to no session, so
    /// they belong to no row.
    @Test func transfersBeforeTheFirstConnectAreCountedNowhere() {
        let events: [AuditEvent] = [
            upload(0),
            event(.connected, 10, "connected to web-01 as deploy"),
            event(.disconnected, 20, "disconnected"),
        ]

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 1)
        #expect(rows[0].uploads == 0)
    }

    /// Exactly the two kinds the design names are counted. The other four
    /// transfer-shaped kinds are listed here rather than left implicit, so
    /// a later decision to include one has to change this test.
    @Test func onlyFinishedAndFailedTransfersAreCounted() {
        let events: [AuditEvent] = [
            event(.connected, 0, "connected to web-01 as deploy"),
            event(.transferCancelled, 1, "upload a.txt → /tmp"),
            event(.editUpload, 2, "upload b.txt → /tmp"),
            event(.crossSessionTransfer, 3, "to “other”: c.txt → /tmp"),
            event(.snippetExecuted, 4, "ran “ls”"),
            event(.disconnected, 5, "disconnected"),
        ]

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 1)
        #expect(rows[0].uploads == 0)
        #expect(rows[0].downloads == 0)
        #expect(rows[0].failedTransfers == 0)
    }

    /// No audit event carries a byte count — neither as a field nor in its
    /// detail text. Recounted 2026-09-04 at HEAD over every `AuditEvent(`
    /// construction site under `Sources/` (comments excluded, and
    /// `ConnectionHistory`'s own prose mention of the spelling with it):
    /// TWENTY-FIVE — `RemoteBrowserViewModel` fifteen, `AuditRecorder`
    /// eight, `ContentView` one, `ContentView+Lifecycle` one. None names
    /// bytes. The first version of this sentence said "eighteen", which was
    /// never counted; `ConnectionHistory.Row.bytes` carries the same number
    /// and the two are now the same count. So the answer is `nil`, and it is
    /// `nil` honestly rather than zero.
    @Test func bytesAreNilBecauseNoEventCarriesAByteCount() {
        let events: [AuditEvent] = [
            event(.connected, 0, "connected to web-01 as deploy"),
            upload(1), download(2), failedTransfer(3),
            event(.disconnected, 4, "disconnected"),
        ]

        let rows = ConnectionHistory.rows(from: events)

        #expect(rows.count == 1)
        #expect(rows[0].bytes == nil)
    }

    // MARK: - The reader and the writer

    private func makeItem(
        fileName: String, direction: TransferDirection
    ) -> TransferQueueViewModel.Item {
        TransferQueueViewModel.Item(
            id: UUID(), fileName: fileName, direction: direction, status: .finished,
            sourcePath: RemotePath.join("/source", fileName),
            destinationTabID: nil, isEditUpload: false, destinationDirectory: "/dest",
            destinationPath: RemotePath.join("/dest", fileName),
            destinationSupportsResume: true, crossRemote: false, crossBackendTarget: nil)
    }

    /// The one test here that does not hand-build its events. `AuditRecorder`
    /// writes a transfer's direction into the head of the detail text, and
    /// `ConnectionHistory` reads it back from there; this drives the real
    /// recorder for both directions so the two cannot drift apart in
    /// silence.
    @Test func theVerbTheRecorderWritesIsTheVerbTheHistoryReads() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AuditLogStore(directory: directory)
        let sessionID = UUID()
        let recorder = AuditRecorder(sessionID: sessionID, store: store)

        recorder.recordConnected(host: "web-01", username: "deploy")
        recorder.recordTransfer(makeItem(fileName: "a.txt", direction: .upload), targetTitle: nil)
        recorder.recordTransfer(makeItem(fileName: "b.txt", direction: .download), targetTitle: nil)
        recorder.recordTransfer(makeItem(fileName: "c.txt", direction: .download), targetTitle: nil)
        recorder.recordDisconnected()

        let rows = ConnectionHistory.rows(from: store.events(for: sessionID))

        #expect(rows.count == 1)
        #expect(rows[0].uploads == 1)
        #expect(rows[0].downloads == 2)
    }

    /// The positive companion to the negative checks above: the verb
    /// vocabulary has exactly the two members the directions have, and each
    /// one is recognized in the detail shape the recorder writes.
    @Test func everyVerbIsRecognizedAtTheHeadOfADetail() {
        #expect(AuditEvent.TransferVerb.allCases.count == 2)
        for verb in AuditEvent.TransferVerb.allCases {
            let sample = AuditEvent(
                kind: .transferFinished, detail: "\(verb.rawValue) file.txt → /tmp")
            #expect(sample.transferVerb == verb)
        }
        let unrelated = AuditEvent(kind: .rename, detail: "renamed a.txt to b.txt")
        #expect(unrelated.transferVerb == nil)
    }

    @Test func anEmptyLogHasNoRows() {
        #expect(ConnectionHistory.rows(from: []).isEmpty)
    }
}
