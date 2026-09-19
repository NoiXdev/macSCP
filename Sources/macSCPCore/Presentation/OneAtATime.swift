import Foundation
import Observation

/// A latch for a user action that must not overlap itself.
///
/// `run(_:)` runs its body unless a run is already in flight; an overlapping
/// call returns `nil` without running anything. `isRunning` is observable, so
/// the control that starts the action can grey itself out for as long as the
/// latch is held — the refusal in `run` is the backstop for a start that got
/// past it anyway.
///
/// Main-actor isolated: the latch is read by a view and flipped around work
/// that the main actor drives, so the check and the set in `run` cannot be
/// split by another caller.
@Observable
@MainActor
public final class OneAtATime {
    public private(set) var isRunning = false

    public init() {}

    /// Runs `body` and returns its result, or returns `nil` without running
    /// it when a run is already in flight.
    public func run<T>(_ body: @MainActor () async -> T) async -> T? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        return await body()
    }
}
