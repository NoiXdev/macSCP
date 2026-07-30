/// Pure index arithmetic for cycling through a Tab-completion candidate list
/// (M11i). Deliberately knows nothing about `PathBar`'s `@State` or the
/// candidates themselves — just "what's the next/previous index, wrapping
/// modulo the count" — so it can be unit-tested without any AppKit/SwiftUI
/// scaffolding, unlike the rest of the cycling behavior, which lives as
/// `@State` in `PathBar` and has no automated coverage (see that type's
/// `handleTab` doc comments).
public enum CandidateCycle {
    /// The next index after `current`, wrapping to `0` past the last one.
    /// `current == nil` (not cycling yet) starts at `0` — the first Tab in
    /// the candidate list selects the first candidate. `count == 0` (no
    /// candidates to cycle through) is always `nil`.
    public static func next(from current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return (current + 1) % count
    }

    /// The previous index before `current`, wrapping to the last one before
    /// `0`. `current == nil` starts at the LAST candidate — Shift+Tab before
    /// any forward cycling steps backward from "past the end". `count == 0`
    /// is always `nil`.
    public static func previous(from current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        return (current - 1 + count) % count
    }
}
