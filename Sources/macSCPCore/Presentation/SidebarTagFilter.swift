import Foundation

/// What the session sidebar is filtering by: a SET of tags plus the join
/// that says what several of them mean together.
///
/// One model, two presentations. The chip row is a compact drawing of this
/// value and the filter dialog is a roomier one; neither is a second state.
/// The sidebar used to hold `activeTag: String?` — one tag — which is the
/// shape that makes a dialog offering several tags into a translation
/// problem: crossing the threshold in either direction would have to map
/// "the one tag from the row" onto "the several from the dialog" and back,
/// and every such mapping is a place a selection is silently dropped. There
/// is nothing to map here. The row selects into the same set the dialog
/// does, and the threshold decides only who draws it.
///
/// Deliberately NOT persisted anywhere: the filter is a view, not a setting
/// (`SessionSidebar` holds it as `@State`), so it starts empty on every
/// relaunch and can never name a tag the store lost while the app was
/// closed.
public struct SidebarTagFilter: Equatable, Sendable {
    /// What several selected tags mean together.
    ///
    /// With fewer than two selected they mean the same thing, which is why
    /// `showsJoinChoice` exists — see there for why the choice is hidden
    /// rather than shown inert.
    public enum Join: Equatable, Sendable, CaseIterable {
        /// A session must carry EVERY selected tag (intersection).
        case all
        /// A session must carry AT LEAST ONE selected tag (union).
        case any
    }

    /// The selected tags. Unordered on purpose: what order the chips stand
    /// in is `SidebarVisibility.availableTags`' answer, so a set here cannot
    /// become a second, contradicting order.
    public let tags: Set<String>
    /// Survives everything except the user changing it — deselecting down to
    /// one tag or to none leaves it exactly as chosen, so re-selecting a
    /// second tag finds the join the user last picked rather than a default
    /// that quietly replaced it.
    public let join: Join

    public init(tags: Set<String> = [], join: Join = .all) {
        self.tags = tags
        self.join = join
    }

    /// No filter — every session passes. `join` is `.all` here only because
    /// a value is needed; with nothing selected the two joins are the same
    /// answer.
    public static let none = SidebarTagFilter()

    /// One selected tag, the shape the chip row produces from a single tap.
    public static func one(_ tag: String) -> SidebarTagFilter {
        SidebarTagFilter(tags: [tag])
    }

    /// Nothing is being narrowed — the sidebar reads this rather than
    /// comparing against `SidebarTagFilter.none`, which would also have to
    /// agree about `join` and would therefore call a filter with an unusual
    /// join "active" while it selects nothing.
    public var isEmpty: Bool { tags.isEmpty }

    public func contains(_ tag: String) -> Bool { tags.contains(tag) }

    /// Selects `tag` if it is not selected, deselects it if it is — the one
    /// thing a chip tap and a dialog checkbox both do. `join` is carried
    /// through untouched.
    public func toggling(_ tag: String) -> SidebarTagFilter {
        var next = tags
        if next.contains(tag) {
            next.remove(tag)
        } else {
            next.insert(tag)
        }
        return SidebarTagFilter(tags: next, join: join)
    }

    /// Back to "no filter", keeping the chosen join: clearing is deselecting
    /// everything at once, and deselecting never resets the join.
    public func cleared() -> SidebarTagFilter {
        SidebarTagFilter(tags: [], join: join)
    }

    public func joined(_ join: Join) -> SidebarTagFilter {
        SidebarTagFilter(tags: tags, join: join)
    }

    /// Whether the join is a question at all — that is, whether at least
    /// `joinChoiceMinimumTags` tags are selected.
    ///
    /// Below that, "all" and "any" pick out exactly the same sessions, so a
    /// visible switch would stand there, let itself be flipped, and change
    /// nothing on screen. This project shows only what is possible; a
    /// control whose two positions are indistinguishable is the case where
    /// that rule pays best.
    public var showsJoinChoice: Bool { tags.count >= Self.joinChoiceMinimumTags }

    /// The selection size from which the join starts to mean something. Two,
    /// because one tag joined with nothing is just that tag.
    public static let joinChoiceMinimumTags = 2

    /// Whether a session carrying `sessionTags` passes.
    ///
    /// Comparison is EXACT, against the case `TagList.normalized`
    /// deliberately preserves instead of folding — so a differently-cased
    /// spelling is a non-match. Damping near-duplicates is the input
    /// control's job (a case-insensitive suggestion list), which is what
    /// lets this comparison stay exact.
    public func matches(tags sessionTags: [String]) -> Bool {
        guard !tags.isEmpty else { return true }
        let carried = Set(sessionTags)
        switch join {
        case .all: return tags.isSubset(of: carried)
        case .any: return !tags.isDisjoint(with: carried)
        }
    }

    /// The same filter with every tag no session carries any more dropped —
    /// so a sidebar reacting to a session being deleted or retagged falls
    /// back toward "no filter" instead of holding a selection nothing can
    /// ever match again. The join is kept: losing a tag is not a reason to
    /// forget how the remaining ones are joined.
    public func resolved(in sessions: [StoredSession]) -> SidebarTagFilter {
        let carried = Set(sessions.flatMap(\.tags))
        return SidebarTagFilter(tags: tags.intersection(carried), join: join)
    }

    /// How the sidebar offers the tags it has.
    public enum Presentation: Equatable, Sendable {
        /// Every tag as its own chip, selected and deselected in place.
        case bar
        /// One button carrying the number of selected tags, opening the
        /// filter dialog — what the row turns into once the chips would take
        /// more room than the sidebar has.
        case dialog
    }

    /// Which of the two drawings applies for `availableTagCount` tags —
    /// asked here rather than in the view, so the threshold is a fact with a
    /// test and not a literal inside a SwiftUI body.
    public static func presentation(availableTagCount: Int) -> Presentation {
        availableTagCount >= dialogTagThreshold ? .dialog : .bar
    }

    /// From how many available tags the chip row collapses into the dialog.
    ///
    /// Whether six is the right place for it is the one thing no test here
    /// can decide — it is the number in the word "handful" and will show
    /// itself in use. That is exactly why it is a named constant in one
    /// place rather than a literal at the point of drawing.
    public static let dialogTagThreshold = 6
}
