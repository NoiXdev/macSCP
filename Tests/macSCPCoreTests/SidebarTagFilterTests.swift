import Foundation
import Testing

@testable import macSCPCore

private func tagged(_ name: String, _ tags: [String]) -> StoredSession {
    StoredSession(name: name, tags: tags)
}

/// The sidebar's filter VALUE — the set of tags and the join — as opposed to
/// what `SidebarVisibility.compute` does with it, which
/// `SidebarVisibilityTests` covers.
///
/// Everything the design calls decidable is decided here: that the threshold
/// bites, that "all" and "any" pick out different sessions, that the join is
/// offered only once it means something and is not forgotten when the
/// selection falls back below that, and that dropping a filter keeps the
/// join. What the design says no test can decide — whether the threshold
/// sits in the right place — is why `dialogTagThreshold` is one named
/// constant rather than a literal at the point of drawing.
@Suite("Sidebar tag filter")
struct SidebarTagFilterTests {
    // MARK: - Selecting

    @Test func togglingSelectsThenDeselectsTheSameTag() {
        let once = SidebarTagFilter.none.toggling("docker")
        #expect(once.tags == ["docker"])
        #expect(once.toggling("docker").isEmpty)
    }

    @Test func togglingASecondTagKeepsTheFirst() {
        let both = SidebarTagFilter.none.toggling("docker").toggling("web")
        #expect(both.tags == ["docker", "web"])
    }

    @Test func anEmptyFilterMatchesEverySessionIncludingUntaggedOnes() {
        #expect(SidebarTagFilter.none.matches(tags: []))
        #expect(SidebarTagFilter.none.matches(tags: ["docker"]))
    }

    // MARK: - The join

    /// The intersection: every selected tag has to be on the session.
    @Test func joinAllKeepsOnlySessionsCarryingEverySelectedTag() {
        let filter = SidebarTagFilter(tags: ["docker", "web"], join: .all)
        #expect(filter.matches(tags: ["docker", "web", "eu"]))
        #expect(!filter.matches(tags: ["docker"]))
        #expect(!filter.matches(tags: []))
    }

    /// The union: one of them is enough.
    @Test func joinAnyKeepsSessionsCarryingAtLeastOneSelectedTag() {
        let filter = SidebarTagFilter(tags: ["docker", "web"], join: .any)
        #expect(filter.matches(tags: ["docker"]))
        #expect(filter.matches(tags: ["web"]))
        #expect(!filter.matches(tags: ["db"]))
    }

    /// With one tag selected the two joins are the same answer — which is
    /// the whole reason the choice is hidden until a second one arrives.
    @Test func withOneSelectedTagTheTwoJoinsAnswerIdentically() {
        let all = SidebarTagFilter(tags: ["docker"], join: .all)
        let any = SidebarTagFilter(tags: ["docker"], join: .any)
        for session in [["docker"], ["docker", "web"], ["web"], []] {
            #expect(all.matches(tags: session) == any.matches(tags: session))
        }
    }

    @Test func theJoinChoiceAppearsOnlyFromTwoSelectedTags() {
        #expect(!SidebarTagFilter.none.showsJoinChoice)
        #expect(!SidebarTagFilter.one("docker").showsJoinChoice)
        #expect(SidebarTagFilter(tags: ["docker", "web"]).showsJoinChoice)
    }

    /// The design's explicit rule: deselecting back below two tags must not
    /// reset the join to a default. The choice was made by the user; a third
    /// tap that brings a second tag back has to find it again.
    @Test func theChosenJoinSurvivesFallingBackBelowTwoSelectedTags() {
        let chosen = SidebarTagFilter(tags: ["docker", "web"], join: .any)
        let single = chosen.toggling("web")
        #expect(!single.showsJoinChoice)
        #expect(single.join == .any)
        #expect(single.toggling("web").join == .any)
    }

    /// Clearing is deselecting everything at once, so it follows the same
    /// rule — including the clear the sidebar's empty state offers.
    @Test func clearingKeepsTheChosenJoin() {
        let cleared = SidebarTagFilter(tags: ["docker", "web"], join: .any).cleared()
        #expect(cleared.isEmpty)
        #expect(cleared.join == .any)
    }

    // MARK: - Falling back

    @Test func aTagNobodyCarriesAnymoreIsDroppedAndTheRestStays() {
        let resolved = SidebarTagFilter(tags: ["gone", "web"], join: .any)
            .resolved(in: [tagged("a", ["web"])])
        #expect(resolved.tags == ["web"])
        #expect(resolved.join == .any)
    }

    @Test func aFilterWhoseTagsAllDisappearedResolvesToNoFilter() {
        #expect(SidebarTagFilter.one("gone").resolved(in: [tagged("a", ["web"])]).isEmpty)
    }

    // MARK: - Threshold

    /// Below the threshold the chips are drawn one by one; from it on, the
    /// row becomes a button that opens the dialog.
    @Test func theBarCollapsesIntoTheDialogFromTheThresholdOn() {
        let below = SidebarTagFilter.dialogTagThreshold - 1
        #expect(SidebarTagFilter.presentation(availableTagCount: below) == .bar)
        #expect(
            SidebarTagFilter.presentation(availableTagCount: SidebarTagFilter.dialogTagThreshold)
                == .dialog)
        #expect(
            SidebarTagFilter.presentation(
                availableTagCount: SidebarTagFilter.dialogTagThreshold + 1) == .dialog)
    }

    /// The number the design names, pinned once — so moving it is a decision
    /// that shows up in a diff here rather than a literal edited in a view.
    @Test func theThresholdIsSix() {
        #expect(SidebarTagFilter.dialogTagThreshold == 6)
    }

    @Test func noTagsAtAllIsStillTheBarCase() {
        #expect(SidebarTagFilter.presentation(availableTagCount: 0) == .bar)
    }
}
