import SwiftUI
import macSCPCore

/// The confirmation a user-defined file action passes through before
/// anything runs: what the server's file names became, one command per line.
///
/// The file names in a command come from the server's directory listing, not
/// from the user, so this sheet is the only place the user can check them.
/// Everything it shows is therefore drawn through `FileActionPlanDisplay`,
/// which makes a control character visible instead of passing it to `Text`.
///
/// A small modal in the shape `ExtractDestinationSheet` uses: the same
/// padding and spacing, buttons in a trailing row with Cancel first and the
/// default action last, and `.interactiveDismissDisabled(true)` so that only
/// a button resolves it and `onRun` or `onCancel` is called exactly once.
///
/// When the planner refused, the sheet shows one fixed sentence in place of
/// the list and has no Run button. The sentence names nothing from the
/// selection: a refusal's payload can be the hostile value itself.
///
/// Presented by `BrowserPane`, which owns every sheet its menu entries open.
struct FileActionConfirmSheet: View {
    let request: FileActionRequest
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("fileAction.confirm.title", "Run action")).font(.headline)
            Text(request.action.name)
                .font(.system(.body, design: .default).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            switch request.outcome {
            case .success(let plan):
                Text(L10n.string(
                    "fileAction.confirm.message",
                    "This is what will run. The file names come from the server, so read them before you continue."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                commandList(FileActionPlanDisplay.lines(for: plan))
            case .failure(let refusal):
                Text(FileActionPlanDisplay.refusalSentence(for: refusal))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.string("fileAction.confirm.cancel", "Cancel"), role: .cancel) { onCancel() }
                    .buttonStyle(.polished)
                    .keyboardShortcut(.cancelAction)
                if case .success = request.outcome {
                    Button(L10n.string("fileAction.confirm.run", "Run")) { onRun() }
                        .buttonStyle(.polishedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(true)
    }

    /// One row per command, monospaced, selectable and scrollable. A long
    /// line wraps rather than truncates: a clipped line would show less than
    /// will run.
    private func commandList(_ lines: [[FileActionPlanDisplay.Run]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(FileActionPlanDisplay.attributed(lines[index]))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 240)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

/// What the sheet draws for a plan.
///
/// **A control character is never passed through.** A NUL inside a SwiftUI
/// `Text` may end the string at that point, so the user would be shown a
/// shorter command than the one that runs, and that defeats the one check
/// the sheet exists for. `FileActionPlanner` refuses a C0 control character
/// or DEL in a selection-derived value on the remote path (the line editor
/// would act on it), but a prompted value or the author's own template can
/// still carry one, and a server value can carry other format characters
/// listed below, so such a scalar can reach a line shown here. These markers
/// are defence in depth and not the control: a user recognising `<U+0015>`
/// is not a security property. Each such scalar is drawn as
/// `<U+XXXX>` in its own run, which the sheet colours: a name that merely
/// spells `<U+0000>` out stays plain, so the two cannot be mistaken for each
/// other.
///
/// The same rule covers what a terminal or a text layout would act on rather
/// than draw — line breaks, and the invisible bidirectional and zero-width
/// format characters a spoofed file name uses to reorder what is shown around
/// it — except the joiner and variation selectors an emoji is built from
/// (see `needsMarker`). Asked scalar by scalar, as `FileActionPlanner` asks
/// its questions of server-chosen values.
enum FileActionPlanDisplay {
    struct Run: Equatable {
        let text: String
        /// Whether `text` stands for a scalar that was not drawn.
        let isEscape: Bool
    }

    /// `text` with every scalar that would not be drawn faithfully replaced
    /// by its marker, as consecutive runs.
    static func runs(of text: String) -> [Run] {
        var result: [Run] = []
        var plain = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if needsMarker(scalar) {
                if !plain.isEmpty {
                    result.append(Run(text: String(plain), isEscape: false))
                    plain = String.UnicodeScalarView()
                }
                let hex = String(scalar.value, radix: 16, uppercase: true)
                let padded = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                result.append(Run(text: "<U+\(padded)>", isEscape: true))
            } else {
                plain.append(scalar)
            }
        }
        if !plain.isEmpty { result.append(Run(text: String(plain), isEscape: false)) }
        return result
    }

    /// `text` as a plain string with every marked scalar spelled out as its
    /// `<U+XXXX>` marker, for the surfaces that hand a name to something
    /// other than `attributed(_:)` — an alert's message, a menu title, a
    /// sentence built with `String(format:)`. The same decision as `runs`,
    /// so a name cannot look different on two surfaces, but it carries no
    /// colour: use `attributed` wherever a `Text` can show one.
    static func visible(_ text: String) -> String {
        runs(of: text).map(\.text).joined()
    }

    /// One entry per command the plan will run. A shell line is shown as
    /// planned. An invocation has no shell, so it is shown with each
    /// argument quoted: joined bare, `a b` as one argument and `a` `b` as two
    /// would read the same.
    static func lines(for plan: FileActionPlan) -> [[Run]] {
        switch plan {
        case .shellLines(let lines):
            return lines.map(runs(of:))
        case .invocations(let invocations):
            return invocations.map { invocation in
                runs(of: ([invocation.executable] + invocation.arguments.map(PosixQuoting.singleQuoted))
                    .joined(separator: " "))
            }
        }
    }

    /// The sentence for a refusal. It takes the refusal so that a call site
    /// cannot ask for anything else, and it uses none of it: two cases carry
    /// the offending value, and the sentence would then have to render it.
    static func refusalSentence(for refusal: FileActionPlanner.Refusal) -> String {
        L10n.string(
            "fileAction.confirm.refused", "This action cannot run on this selection.")
    }

    /// The runs as one `AttributedString`, markers in red.
    static func attributed(_ runs: [Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isEscape {
                piece.foregroundColor = Color.red
                piece.backgroundColor = Color.red.opacity(0.15)
            }
            result.append(piece)
        }
        return result
    }

    /// Whether `scalar` is drawn as a marker instead of passed through.
    ///
    /// U+200D ZERO WIDTH JOINER is let through: it composes one emoji out of
    /// several (a family, a profession), so a name with one is ordinary, and a
    /// sheet that decorated ordinary names with markers would teach the user
    /// to ignore markers. The variation selectors U+FE00 to U+FE0F pass for
    /// the same reason without being named here: they are nonspacing marks,
    /// not format characters, so the category test below never reaches them.
    /// Every other format character stays marked, in particular each
    /// bidirectional control (U+200E, U+200F, U+202A to U+202E, U+2066 to
    /// U+2069), which reorders what the user reads, and the zero-width space
    /// and non-joiner (U+200B, U+200C), which hide a difference between two
    /// names instead of composing one glyph.
    private static func needsMarker(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\u{200D}" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
