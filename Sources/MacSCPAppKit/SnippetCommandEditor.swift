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
/// 4. **Newlines.** `Snippet.init?` refuses them; `SnippetCommandInput`
///    turns them into spaces before the binding ever sees them. Return
///    itself never reaches the sheet's Save button either way: a plain,
///    unmodified Return is not a "key equivalent" in AppKit's sense (that
///    path is reserved for characters typed with a modifier, or Shift-only,
///    and is checked by `NSApplication` based on the event's modifier
///    flags — see Apple's Event Handling Guide). With no modifier at all,
///    the event goes straight to whichever view is first responder, and
///    while this text view holds that role, its own `keyDown:` routes
///    Return through `insertNewline:` into the same text-editing pipeline
///    `shouldChangeTextIn:replacementString:` below intercepts. The sheet's
///    `.keyboardShortcut(.defaultAction)` Save button is never consulted
///    while this field has focus.
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
        textView.textContainerInset = NSSize(width: 4, height: 4)
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
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .bezelBorder
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

        /// Hazard 4: Return, and a pasted multi-line command, become spaces
        /// before anything else sees them.
        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacement = replacementString else { return true }
            let cleaned = SnippetCommandInput.sanitized(replacement)
            guard cleaned != replacement else { return true }
            textView.insertText(cleaned, replacementRange: range)
            return false
        }

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
            // `.variable` used to share `remoteBlue`, which rendered six
            // declared kinds as only four distinct colours. `s3Violet` is an
            // existing design token (M15's S3 login-set badge), not a new
            // hex value invented for this file.
            case .variable: return NSColor(DesignTokens.s3Violet)
            case .comment: return DesignTokens.inkTertiaryNS
            case .operator: return DesignTokens.inkSecondaryNS
            case .plain: return DesignTokens.inkNS
            }
        }
    }
}
