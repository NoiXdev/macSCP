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
