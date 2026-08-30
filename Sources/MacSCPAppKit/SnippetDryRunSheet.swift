import SwiftUI
import macSCPCore

/// What a snippet would send, shown before it sends it.
///
/// Renders a `SnippetDryRun` and composes nothing: the resolved command,
/// the send form, the reason for a refusal and the colouring all come off
/// the value. That is what lets the two entrances — the way out of a
/// refusal at trigger time and the editor's "Test" button — show the same
/// thing rather than two similar things.
///
/// ## The two entrances, told apart by one closure
///
/// `onSendAnyway` is `nil` for the editor's rehearsal, and that absence is
/// the whole difference: with no way to send, the button is not drawn at
/// all rather than drawn and disabled. A disabled control asks the reader
/// to work out why; an absent one asks nothing. The rehearsal note takes
/// its place, because "nothing is sent and nothing is remembered" is the
/// thing a person needs to know about a run that looks exactly like the
/// real one.
///
/// ## The value on the screen
///
/// `resolvedCommand` carries whatever was typed into a placeholder, and
/// showing it is the point — it is the reader's own screen. It goes no
/// further: `SnippetAuditDetail` reads the template, `ExportedSnippet`
/// copies the template, and neither sentence beside the command carries a
/// value (`SnippetDryRunPresentationTests
/// .aSubstitutedValueReachesNoSentenceTheSheetShows`).
///
/// Untested as a view, like `SnippetVariablePromptSheet` and
/// `SnippetActionSheet` before it: this project has no SwiftUI rendering
/// harness. What the view is HANDED is tested — see
/// `SnippetDryRunPresentationTests` — and that both entrances hand it the
/// same kind of value is `SnippetDryRunEntranceGuardTests`.
struct SnippetDryRunSheet: View {
    let snippetName: String
    let dryRun: SnippetDryRun
    /// `nil` when there is nothing to send from here — see this type's own
    /// doc comment.
    let onSendAnyway: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                format: L10n.string("snippets.dryRun.title %@", "Dry run of \u{201C}%@\u{201D}"),
                snippetName))
                .font(.headline)

            if let refusal = snippetDryRunRefusalText(for: dryRun.sendForm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(refusal.title).font(.callout.bold())
                    Text(refusal.reason).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("snippets.dryRun.command", "Would go to the shell"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    Text(colouredCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.card))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.hairline, lineWidth: 1))
            }

            Text(snippetSendFormText(for: dryRun.sendForm))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if onSendAnyway == nil {
                Text(L10n.string(
                    "snippets.dryRun.rehearsalNote",
                    "Nothing is sent, and nothing is remembered: what you enter for a test does not pre-fill the next real run."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close"), role: .cancel) { onClose() }
                    .buttonStyle(.polished)
                    .keyboardShortcut(.cancelAction)
                if let onSendAnyway {
                    Button(L10n.string("snippets.dryRun.sendAnyway", "Send anyway")) {
                        onSendAnyway()
                    }
                    .buttonStyle(.polishedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// The resolved command, painted from the dry run's own tokens.
    ///
    /// A base colour first, then one run per token: `SnippetHighlighter`
    /// does not tokenise whitespace and says so, so full coverage is the
    /// caller's job. The ranges index into `resolvedCommand`, and the
    /// `AttributedString` is built from that same string, which is what
    /// makes the index conversion below total in practice — a range that
    /// does not convert is skipped rather than trapping.
    private var colouredCommand: AttributedString {
        var text = AttributedString(dryRun.resolvedCommand)
        text.foregroundColor = DesignTokens.ink
        for token in dryRun.tokens {
            guard
                let lower = AttributedString.Index(token.range.lowerBound, within: text),
                let upper = AttributedString.Index(token.range.upperBound, within: text)
            else { continue }
            text[lower..<upper].foregroundColor = snippetTokenColour(for: token.kind)
        }
        return text
    }
}
