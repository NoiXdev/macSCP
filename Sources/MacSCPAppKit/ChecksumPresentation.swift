import Foundation
import Observation
import macSCPCore

/// Everything a surface shows about one checksum, computed from the result
/// and from nothing else.
///
/// A pure value, so what the app SAYS for each answer a backend can give is
/// decidable without rendering anything (`ChecksumDisplayTests`). That is
/// half the reason it exists. The other half is the design's central
/// promise, and it is structural: the only way for a view to obtain a
/// digest is to obtain a `ChecksumDisplay`, and a `ChecksumDisplay` has no
/// digest without a `qualification` beside it in the same value. Reaching
/// the number and reaching the sentence about it are one act.
///
/// An object store's multipart ETag is why the promise is worth structure.
/// It is a well-formed MD5 that is not the file's hash, it appears on
/// exactly the large files someone bothers to check, and shown bare it is
/// indistinguishable from an answer. `ChecksumSurfaceGuardTests` carries
/// the last stretch — that the view reads every part of this value.
struct ChecksumDisplay: Equatable, Sendable {
    /// How much the value wants to be trusted.
    enum Severity: Equatable, Sendable {
        /// A digest of the file's bytes, or a plain statement.
        case plain
        /// A number that looks like a digest of the file and is not one.
        case caution
        /// The request failed for this file.
        case failure
    }

    /// The digest, bare, exactly as it would be pasted into a comparison —
    /// or, where there is no digest, the sentence that stands in its place.
    let value: String

    /// What qualifies `value`: the algorithm it actually is, where it came
    /// from, and — for a multipart ETag — that it is not the file's
    /// checksum. Empty only when `value` is itself a sentence.
    let qualification: String

    /// Whether `value` is a digest of the file, something else wearing a
    /// digest's shape, or a failure.
    let severity: Severity

    static func of(_ result: ChecksumRequestResult) -> ChecksumDisplay {
        switch result {
        case .checksum(let checksum):
            return ChecksumDisplay(
                value: checksum.hex,
                qualification: qualification(of: checksum),
                // Read off the value's own account of itself rather than
                // matched case by case, so a provenance added later cannot
                // land on `.plain` by being forgotten here.
                severity: checksum.describesFileContent ? .plain : .caution)
        case .unavailableOnThisConnection:
            return ChecksumDisplay(
                value: L10n.string(
                    "checksum.unavailable", "This server does not provide checksums."),
                qualification: "",
                // Not a failure. Nothing went wrong; this protocol has no
                // digest to report, which is a fact about the server and is
                // said as one.
                severity: .plain)
        case .failed(let message):
            return ChecksumDisplay(
                value: String(
                    format: L10n.string(
                        "checksum.failed", "The checksum could not be computed. %@"),
                    message),
                qualification: "",
                severity: .failure)
        }
    }

    /// The algorithm named is the VALUE's, never the one that was asked
    /// for. An object store computes nothing on demand, so a SHA-256
    /// request against S3 comes back as the ETag's MD5 — labelled MD5,
    /// which is the only thing that makes the substitution honest.
    private static func qualification(of checksum: FileChecksum) -> String {
        let name = checksum.algorithm.displayName
        switch checksum.provenance {
        case .computedOnRemote:
            return String(
                format: L10n.string("checksum.origin.remote", "%@, computed on the server."),
                name)
        case .computedLocally:
            return String(
                format: L10n.string("checksum.origin.local", "%@, computed on this Mac."),
                name)
        case .objectStorageETagSinglePart:
            return String(
                format: L10n.string(
                    "checksum.origin.etag",
                    "%@, from the object store’s ETag — the checksum of the stored file."),
                name)
        case .objectStorageETagMultipart:
            return String(
                format: L10n.string(
                    "checksum.origin.etagMultipart",
                    """
                    %@, from the object store’s ETag for an upload that arrived in several \
                    parts. It is not the checksum of the file and will not match one.
                    """),
                name)
        }
    }
}

/// Whether a result that just came back is worth recording.
///
/// A failure that arrived because the request was CANCELLED is not a fact
/// about the file: the far side was still working when we stopped
/// listening, so "could not be computed" would read as a property of the
/// file rather than of the cancel. A result that completed before the
/// cancel landed is kept — it is a real answer, and keeping it is the whole
/// point of a cancel that leaves the computed work standing.
///
/// One function rather than the condition written twice: the info sheet
/// asks about one file and `ChecksumBatch` about a selection, and what a
/// cancel means must not come apart between them.
enum ChecksumInterruption {
    static func isWorthRecording(_ result: ChecksumRequestResult, cancelled: Bool) -> Bool {
        if case .failed = result, cancelled { return false }
        return true
    }
}

/// One selection's run: the files in it, computed one after another, each
/// result standing the moment it is there.
///
/// Hashing is a transfer — the design says so, and the reason is measurable:
/// a checksum over 40 GB takes minutes on the far side. So the run is a
/// sequence with a way out, not a modal wait. Cancelling stops the run and
/// keeps every result already computed; nothing is cleared and nothing rolls
/// back.
///
/// The computation arrives as a closure rather than as a file system, which
/// is what lets `ChecksumBatchTests` drive the ordering, the arrival of a
/// result and the cancel without any connection at all.
@Observable
@MainActor
final class ChecksumBatch: Identifiable {
    /// Identity for `.sheet(item:)`: a run is one presentation, and a new
    /// selection is a new run rather than a change to this one.
    let id = UUID()

    struct Row: Identifiable, Equatable {
        let item: RemoteFileItem
        /// `nil` until this file has been asked about — and it stays `nil`
        /// for a file the cancel interrupted, because an interrupted
        /// computation has no answer about that file.
        var result: ChecksumRequestResult?

        var id: String { item.path }
    }

    /// The files of the selection, in the order it had. Folders and
    /// symlinks are not rows: they have no digest, and a row that could
    /// only ever say so would be a dead entry in a list.
    private(set) var rows: [Row]
    private(set) var isRunning = false
    /// Set when a run ended because it was cancelled, so the sheet can say
    /// that the list is short on purpose.
    private(set) var wasCancelled = false

    /// The algorithm this run was started with. Held rather than re-read
    /// from the settings, so changing the setting mid-run cannot make the
    /// heading disagree with the values below it.
    let algorithm: ChecksumAlgorithm

    private var task: Task<Void, Never>?

    /// Told about each result the moment it stands, with the file it is
    /// about — how a value the user asked for reaches anything beyond this
    /// sheet (the pane's `ChecksumLedger`, which the checksum column reads).
    ///
    /// A report, not a second computation: it is called with what was
    /// already recorded into `rows`, exactly once per row that got an
    /// answer, and never for a row the cancel interrupted. Defaulted to a
    /// no-op so a surface that only wants the sheet stays a two-argument
    /// construction.
    private let onResult: (ChecksumRequestResult, RemoteFileItem) -> Void

    init(
        selection: [RemoteFileItem],
        algorithm: ChecksumAlgorithm,
        onResult: @escaping (ChecksumRequestResult, RemoteFileItem) -> Void = { _, _ in }
    ) {
        self.rows = selection.filter { $0.kind == .file }.map { Row(item: $0, result: nil) }
        self.algorithm = algorithm
        self.onResult = onResult
    }

    var finishedCount: Int { rows.filter { $0.result != nil }.count }

    /// Starts the run and returns the task driving it.
    ///
    /// The sheet discards the task — `cancel()` is the only handle it needs
    /// — while the tests await it, which is how the END of a run is
    /// observable without polling for it.
    @discardableResult
    func start(
        _ compute: @escaping @MainActor (RemoteFileItem) async -> ChecksumRequestResult
    ) -> Task<Void, Never> {
        cancel()
        isRunning = true
        wasCancelled = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for index in self.rows.indices {
                if Task.isCancelled { break }
                let result = await compute(self.rows[index].item)
                guard ChecksumInterruption.isWorthRecording(
                    result, cancelled: Task.isCancelled)
                else { break }
                self.rows[index].result = result
                self.onResult(result, self.rows[index].item)
            }
            self.wasCancelled = Task.isCancelled
            self.isRunning = false
            self.task = nil
        }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
    }
}
