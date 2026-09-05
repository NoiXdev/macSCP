import AppKit

/// The one decision point for whether a window floats above others
/// (Detachable Tabs plan, Task 4, "Keep on Top").
///
/// A pure, stateless mapping: `keepOnTop` is the only input, `.floating` or
/// `.normal` the only outputs. `ContentView` applies the result to the
/// `WindowAccessor`-resolved `NSWindow`, both when that window is first
/// resolved and whenever its own `keepOnTop` state changes — and nowhere
/// else in this target assigns `NSWindow.level` (guarded by
/// `WindowLevelPlanTests`: every `.level = ` assignment under
/// `Sources/MacSCPAppKit` names `WindowLevelPlan.level(` on the same line).
///
/// Per window, not persisted: each window's sticky state lives only in that
/// window's own `@State`, the same way `TabCommands` itself is per window
/// rather than app-wide (see that type's doc comment). Restoring it across
/// launches is Task 5's concern, not this one's.
enum WindowLevelPlan {
    static func level(keepOnTop: Bool) -> NSWindow.Level {
        keepOnTop ? .floating : .normal
    }
}
