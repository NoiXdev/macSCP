import AppKit
import SwiftUI
import macSCPCore

/// The snippet editor's command field: an `NSTextView` so the text can be
/// coloured WHILE typing, which a SwiftUI `TextField` cannot do.
///
/// Six hazards this deliberately handles, because each of them is
/// invisible until someone hits it:
///
/// 1. **Caret.** Re-colouring sets attributes; without saving and restoring
///    the selected range, the insertion point jumps to the end on every
///    keystroke.
/// 2. **Undo.** Attribute changes must not enter the undo stack, or ⌘Z
///    undoes colours instead of text.
/// 3. **Binding loop.** text change → binding → `updateNSView` → text
///    change. The guard is comparing the string before assigning it.
/// 4. **Line breaks are content.** Part 2 made a snippet command
///    multi-line: a typed Return inserts, a pasted multi-line string is
///    kept as it stands, and `Snippet` stores both verbatim. What reaches
///    the shell is `SnippetSendPlanner`'s decision, made at trigger time
///    from the remote's bracketed-paste mode — not this view's.
/// 5. **Automatic substitutions.** An `NSTextField`'s field editor disables
///    smart quotes, smart dashes, automatic text replacement, spelling
///    correction, and smart insert/delete by default; a raw `NSTextView`
///    does not. Left at the system default, "smart quotes and dashes"
///    would silently corrupt a typed command (`echo "hi"` grows curly
///    quotes, `--delete` grows an en dash) — disabled explicitly in
///    `makeNSView` below.
/// 6. **Tab.** A raw `NSTextView`'s own `insertTab:`/`insertBacktab:`
///    insert literal tab characters by default; an `NSTextField`'s field
///    editor instead traverses focus. The `Coordinator` below claims both
///    selectors itself so Tab moves to the next field, like every other
///    field in this sheet.
///
/// It also carries the completion list that opens on the opening braces
/// (snippet editor operation, part 2) — feasible here precisely because
/// this is an `NSTextView`: a list on a SwiftUI `TextField` would have
/// been a project of its own. What the list offers is decided by
/// `snippetPlaceholderCompletions`, away from the view; the `Coordinator`
/// below only supplies the text around the caret and shows the result.
struct SnippetCommandEditor: NSViewRepresentable {
    @Binding var text: String
    /// VoiceOver's name for this field. The `TextField(commandLabel, ...)`
    /// this replaced supplied one implicitly, from its own title parameter;
    /// a raw `NSTextView` supplies none on its own, so the caller
    /// (`SnippetsSheet`) hands in the exact same localized string its
    /// `FormRow` label uses — that label is `.accessibilityHidden(true)`
    /// for precisely this reason (see `FormRow`'s own doc comment: the
    /// wrapped control is expected to carry its own accessibility label).
    let accessibilityLabel: String
    /// The declarations the completion list on the opening braces is built
    /// from (snippet editor operation, part 2). Handed in whole rather than
    /// pre-filtered, so the one rule about what belongs in a command as
    /// `{{NAME}}` —
    /// `snippetBelongsInCommandAsPlaceholder` — is applied in the one place
    /// the variable row's insert control applies it too.
    let variables: [SnippetVariable]

    /// How tall this field wants to be for `text`: one line's height per
    /// line, plus the container insets, clamped so a long script cannot push
    /// the sheet off screen. Beyond the clamp the view scrolls vertically —
    /// which depends on `makeNSView`'s `isVerticallyResizable`/
    /// `autoresizingMask` configuration below actually letting the text
    /// view's frame grow past this clamp; the clamp on its own decides
    /// nothing about whether the overflow is reachable.
    ///
    /// The bounds are estimates and belong in the maintainer's visual check
    /// — no test in this project draws an `NSViewRepresentable`.
    /// The text container's inset above the first line and below the last,
    /// and the font every line is laid out in. They live here as constants
    /// because three things have to agree on them: `makeNSView`, which sets
    /// the inset on the view; `intrinsicHeight`, which reserves room for
    /// both; and `firstBaselineOffset`, which the sheet aligns the row's
    /// label to.
    /// The statics below are `nonisolated` because `SnippetCommandEditor`
    /// inherits main-actor isolation from `NSViewRepresentable`, while
    /// `SnippetsSheet` reads the baseline from an `.alignmentGuide` closure,
    /// which SwiftUI declares `@Sendable`. Nothing in this group needs the
    /// main actor: they are constants, a font derived from the system font,
    /// and pure arithmetic over the two.
    nonisolated static let verticalInset: CGFloat = 4
    nonisolated static let lineHeight: CGFloat = 16
    nonisolated static var font: NSFont {
        .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    /// Distance from the view's top edge to the FIRST LINE's baseline.
    ///
    /// SwiftUI cannot read a baseline out of an `NSViewRepresentable`, so a
    /// `.firstTextBaseline` row aligns the label against the wrapper's own
    /// edge instead and the label ends up sitting well above the text it
    /// names. The sheet hands this value to `.alignmentGuide` to put the
    /// label back on the first line — see `SnippetsSheet`'s command row.
    nonisolated static var firstBaselineOffset: CGFloat { verticalInset + font.ascender }

    nonisolated static func intrinsicHeight(for text: String) -> CGFloat {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let clamped = min(max(lines, 1), 8)
        return CGFloat(clamped) * lineHeight + verticalInset * 2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 6, height: Self.verticalInset)
        textView.drawsBackground = false
        textView.setAccessibilityLabel(accessibilityLabel)
        // Hazard 5: an `NSTextField`'s field editor disables all five of
        // these by default; a raw `NSTextView` does not, so without this a
        // system "smart quotes and dashes" setting would silently corrupt a
        // typed command (`echo "hi"` -> curly quotes, `--delete` -> an en
        // dash) the moment it's typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        // Word-wrap stays off (the `TextField` this replaced never wrapped
        // either): `scrollableTextView()` starts out configured to WRAP,
        // which lets a long line wrap out of sight with no horizontal
        // scroller at all. This is Apple's own recipe for a
        // horizontally-scrolling, non-wrapping text view ("Putting an
        // NSTextView Object in an NSScrollView"): the container must not
        // track the view's width and must be effectively unbounded, and the
        // view itself must be horizontally resizable so its FRAME -- not
        // just its container -- can grow past the visible width for the
        // horizontal scroller to have something to scroll.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        // `isVerticallyResizable = true` lets the text view's FRAME -- not
        // just its container -- grow past `intrinsicHeight`'s clamp as text
        // is laid out; without it the frame stays pinned at its initial
        // height forever; an `NSScrollView` only ever scrolls as far as its
        // document view's frame, so a pinned frame leaves the overflow laid
        // out but unreachable no matter what the scroller flags below say
        // (measured with an AppKit probe: at 5/12/30/60 lines the frame
        // stayed at 150pt while the text needed 88/200/488/968). `.width` in
        // the mask, not `.height`, is the counterpart to that: it tracks the
        // clip view's WIDTH, so the horizontal axis stays governed by the
        // `isHorizontallyResizable`/`maxSize` configuration above and does
        // not fight it.
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No horizontal scroller, and still no border: a permanently
        // visible horizontal scroller ate roughly two thirds of the row's
        // height and drew as a dark capsule across the empty field; the
        // clip view still follows the caret past the right edge without
        // one, which is exactly what the `TextField` this replaced did.
        // The rounded chrome comes from the call site, because AppKit's
        // `NSBorderType` has no rounded member and the neighbouring fields
        // in this sheet are all `.roundedBorder`. The vertical scroller, by
        // contrast, is turned ON: paired with `isVerticallyResizable = true`
        // and `autoresizingMask = [.width]` above -- which are what actually
        // let the frame grow past `intrinsicHeight`'s clamp -- a command
        // past that clamp is reachable, not just cropped. The scroller flag
        // alone cannot do that: an `NSScrollView` only scrolls as far as its
        // document view's frame, and without the resizing configuration
        // above that frame never grows.
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        context.coordinator.apply(text, to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Hazard 3: only touch the view when the value actually differs,
        // or every binding round trip re-enters this.
        guard textView.string != text else { return }
        context.coordinator.apply(text, to: textView)
    }

    /// Main-actor isolated for the same reason as `RemoteFileTableView`'s
    /// coordinator: SwiftUI creates it on the main actor and `NSTextView`
    /// delegate callbacks arrive there, so `apply` and `recolour` — which
    /// are ours, not protocol witnesses — may reach into the text view.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SnippetCommandEditor

        init(_ parent: SnippetCommandEditor) { self.parent = parent }

        /// Hazard 6: a raw `NSTextView` inserts a literal tab character for
        /// both selectors by default; claim them here instead so Tab (and
        /// Shift-Tab) traverse focus, matching every other field in the
        /// sheet.
        func textView(
            _ textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recolour(textView)
            // The design's trigger: the opening braces, and nothing else.
            // Once the list is up AppKit keeps it in step with what is
            // typed after them, asking the delegate below again each time.
            if Self.opensPlaceholderCompletion(textView) { textView.complete(nil) }
        }

        /// What the list offers at the caret, for the partial word AppKit
        /// worked out on its own.
        ///
        /// `words` — the spell checker's guesses — is deliberately dropped:
        /// this field holds a shell command, and the only completion it has
        /// any business offering is a declared variable name.
        ///
        /// The decision itself is `snippetPlaceholderCompletions`, which
        /// takes the text on either side rather than a text view, so every
        /// part of the rule can be checked without one.
        func textView(
            _ textView: NSTextView, completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let text = textView.string as NSString
            guard charRange.location != NSNotFound,
                charRange.location >= 0, charRange.length >= 0,
                NSMaxRange(charRange) <= text.length
            else { return [] }
            return snippetPlaceholderCompletions(
                in: parent.variables,
                textBeforePartialWord: text.substring(to: charRange.location),
                partialWord: text.substring(with: charRange),
                textAfterPartialWord: text.substring(from: NSMaxRange(charRange)))
        }

        /// Whether the caret has just come to rest right behind a pair of
        /// opening braces.
        ///
        /// Only with an empty selection: a range selection has no single
        /// "just typed here" position, and opening a list over one would
        /// offer to replace text the user did not point at.
        private static func opensPlaceholderCompletion(_ textView: NSTextView) -> Bool {
            let selected = textView.selectedRange()
            guard selected.length == 0 else { return false }
            let text = textView.string as NSString
            guard selected.location != NSNotFound, selected.location <= text.length
            else { return false }
            return text.substring(to: selected.location).hasSuffix("{{")
        }

        func apply(_ value: String, to textView: NSTextView) {
            textView.string = value
            recolour(textView)
        }

        /// Hazards 1 and 2: the caret is put back where it was, and the
        /// attribute run is kept out of the undo stack.
        private func recolour(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            let text = textView.string
            let full = NSRange(location: 0, length: (text as NSString).length)

            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: DesignTokens.inkNS, range: full)
            for token in SnippetHighlighter.tokens(in: text, language: .shell) {
                storage.addAttribute(
                    .foregroundColor, value: Self.colour(for: token.kind),
                    range: NSRange(token.range, in: text))
            }
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()

            textView.setSelectedRange(selected)
        }

        /// The `NSColor` side of the one kind-to-colour map, which lives in
        /// `snippetTokenColour` (Snippet-Probelauf, Task 4) because the
        /// dry-run sheet paints the same kinds in SwiftUI. Keeping a second
        /// switch here would be two answers to "what colour is a
        /// variable", and the review that gave `.variable` its own hue
        /// would have had to be made twice.
        ///
        /// Four of the seven kinds already went through `NSColor(_:)`
        /// before the map moved (`NSColor(DesignTokens.remoteBlue)` and its
        /// three siblings); the other three named `inkNS`, `inkSecondaryNS`
        /// and `inkTertiaryNS`, and the `Color` the map returns for them is
        /// `Color(nsColor:)` of exactly those, so the bridge is asked for
        /// nothing new.
        private static func colour(for kind: SnippetToken.Kind) -> NSColor {
            NSColor(snippetTokenColour(for: kind))
        }
    }
}
