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
/// 4. **Newlines.** A command may now span lines (snippet editor, part 2),
///    so a pasted multi-line string is accepted as-is. A typed Return is
///    still handled separately: the `Coordinator` claims `insertNewline(_:)`
///    in `doCommandBy:` and returns `true` without inserting anything, so
///    *if* this text view is the one to receive the keystroke, it does
///    nothing. Whether the text view is the one to receive it is a
///    different, unverified question: AppKit may instead route the
///    unmodified Return to the sheet's `.keyboardShortcut(.defaultAction)`
///    Save button before this view ever sees it. Reconciling typed Return
///    with a field that now accepts multi-line content is a later task in
///    this milestone.
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 4)
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
        // Single-line is enforced (the `TextField` this replaced never
        // wrapped either): `scrollableTextView()` starts out configured to
        // WRAP, which in a 24pt-tall box lets a long command wrap out of
        // sight with no scroller at all. This is Apple's own recipe for a
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
        // `.width` in the mask pins the text view's width to the clip
        // view's, so the frame can never grow past the visible width and
        // there is nothing for the scroll view to scroll -- a long command
        // just stopped at the right edge, unreachable. Only the height
        // tracks the clip view; the width is left to `maxSize`, which is
        // the ceiling the frame grows toward as text is laid out. The
        // vertical axis is fixed instead of self-sizing because this is a
        // one-line field whose height comes from the row, not the text.
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No scroller and no border: this is a single-line form field
        // pretending to be the `TextField` it replaced. A permanently
        // visible horizontal scroller ate roughly two thirds of the row's
        // height and drew as a dark capsule across the empty field; the
        // clip view still follows the caret past the right edge without
        // one, which is exactly what the `TextField` did. The rounded
        // chrome comes from the call site, because AppKit's `NSBorderType`
        // has no rounded member and the neighbouring fields in this sheet
        // are all `.roundedBorder`.
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
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
            case #selector(NSResponder.insertNewline(_:)):
                // Hazard 4: this field is single-line, so a typed Return
                // has nothing to insert. Claiming the selector (and
                // returning `true` without calling through) swallows it
                // deterministically here, if this view is the one that
                // receives the keystroke at all -- see the doc comment
                // above this type.
                return true
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recolour(textView)
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

        /// The one place kinds become colours. Core supplies neither.
        private static func colour(for kind: SnippetToken.Kind) -> NSColor {
            switch kind {
            case .command: return NSColor(DesignTokens.remoteBlue)
            case .option: return NSColor(DesignTokens.agentGreen)
            case .string: return NSColor(DesignTokens.localAmber)
            // Its own hue (whole-branch review, finding 7): `.command` and
            // `.variable` used to share `remoteBlue`, the only collision
            // among the declared kinds. `s3Violet` is an existing design
            // token (M15's S3 login-set badge), not a new hex value invented
            // for this file.
            case .variable: return NSColor(DesignTokens.s3Violet)
            case .comment: return DesignTokens.inkTertiaryNS
            case .operator: return DesignTokens.inkSecondaryNS
            case .plain: return DesignTokens.inkNS
            }
        }
    }
}
