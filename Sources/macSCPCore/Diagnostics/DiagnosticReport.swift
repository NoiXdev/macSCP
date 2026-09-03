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

    /// No redaction pass here, unlike `DiagnosticStep.init`, and that is a
    /// decision rather than an omission: the only fields this prints besides
    /// the steps are `endpoint.text` and `appVersion`. An endpoint's host
    /// comes either from `URL.host()` (which never carries userinfo) or from
    /// SSH's own host field, where an `alice@server.lan` a user typed is a
    /// user name and not a credential — and carries no `://` for
    /// `withoutUserinfo` to act on anyway.
    public init(endpoint: Endpoint, steps: [DiagnosticStep], appVersion: String) {
        self.endpoint = endpoint
        self.steps = steps
        self.appVersion = appVersion
    }

    private static let title = "macSCP connection diagnostics"

    public func plainText() -> String {
        var lines = [
            Self.title,
            "Endpoint: \(endpoint.text)",
            "App version: \(appVersion)",
            "",
        ]
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
            "",
            "| Step | Outcome | Duration | Detail |",
            "| --- | --- | --- | --- |",
        ]
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
