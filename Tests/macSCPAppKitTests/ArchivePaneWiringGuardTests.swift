import Foundation
import MacSCPTestSupport
import Testing

/// Guards the wiring of the archive actions inside the App target, which
/// cannot be instantiated from a test (the boundary
/// `PaneRenderConditionGuardTests` documents): a source-text scan over the
/// COMMENT-FREE view of each file, because the files carry comments that
/// quote the very calls a scanner looks for.
///
/// Every NEGATIVE check below has a POSITIVE one beside it asserting that the
/// thing it scans is there at all -- without that, a rename would leave the
/// negative matching nothing and passing.
@Suite("Archive pane wiring guard")
struct ArchivePaneWiringGuardTests {
    private static let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")

    /// Whitespace runs collapsed to one space, so a call wrapped across
    /// lines reads the same as one on a single line.
    private static func code(_ file: String) throws -> String {
        let code = try SourceCorpus.commentFree(of: root.appendingPathComponent(file))
        return code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    // MARK: The runner

    /// The remote runner is made over the file system the pane browses and
    /// nothing else: `init?(backend: any Sendable)` accepts any argument and
    /// answers `nil` for a wrong one forever.
    @Test func theRemoteRunnerIsMadeOverThePanesOwnFileSystem() throws {
        let code = try Self.code("BrowserPane+Archive.swift")
        #expect(Self.occurrences(of: "RemoteArchiveRunner(", in: code) == 1)
        #expect(code.contains("case .remote: RemoteArchiveRunner(backend: fileSystem)"))
        #expect(code.contains("case .local: LocalArchiveRunner()"))
    }

    /// The pane's `fileSystem` is the session's remote one at the remote
    /// call site, which is what ties the argument above to the gate's.
    @Test func theRemotePaneIsHandedTheSessionsRemoteFileSystem() throws {
        let code = try Self.code("ContentView+Detail.swift")
        #expect(code.contains("fileSystem: session.remoteFS"))
        #expect(code.contains("fileSystem: session.localFS"))
    }

    // MARK: Entries are handled inside the pane, before they could be forwarded

    @Test func theArchiveEntriesAreHandledBeforeTheForwardingDefault() throws {
        let code = try Self.code("BrowserPane.swift")
        let compress = try #require(
            code.range(of: "case .compressTo(let format): startCompress(format, selection: selection)"))
        let extract = try #require(
            code.range(of: "case .extractArchive(let format): beginExtract(format, selection: selection)"))
        let forward = try #require(code.range(of: "default: onMenuAction?(entry, selection)"))
        #expect(compress.upperBound <= forward.lowerBound)
        #expect(extract.upperBound <= forward.lowerBound)
    }

    @Test func theRowTheSheetAndTheReloadAreWired() throws {
        let code = try Self.code("BrowserPane.swift")
        #expect(code.contains("ArchiveActivityRow(activity: viewModel.archiveActivity)"))
        #expect(code.contains(".sheet(item: $extractRequest)"))
        #expect(code.contains("ExtractDestinationSheet("))
        // The reload when the activity goes idle.
        #expect(code.contains(".onChange(of: viewModel.archiveActivity.state)"))
        #expect(code.contains("if current == .idle, previous != .idle { Task { await viewModel.refresh() } }"))
    }

    // MARK: The alert is the route for the sentences the row does not carry

    /// A refusal (`gzTargetExists` among them), a listing too large to
    /// preview, and "another operation is running" reach the user ONLY through
    /// this alert. Dropping or re-binding it makes all of them silent while
    /// every mapping test stays green, because the mapping is still exercised
    /// directly -- so the alert's title, its binding to the message, and the
    /// message's own text are each pinned.
    @Test func theAlertThatCarriesTheArchiveSentencesIsBoundToTheirState() throws {
        let code = try Self.code("BrowserPane.swift")
        #expect(code.contains("@State var archiveAlertMessage: String?"))
        #expect(code.contains(".alert(ArchivePresentation.alertTitle,"))
        #expect(code.contains("get: { archiveAlertMessage != nil }"))
        #expect(code.contains("set: { if !$0 { archiveAlertMessage = nil } }"))
        #expect(code.contains("message: { Text(archiveAlertMessage ?? \"\") }"))
        // The title and binding are one `.alert`, not two things that merely
        // both appear in the file.
        let alert = try #require(code.range(of: ".alert(ArchivePresentation.alertTitle,"))
        let tail = String(code[alert.upperBound...].prefix(400))
        #expect(tail.contains("get: { archiveAlertMessage != nil }"))
        #expect(tail.contains("message: { Text(archiveAlertMessage ?? \"\") }"))
    }

    /// The writers of that state: the positive beside the alert above. Each
    /// is a sentence from `ArchivePresentation`, never a literal.
    @Test func everyWriterOfTheAlertStateSpeaksThroughThePresentation() throws {
        let code = try Self.code("BrowserPane+Archive.swift") + " " + Self.code("BrowserPane.swift")
        #expect(Self.occurrences(of: "archiveAlertMessage = ", in: code) >= 4)
        #expect(code.contains("archiveAlertMessage = ArchivePresentation.busy"))
        #expect(code.contains("archiveAlertMessage = ArchivePresentation.message(for: error)"))
        #expect(code.contains("archiveAlertMessage = ArchivePresentation.message(for: refusal)"))
        // Every assignment other than the alert's own dismissal (`= nil`)
        // goes through `ArchivePresentation`.
        var rest = Substring(code)
        var checked = 0
        while let hit = rest.range(of: "archiveAlertMessage = ") {
            let after = rest[hit.upperBound...]
            if !after.hasPrefix("nil") {
                #expect(after.hasPrefix("ArchivePresentation."), "\(after.prefix(60))")
                checked += 1
            }
            rest = after
        }
        #expect(checked >= 3)
    }

    /// A refusal ends the activity as `.refused` and the pane turns it into
    /// the alert; the row deliberately does not show it.
    @Test func aRefusalReachesTheAlertAndNotTheRow() throws {
        let code = try Self.code("BrowserPane.swift")
        #expect(code.contains(".onChange(of: viewModel.archiveActivity.lastOutcome)"))
        #expect(code.contains("if case .refused(let refusal) = outcome {"))
        let row = try Self.code("ArchiveActivityRow.swift")
        #expect(row.contains("!ending.isRefusal"))
    }

    // MARK: Nothing owns a preparation but the activity

    /// The plan is made, and the archive listed, INSIDE `ArchiveActivity`, so
    /// the one `cancel()` a tab's teardown calls reaches both. An unstructured
    /// `Task` here would be owned by nothing: a tab closed while the folder
    /// was being read found no operation to cancel, and the run started
    /// afterwards on a pane that no longer existed.
    @Test func noPreparationRunsInATaskNothingOwns() throws {
        let code = try Self.code("BrowserPane+Archive.swift")
        #expect(code.contains("makePlan:"))
        #expect(code.contains("viewModel.archiveActivity.preview("))
        #expect(!code.contains("Task {"))
        #expect(!code.contains("Task("))
        #expect(!code.contains("Task.detached"))
        // Other spellings of the same thing, so the guard does not buy one
        // spelling and reveal another.
        #expect(!code.contains("Task.init"))
        #expect(!code.contains("Task<"))
        // `Task{ @MainActor in … }` is legal Swift, and the whitespace
        // collapse above leaves it as `Task{`, which `"Task {"` does not
        // match (found by the final whole-branch review, 2026-10-09).
        #expect(!code.contains("Task{"))
        #expect(!code.contains("DispatchQueue"))
        #expect(!code.contains("Thread"))
    }

    // MARK: What the names and the preview are built from

    /// The pane's table can be hiding dotfiles; a collision count or a free
    /// name built from it under-reports. The archive entries must go
    /// through `ArchivePreparation`, which lists the file system itself, and
    /// must not touch the table's items.
    @Test func theArchiveEntriesNeverReadWhatTheTableShows() throws {
        let code = try Self.code("BrowserPane+Archive.swift")
        // Positive: the calls that list the file system are there.
        #expect(code.contains("ArchivePreparation.compress("))
        #expect(code.contains("ArchivePreparation.extractPreview("))
        // Negative: nothing in this file reads the displayed rows.
        #expect(!code.contains("viewModel.items"))
        #expect(!code.contains(".items"))
        #expect(!code.contains("namesInFolder:"))
    }

    // MARK: The subfolder

    /// The directory is created through the file system, inside the
    /// activity, before the runner is asked -- and not by a shell `mkdir`.
    @Test func theSubfolderIsCreatedThroughTheFileSystemBeforeTheRun() throws {
        let code = try Self.code("BrowserPane+Archive.swift")
        #expect(code.contains("prepare: { try await ArchivePreparation.makeDestination("))
        #expect(!code.contains("mkdir"))
        let core = try SourceCorpus.commentFree(
            of: SourceCorpus.url(of: .sources)
                .appendingPathComponent("macSCPCore/Archive/ArchivePreparation.swift"))
        #expect(core.contains("createDirectory(at:"))
        #expect(!core.contains("mkdir"))
    }

    // MARK: The sheet

    @Test func theSheetRefusesATypedNameThatExists() throws {
        let code = try Self.code("ExtractDestinationSheet.swift")
        #expect(code.contains("preview.isSubfolderNameTaken(subfolderName)"))
        #expect(code.contains("ExtractPreview.isUsableSubfolderName(subfolderName) && !nameIsTaken"))
        #expect(code.contains("archive.extract.subfolderTaken"))
    }

    // MARK: Lifecycle

    @Test func aTabsTeardownCancelsBothPanesArchiveOperations() throws {
        let code = try Self.code("TabTeardown.swift")
        #expect(code.contains("session.local.archiveActivity.cancel()"))
        #expect(code.contains("session.remote.archiveActivity.cancel()"))
        // Before the queue sweep, which is the first stage.
        let cancel = try #require(code.range(of: "session.remote.archiveActivity.cancel()"))
        let sweep = try #require(code.range(of: "await tab.transferQueue.cancelAll("))
        #expect(cancel.upperBound <= sweep.lowerBound)
    }

    /// The transfer queue is untouched: its status type stays byte-shaped.
    @Test func theTransferQueueKnowsNothingOfArchives() throws {
        let sources = SourceCorpus.url(of: .sources)
        let queue = try SourceCorpus.commentFree(
            of: sources.appendingPathComponent("macSCPCore/Presentation/TransferQueueViewModel.swift"))
        #expect(queue.contains("enum Status"))
        #expect(!queue.contains("Archive"))
    }
}
