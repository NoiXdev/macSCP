import Foundation
import Testing

@testable import macSCPCore

/// `SessionNameRule` — is this name already taken, and by which session.
///
/// Two matchings, because two callers ask two different questions of the same
/// list. `.caseInsensitive` answers "would a person call these the same
/// name", which is what a command line refuses on. `.exactAsSaved` answers
/// "which session would `SessionListViewModel.save` overwrite", which is what
/// a warning that says *replaces* must be measured against. Every call below
/// names its matching, because the function has no default to inherit.
@Suite("Session name rule")
struct SessionNameRuleTests {

    // MARK: - `.caseInsensitive`: trimmed on both sides, case folded

    @Test func caseAloneDoesNotMakeADifferentName() {
        let stored = sshSession(name: "prod")
        #expect(SessionNameRule.conflict(
            "Prod", among: [stored], matching: .caseInsensitive)?.id == stored.id)
    }

    @Test func surroundingWhitespaceDoesNotMakeADifferentName() {
        // Both directions: the asked name and the stored one. The stored side
        // is the half a rule that only trims its argument gets wrong.
        let storedPadded = sshSession(name: " prod ")
        #expect(SessionNameRule.conflict(
            "Prod", among: [storedPadded], matching: .caseInsensitive)?.id
            == storedPadded.id)

        let stored = sshSession(name: "prod")
        #expect(SessionNameRule.conflict(
            "  Prod  ", among: [stored], matching: .caseInsensitive)?.id == stored.id)
    }

    @Test func aFreeNameConflictsWithNothing() {
        #expect(SessionNameRule.conflict(
            "prod", among: [sshSession(name: "staging")], matching: .caseInsensitive) == nil)
    }

    @Test func theExcludedSessionIsNotAConflictWithItself() {
        let editing = sshSession(name: "prod")
        #expect(SessionNameRule.conflict(
            "Prod", among: [editing], excluding: editing.id, matching: .caseInsensitive) == nil)
    }

    @Test func excludingOneSessionStillFindsAnother() {
        // The positive beside the negative above: `excluding:` must step past
        // exactly one session, not switch the rule off.
        let editing = sshSession(name: "old")
        let other = sshSession(name: "prod")
        #expect(SessionNameRule.conflict(
            "Prod", among: [editing, other], excluding: editing.id,
            matching: .caseInsensitive)?.id == other.id)
    }

    @Test func theFirstConflictingSessionIsReported() {
        let first = sshSession(name: "prod")
        let second = sshSession(name: "PROD")
        #expect(SessionNameRule.conflict(
            "Prod", among: [first, second], matching: .caseInsensitive)?.id == first.id)
    }

    // MARK: - `.exactAsSaved`: the app's save-mirroring matching

    @Test func theSaveMirroringMatchingIsCaseSensitive() {
        // `SessionListViewModel.save` finds its target through this very
        // matching, which compares with `==`. A warning
        // saying "saving replaces prod" while saving would create a second
        // session called "Prod" describes an outcome that does not happen.
        #expect(SessionNameRule.conflict(
            "Prod", among: [sshSession(name: "prod")], matching: .exactAsSaved) == nil)
    }

    @Test func theSaveMirroringMatchingTrimsOnlyTheAskedName() {
        // `save` never sees what a name field holds — both write paths trim
        // before calling it — but it does not trim the STORED names either.
        #expect(SessionNameRule.conflict(
            " prod", among: [sshSession(name: "prod")], matching: .exactAsSaved)?.name == "prod")
        #expect(SessionNameRule.conflict(
            "prod", among: [sshSession(name: "prod ")], matching: .exactAsSaved) == nil)
    }

    @Test func bothMatchingsExcludeTheSameWay() {
        let editing = sshSession(name: "prod")
        #expect(SessionNameRule.conflict(
            "prod", among: [editing], excluding: editing.id, matching: .exactAsSaved) == nil)
    }
}
