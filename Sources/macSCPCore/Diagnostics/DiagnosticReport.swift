import Foundation

/// The whole diagnosis, in the order it was measured, plus what it was
/// pointed at and which build measured it.
///
/// Both renderings are English and unlocalized, on purpose. This is what the
/// user pastes into a bug report — the same audience the command-line tool
/// writes for — and a row that arrives translated is a row the person reading
/// the report cannot search for. The PANEL is localized: it renders each
/// step's `titleKey` through the App's catalogs, which is why the renderings
/// below print the step's stable `id` and never resolve a key.
public struct DiagnosticReport: Sendable, Equatable {
    public let endpoint: Endpoint
    public let steps: [DiagnosticStep]
    /// The build that measured this. Passed in by the App
    /// (`CFBundleShortVersionString`); Core never reads the bundle itself —
    /// see `GitHubReleaseFetcher`'s note for the same rule.
    public let appVersion: String

    /// Whether the walk that produced this finished, and how it ended when it
    /// did not.
    ///
    /// A report is pasted into an issue, and a PARTIAL one — copied while the
    /// diagnosis is still running, or after it was cancelled — has rows that
    /// were never measured rather than rows that were measured and found
    /// absent. Those two read identically once the text leaves the panel, so
    /// the renderers say which this is.
    public enum Completion: Sendable, Equatable {
        /// The walk reached its end. Every row it was going to measure is
        /// here.
        case complete
        /// A snapshot of a walk that is still walking, taken so the rows
        /// already on screen can be copied before the slowest step returns.
        case running
        /// The walk was stopped. `afterSteps` is how many rows it had
        /// finished — carried in the case so the marker can name it without
        /// the renderer having to assume that the list it is printing is the
        /// whole of what was measured.
        case cancelled(afterSteps: Int)
    }

    public let completion: Completion

    /// The yes/no question, for a caller that does not care which of the two
    /// partial cases it is looking at.
    public var isComplete: Bool { completion == .complete }

    /// No redaction pass here, unlike `DiagnosticStep.init`, and that is a
    /// decision rather than an omission: the only fields this prints besides
    /// the steps are `endpoint.text` and `appVersion`. An endpoint's host
    /// comes either from `URL.host()` (which never carries userinfo) or from
    /// SSH's own host field, where an `alice@server.lan` a user typed is a
    /// user name and not a credential — and carries no `://` for
    /// `withoutUserinfo` to act on anyway.
    public init(
        endpoint: Endpoint, steps: [DiagnosticStep], appVersion: String,
        completion: Completion = .complete
    ) {
        self.endpoint = endpoint
        self.steps = steps
        self.appVersion = appVersion
        self.completion = completion
    }

    private static let title = "macSCP connection diagnostics"

    /// The one line that marks an unfinished walk, and says which of the two
    /// ways it is unfinished. English, like the rest of this rendering: the
    /// report's audience is whoever reads the issue, not whoever pasted it
    /// (see this type's own doc comment).
    ///
    /// `nil` for a finished walk, which needs no marker at all: the rows are
    /// the whole measurement, and a line saying so would be noise in every
    /// report anyone ever pastes.
    private static func marker(for completion: Completion) -> String? {
        switch completion {
        case .complete:
            return nil
        case .running:
            return "(run in progress)"
        case .cancelled(let afterSteps):
            let rows = afterSteps == 1 ? "1 step" : "\(afterSteps) steps"
            return "(cancelled after \(rows))"
        }
    }

    public func plainText() -> String {
        var lines = [
            Self.title,
            "Endpoint: \(endpoint.text)",
            "App version: \(appVersion)",
        ]
        if let marker = Self.marker(for: completion) { lines.append(marker) }
        lines.append("")
        for step in steps {
            var line = "\(step.id) — \(step.outcome.label) — \(Self.duration(step.duration))"
            if !step.detail.isEmpty { line += " — \(step.detail)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public func markdown() -> String {
        var lines = [
            "# \(Self.title)",
            "",
            "- **Endpoint:** `\(endpoint.text)`",
            "- **App version:** \(appVersion)",
        ]
        if let marker = Self.marker(for: completion) { lines.append("- **\(marker)**") }
        lines.append(contentsOf: [
            "",
            "| Step | Outcome | Duration | Detail |",
            "| --- | --- | --- | --- |",
        ])
        for step in steps {
            lines.append(
                "| `\(step.id)` | \(Self.cell(step.outcome.label)) "
                    + "| \(Self.duration(step.duration)) | \(Self.cell(step.detail)) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func duration(_ duration: Duration) -> String {
        DurationText.milliseconds(duration)
    }

    /// A detail line is free text (an error reason, a server's header), and a
    /// `|` or a newline in it would split the row it sits in.
    ///
    /// Decided one `Unicode.Scalar` at a time, not with
    /// `replacingOccurrences`: that matches on grapheme clusters and on
    /// canonical equivalence, so a bar carrying a combining mark is one
    /// cluster that the search misses while Markdown still reads the bar.
    /// Same reasoning, and the same shape, as `ShellScalar` on the snippet
    /// path — `noCoreFileEscapesAMetacharacterWithReplacingOccurrences` holds
    /// every file in Core to it.
    private static func cell(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "|":
                escaped.append("\\")
                escaped.append(scalar)
            case "\n", "\r":
                escaped.append(" ")
            default:
                escaped.append(scalar)
            }
        }
        return String(escaped)
    }
}
