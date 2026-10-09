import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// What the pane SAYS about an archive operation: one sentence per ending,
/// one per refusal, and none of them built from a tool's output.
@Suite(.timeLimit(.minutes(1)))
struct ArchivePresentationTests {
    @Test func aCancelAndASuccessSayNothing() {
        #expect(ArchivePresentation.message(for: ArchiveActivity.Ending.finished) == nil)
        #expect(ArchivePresentation.message(for: ArchiveActivity.Ending.cancelled) == nil)
    }

    /// The three failures and the unreached verdict are four different
    /// sentences. Compared against each other rather than against a
    /// catalogue string: a table that mapped two of them to one key would
    /// pass a check that only asked for "some text".
    @Test func everyEndingThatNeedsASentenceHasItsOwn() {
        let endings: [ArchiveActivity.Ending] = [
            .failed(.toolMissing(tool: "zip")), .failed(.exited(status: 3)),
            .failed(.timedOut), .couldNotRun,
        ]
        let sentences = endings.compactMap { ArchivePresentation.message(for: $0) }
        #expect(sentences.count == endings.count)
        #expect(Set(sentences).count == endings.count)
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }

    /// What a sentence may contain: our own tool name and the status number,
    /// both ours. The test pins that they appear, so the format arguments
    /// cannot be dropped silently.
    @Test func theFailuresNameOnlyWhatIsOurs() {
        let missing = ArchivePresentation.message(for: .failed(.toolMissing(tool: "unzip")))
        #expect(missing?.contains("unzip") == true)
        let exited = ArchivePresentation.message(for: .failed(.exited(status: 42)))
        #expect(exited?.contains("42") == true)
    }

    @Test func aTimeoutIsNotTheGenericSentence() {
        #expect(
            ArchivePresentation.message(for: .failed(.timedOut))
                != ArchivePresentation.message(for: .couldNotRun))
    }

    @Test func everyRefusalHasASentenceOfItsOwn() {
        let refusals: [ArchiveRefusal] = [
            .emptySelection, .gzTakesExactlyOneFile(count: 2),
            .gzTakesAFileNotAFolder(name: "dir"),
            .newlineInNameUnsupportedByZip(name: "a\nb"),
            .gzExtractsIntoThisFolderOnly,
            .gzTargetExists(name: "f.gz"),
            .gzExtractTargetExists(name: "notes.txt"),
            .wildcardInNameUnsupportedByUnzip(name: "b*.zip"),
            .tarHasNoSkipExistingFlag,
        ]
        let sentences = refusals.map { ArchivePresentation.message(for: $0) }
        #expect(Set(sentences).count == refusals.count)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        // The names the user chose are theirs to be told back.
        #expect(ArchivePresentation.message(for: .gzTargetExists(name: "f.gz")).contains("f.gz"))
        #expect(ArchivePresentation.message(for: .gzTakesAFileNotAFolder(name: "dir")).contains("dir"))
    }

    /// The error funnel the sheet and the alert use: a refusal, a failure and
    /// a too-large listing each reach their own sentence, and anything else
    /// -- a file system error whose text is the far side's -- reaches the
    /// generic one without being quoted.
    @Test func anyErrorReachesASentenceAndAnUnknownOneIsNotQuoted() {
        struct Foreign: Error, CustomStringConvertible {
            let description = "ghost-text-from-the-far-side"
        }
        let unknown = ArchivePresentation.message(for: Foreign())
        #expect(unknown == ArchivePresentation.message(for: .couldNotRun))
        #expect(unknown.contains("ghost") == false)

        #expect(
            ArchivePresentation.message(for: ArchiveListingTooLarge(limit: 1))
                != ArchivePresentation.message(for: Foreign()))
        #expect(
            ArchivePresentation.message(for: ArchiveFailure.timedOut)
                == ArchivePresentation.message(for: .failed(.timedOut)))
        #expect(
            ArchivePresentation.message(for: ArchiveRefusal.emptySelection)
                == ArchivePresentation.message(for: ArchiveRefusal.emptySelection))
    }

    @Test func theRunningRowNamesTheVerbAndTheArchive() {
        let compressing = ArchivePresentation.runningText(
            operation: .compress(.zip), title: "out.zip")
        let extracting = ArchivePresentation.runningText(
            operation: .extract(.zip), title: "out.zip")
        #expect(compressing.contains("out.zip"))
        #expect(extracting.contains("out.zip"))
        #expect(compressing != extracting)
    }
}
