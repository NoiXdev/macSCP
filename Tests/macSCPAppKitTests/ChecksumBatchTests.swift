import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// A selection's run: one file after another, each result standing as soon
/// as it is there, and cancelling leaving what was already computed.
///
/// The run is a plain object with the computation injected as a closure, so
/// all of this is decidable without a connection and without a view. The
/// interleaving is driven by the closure itself rather than by sleeps —
/// the file that blocks does so until the run is cancelled, which is the
/// only event the test is waiting for anyway.
@Suite("Checksum batch")
@MainActor
struct ChecksumBatchTests {
    private static func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .file, size: 1)
    }
    private static let directory = RemoteFileItem(
        name: "d", path: "/d", kind: .directory, size: nil)

    private static func digest(_ seed: String) -> ChecksumRequestResult {
        .checksum(FileChecksum.computedOnRemote(
            .sha256, hex: String(repeating: seed, count: 64))!)
    }

    // MARK: - What a run covers

    /// Folders have no digest, so they are not rows. A mixed selection
    /// therefore produces a run over its files and nothing that needs
    /// explaining away.
    @Test func onlyTheFilesOfASelectionBecomeRows() {
        let batch = ChecksumBatch(
            selection: [Self.directory, Self.file("a"), Self.file("b")],
            algorithm: .sha256)

        #expect(batch.rows.map(\.item.path) == ["/a", "/b"])
        #expect(batch.rows.allSatisfy { $0.result == nil })
    }

    @Test func theAlgorithmTheRunWasStartedWithIsTheOneItReports() {
        #expect(ChecksumBatch(selection: [Self.file("a")], algorithm: .md5).algorithm == .md5)
    }

    // MARK: - One after another

    @Test func filesAreComputedOneAfterAnotherInSelectionOrder() async {
        let order = Recorder()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b"), Self.file("c")], algorithm: .sha256)

        await batch.start { item in
            order.append(item.path)
            return Self.digest("1")
        }.value

        #expect(order.paths == ["/a", "/b", "/c"])
        #expect(batch.rows.allSatisfy { $0.result != nil })
        #expect(!batch.isRunning)
    }

    /// A result stands the moment it is there rather than at the end of
    /// the run — a checksum over 40 GB takes minutes on the far side, and
    /// a list that fills in only once everything is done would be the
    /// window with no way out that this design rejects.
    @Test func aResultAppearsBeforeTheNextFileIsFinished() async {
        let blocked = Blocker()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b")], algorithm: .sha256)

        let task = batch.start { item in
            guard item.path == "/b" else { return Self.digest("1") }
            await blocked.waitUntilCancelled()
            return .failed("interrupted")
        }

        while batch.rows[0].result == nil { await Task.yield() }
        #expect(batch.rows[1].result == nil)
        #expect(batch.isRunning)

        batch.cancel()
        await task.value
    }

    // MARK: - Cancelling

    /// The point of the whole arrangement: what is already computed stays
    /// on screen. Nothing is cleared, and the run does not roll back.
    ///
    /// The blocked file answers `.failed` once the run is cancelled,
    /// because that is what the real path does: every backend's checksum
    /// call checks cancellation and throws, and
    /// `RemoteBrowserViewModel.checksum` turns a throw into `.failed`.
    @Test func cancellingLeavesWhatWasAlreadyComputedStanding() async {
        let blocked = Blocker()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b"), Self.file("c")], algorithm: .sha256)

        let task = batch.start { item in
            guard item.path == "/b" else { return Self.digest("1") }
            await blocked.waitUntilCancelled()
            return .failed("interrupted")
        }

        while batch.rows[0].result == nil { await Task.yield() }
        batch.cancel()
        await task.value

        #expect(batch.rows[0].result == Self.digest("1"))
        #expect(batch.rows[1].result == nil, """
            the file that was interrupted mid-computation reported something. An interrupted \
            computation has no answer about that file — reporting one would read as a \
            property of the file rather than of the cancel.
            """)
        #expect(batch.rows[2].result == nil)
        #expect(!batch.isRunning)
        #expect(batch.wasCancelled)
    }

    /// A run that finished on its own was not cancelled, so the sheet has
    /// no reason to say anything about a cancel.
    @Test func aRunThatFinishesIsNotReportedAsCancelled() async {
        let batch = ChecksumBatch(selection: [Self.file("a")], algorithm: .sha256)
        await batch.start { _ in Self.digest("1") }.value

        #expect(!batch.wasCancelled)
        #expect(!batch.isRunning)
    }

    /// Cancelling before anything landed leaves an empty list rather than
    /// a list of failures.
    @Test func cancellingImmediatelyRecordsNoResultAtAll() async {
        let blocked = Blocker()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b")], algorithm: .sha256)

        let task = batch.start { _ in
            await blocked.waitUntilCancelled()
            return .failed("interrupted")
        }
        batch.cancel()
        await task.value

        #expect(batch.rows.allSatisfy { $0.result == nil })
        #expect(batch.wasCancelled)
    }

    /// The other half of the same rule, and the reason it is phrased about
    /// the RESULT rather than about the cancel: a backend that ignored the
    /// cancellation and finished anyway produced a real answer about that
    /// file, and throwing it away would lose work that was already done.
    /// The run still stops — the file after it is never started.
    @Test func aFileThatFinishedDespiteTheCancelKeepsItsAnswer() async {
        let blocked = Blocker()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b"), Self.file("c")], algorithm: .sha256)

        let task = batch.start { item in
            if item.path == "/b" { await blocked.waitUntilCancelled() }
            return Self.digest("1")
        }

        while batch.rows[0].result == nil { await Task.yield() }
        batch.cancel()
        await task.value

        #expect(batch.rows[1].result == Self.digest("1"))
        #expect(batch.rows[2].result == nil)
        #expect(batch.wasCancelled)
    }

    /// A file that fails does not stop the run: the next file may be fine,
    /// which is the same distinction the outcome type makes between "this
    /// file went wrong" and "this connection cannot answer".
    @Test func aFailedFileDoesNotEndTheRun() async {
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b")], algorithm: .sha256)

        await batch.start { item in
            item.path == "/a" ? .failed("nope") : Self.digest("1")
        }.value

        #expect(batch.rows[0].result == .failed("nope"))
        #expect(batch.rows[1].result == Self.digest("1"))
    }

    // MARK: - What the run reports onwards

    /// Every result the run records is also handed to whoever asked to be
    /// told (2026-09-02) — the pane's ledger, which is what lets the
    /// checksum column show a value the user asked for. Same value, same
    /// item, once each: the sink is a report of what happened, not a second
    /// computation.
    @Test func everyRecordedResultIsReportedOnceWithItsItem() async {
        let reported = ResultRecorder()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b")], algorithm: .sha256,
            onResult: { result, item in reported.append(result, item) })

        await batch.start { item in
            item.path == "/a" ? Self.digest("1") : .unavailableOnThisConnection
        }.value

        #expect(reported.paths == ["/a", "/b"])
        #expect(reported.results == [Self.digest("1"), .unavailableOnThisConnection])
    }

    /// A file whose only "result" was the cancel interrupting it has no
    /// answer, so nothing is reported for it either — the sink sees exactly
    /// what the rows see, never more.
    @Test func aRowTheCancelInterruptedIsNotReported() async {
        let reported = ResultRecorder()
        let blocked = Blocker()
        let batch = ChecksumBatch(
            selection: [Self.file("a"), Self.file("b")], algorithm: .sha256,
            onResult: { result, item in reported.append(result, item) })

        let task = batch.start { _ in
            await blocked.waitUntilCancelled()
            return .failed("interrupted")
        }
        batch.cancel()
        await task.value

        #expect(reported.paths.isEmpty)
    }

    // MARK: - The rule both surfaces apply

    /// Stated once, so the info sheet (one file) and the run (a selection)
    /// cannot come apart on what a cancel means. Both directions, because
    /// only one of them is obvious.
    @Test func onlyAFailureCausedByACancelIsWorthNothing() {
        #expect(!ChecksumInterruption.isWorthRecording(.failed("x"), cancelled: true))
        #expect(ChecksumInterruption.isWorthRecording(.failed("x"), cancelled: false))
        #expect(ChecksumInterruption.isWorthRecording(Self.digest("1"), cancelled: true))
        #expect(ChecksumInterruption.isWorthRecording(
            .unavailableOnThisConnection, cancelled: true))
    }
}

/// Records the order the run asked about files in.
@MainActor
private final class Recorder {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}

/// Records what the run reported onwards, in the order it reported it.
@MainActor
private final class ResultRecorder {
    private(set) var results: [ChecksumRequestResult] = []
    private(set) var paths: [String] = []
    func append(_ result: ChecksumRequestResult, _ item: RemoteFileItem) {
        results.append(result)
        paths.append(item.path)
    }
}

/// Suspends until the surrounding task is cancelled, cooperatively and
/// without a deadline: the tests that use it always cancel, and a sleep
/// would put a wall-clock number into a test that has nothing to time.
private struct Blocker: Sendable {
    func waitUntilCancelled() async {
        while !Task.isCancelled { await Task.yield() }
    }
}