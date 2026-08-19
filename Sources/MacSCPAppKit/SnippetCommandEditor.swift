import AppKit
import SwiftUI
import macSCPCore

/// The snippet editor's command field: an `NSTextView` so the text can be
/// coloured WHILE typing, which a SwiftUI `TextField` cannot do.
///
/// Four hazards this deliberately handles, because each of them is
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
///    turns them into spaces before the binding ever sees them.
struct SnippetCommandEditor: NSViewRepresentable {
    @Binding var text: String

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
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .bezelBorder
        context.coordinator.apply(text, to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Hazard 3: only touch the view when the value actually differs,
        // or every binding round trip re-enters this.
        guard textView.string != text else { return }
        context.coordinator.apply(text, to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: SnippetCommandEditor

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
            case .variable: return NSColor(DesignTokens.remoteBlue)
            case .comment: return DesignTokens.inkTertiaryNS
            case .operator: return DesignTokens.inkSecondaryNS
            case .plain: return DesignTokens.inkNS
            }
        }
    }
}
