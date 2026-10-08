import Foundation

/// A backend capability queried via `as?`, like `RemoteShellProvider`,
/// `PresignedURLProvider` and `RemoteChecksumProvider`: run ONE archive
/// command line, with bytes on its standard input, and report its exit
/// status.
///
/// Read the parameter lists, because they are the whole design. An
/// `ArchiveCommandLine` — a value only
/// `Sources/macSCPCore/Archive/ArchiveCommandLine.swift` can build — and
/// bytes. Nothing here takes a `String`, an executable name, or an argument
/// list, so a caller cannot phrase a command of its own. That is the same
/// narrowing `ChecksumCommandChannel` uses, and for the reason
/// `RemoteChecksumProvider.swift` gives there: a general execution entry
/// point would be a new surface every future reviewer had to watch.
///
/// Internal on purpose, exactly as `ChecksumCommandChannel` is: what the
/// App layer reaches is the archive runner above this, and this seam exists
/// so the decisions above it are testable against a double with no
/// connection at all. Being internal is not what keeps it narrow — the
/// parameter types are.
protocol ArchiveCommandChannel: Sendable {
    /// Runs `line`, writing `stdin` to the command's standard input and
    /// signalling end-of-input afterwards, and returns the exit status.
    ///
    /// A non-zero status is thrown as `ArchiveCommandExitFailure` rather
    /// than returned, so a caller that only wants "did this work" does not
    /// have to remember to look at the number. The return value is
    /// therefore `0` whenever it returns at all; it is an `Int` because the
    /// double in the tests is what everything above this seam is written
    /// against, and a channel that reports a status is the honest shape of
    /// the thing.
    ///
    /// Standard output is NOT returned. An archive tool's output is progress
    /// chatter, not an answer; what the caller needs is the exit status, and
    /// the files the run produced are read back through the ordinary
    /// listing.
    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int

    /// The STANDARD OUTPUT of a listing line, one entry per line of output,
    /// bounded.
    ///
    /// **`limit` is a number of BYTES of standard output, not a number of
    /// entries.** It is the whole output's size, measured before anything is
    /// split, so a caller sizing it has to think in the far side's bytes:
    /// 10_000 is not "ten thousand entries", it is about 300 paths of
    /// average length. Passing an entry count would refuse ordinary
    /// archives — the kind of mistake that reads as a bug in the preview
    /// rather than in the number.
    ///
    /// The bound exists because an archive can hold millions of entries and
    /// this output is read into memory; past it the channel THROWS rather
    /// than truncating, because a truncated listing would under-report
    /// collisions, which is the one direction this feature must not be
    /// wrong in. What it throws is a channel-level failure, not an
    /// `ArchiveCommandExitFailure`: the far side's command succeeded, it is
    /// this side that will not keep the answer.
    ///
    /// Nothing calls this yet — the extraction preview does, later in this
    /// plan. It is declared here with `run(_:stdin:)` rather than added
    /// afterwards so that a reviewer of the fakes in the test suites cannot
    /// mistake a deliberate extension for a forgotten one.
    func listing(of line: ArchiveCommandLine, limit: Int) async throws -> [String]
}

/// Thrown by a conforming channel when the command's own exit status is
/// known and non-zero — as opposed to a channel-level failure (a dropped
/// connection, a bound that elapsed).
///
/// Mirrors `ChecksumCommandExitFailure`, including why 127 is worth its own
/// question: POSIX shells report "could not find the executable this line
/// names" as exit 127 regardless of which shell is running it, and that is
/// the one archive failure the user can act on by picking another format.
struct ArchiveCommandExitFailure: Error, Equatable, Sendable {
    let exitCode: Int

    /// The far side has no such tool.
    var isToolMissing: Bool { exitCode == 127 }
}
