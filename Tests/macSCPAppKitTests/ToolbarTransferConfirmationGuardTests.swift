import Foundation
import MacSCPTestSupport
import Testing

/// Guards the wiring of the toolbar's transfer question (maintainer decision
/// of 2026-09-16): the Upload and Download buttons ask before transferring
/// more than one item or a folder, and a single file goes without a question.
///
/// Scanned rather than run, because nothing in this project renders SwiftUI.
/// Every read goes through `SwiftSource.blankingCommentsAndStrings` first, so
/// a comment naming `transferSelection(` is not read as a call to it; key
/// literals are read from `SwiftSource.blankingComments`, at the same offsets.
///
/// FOUR claims, counted 2026-09-17 against the `MARK` sections below. Each
/// negative check has a positive check beside it over the same span:
///
/// 1. Both buttons call `requestToolbarTransfer(` and never
///    `transferSelection(` themselves.
/// 2. `requestToolbarTransfer(` asks `ToolbarTransferPlan.plan(`, reaches
///    `transferSelection(` only in its `.transferNow` case, and in its `.ask`
///    case stores a `ToolbarTransferRequest(` built from the selection it
///    was handed — captured at press.
/// 3. `confirmToolbarTransfer(` transfers the request's own selection, side,
///    tab and session, and reads no pane's `selectedItems`.
/// 4. The window presents the question as a `.confirmationDialog(` bound to
///    `toolbarTransferRequest` through `presenting:`, with exactly two
///    buttons: a confirm button whose action alone reaches
///    `confirmToolbarTransfer(`, and a cancel-role button that does nothing
///    but clear the request; a setter that runs neither; and text read from
///    the plan's catalog helpers or `L10n.string(` only.
@Suite("Toolbar transfer confirmation guard")
struct ToolbarTransferConfirmationGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let transfersFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Transfers.swift")
    private static let sheetsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Sheets.swift")

    private enum ScanError: Error {
        case anchorNotFound, unbalanced, dialogNotFound
    }

    // MARK: - 1-3. The buttons, the plan branch, the confirm action

    @Test func theToolbarButtonsReachTheTransferOnlyThroughThePlan() throws {
        let source = try String(contentsOf: Self.transfersFile, encoding: .utf8)
        let violations = try Self.transfersViolations(source)
        #expect(violations.isEmpty, "the toolbar transfer wiring is broken: \(violations)")
    }

    // MARK: - 4. The question

    @Test func theQuestionIsAConfirmationDialogBoundToTheRequest() throws {
        let source = try String(contentsOf: Self.sheetsFile, encoding: .utf8)
        let violations = try Self.dialogViolations(source)
        #expect(violations.isEmpty, "the toolbar transfer question is wired wrong: \(violations)")
    }

    // MARK: - Scanner self-tests

    private static func transfersFixture(
        upload: String = "requestToolbarTransfer(selected, from: .local, in: tab, session: session)",
        download: String = "requestToolbarTransfer(selected, from: .remote, in: tab, session: session)",
        transferNow: String = "transferSelection(selection, from: side, in: tab, session: session)",
        ask: String = "toolbarTransferRequest = ToolbarTransferRequest(tab: tab, session: session, side: side, selection: selection, itemCount: count, includesFolders: folders, destinationPath: path)",
        confirm: String = "transferSelection(request.selection, from: request.side, in: request.tab, session: request.session)",
        extra: String = ""
    ) -> String {
        """
        extension ContentView {
            func uploadButton(in tab: SessionTab, session: BrowserSession) -> some View {
                let selected = session.local.selectedItems
                Button { \(upload) } label: { Label("Upload", systemImage: "arrow.up") }
            }
            func downloadButton(in tab: SessionTab, session: BrowserSession) -> some View {
                let selected = session.remote.selectedItems
                Button { \(download) } label: { Label("Download", systemImage: "arrow.down") }
            }
            func requestToolbarTransfer(_ selection: [RemoteFileItem], from side: BrowserPaneSide, in tab: SessionTab, session: BrowserSession) {
                switch ToolbarTransferPlan.plan(for: selection) {
                case .transferNow:
                    \(transferNow)
                case .ask(let count, let folders):
                    \(ask)
                }
            }
            func confirmToolbarTransfer(_ request: ToolbarTransferRequest) {
                guard request.tab.session?.id == request.session.id else { return }
                \(confirm)
            }
            func transferSelection(_ selection: [RemoteFileItem], from side: BrowserPaneSide, in tab: SessionTab, session: BrowserSession) {
                \(extra)
            }
        }
        """
    }

    @Test func theTransfersScannerAcceptsTheIntendedShape() throws {
        let violations = try Self.transfersViolations(Self.transfersFixture())
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("a transfer that skips the question is reported", arguments: [
        ["upload": "transferSelection(selected, from: .local, in: tab, session: session)"],
        ["download": "transferSelection(selected, from: .remote, in: tab, session: session)"],
        ["ask": "transferSelection(selection, from: side, in: tab, session: session)"],
        ["confirm": "transferSelection(tab.session!.remote.selectedItems, from: request.side, in: request.tab, session: request.session)"],
        ["extra": "func other() { transferSelection(a, from: .local, in: t, session: s) }"],
    ])
    func theTransfersScannerSeesABypass(_ planted: [String: String]) throws {
        let fixture = Self.transfersFixture(
            upload: planted["upload"] ?? "requestToolbarTransfer(selected, from: .local, in: tab, session: session)",
            download: planted["download"] ?? "requestToolbarTransfer(selected, from: .remote, in: tab, session: session)",
            ask: planted["ask"] ?? "toolbarTransferRequest = ToolbarTransferRequest(tab: tab, session: session, side: side, selection: selection, itemCount: count, includesFolders: folders, destinationPath: path)",
            confirm: planted["confirm"] ?? "transferSelection(request.selection, from: request.side, in: request.tab, session: request.session)",
            extra: planted["extra"] ?? "")
        #expect(try Self.transfersViolations(fixture).isEmpty == false, "planted \(planted) passed")
    }

    private static func dialogFixture(
        confirmAction: String = "confirmToolbarTransfer(request)",
        cancelAction: String = "",
        setter: String = "if !isPresented { toolbarTransferRequest = nil }",
        extraButton: String = ""
    ) -> String {
        """
        func sheets() -> some View {
            content
            .confirmationDialog(
                L10n.string("tabs.close.title", "Close tab?"),
                isPresented: Binding(get: { closeRequest != nil }, set: { _ in }),
                titleVisibility: .visible
            ) {
                Button(L10n.string("tabs.close.confirm", "Close")) { confirmToolbarTransfer(x) }
            } message: {
                Text(closeWarningText)
            }
            .confirmationDialog(
                toolbarTransferRequest.map { ToolbarTransferPlan.title(side: $0.side) } ?? "",
                isPresented: Binding(
                    get: { toolbarTransferRequest != nil },
                    set: { isPresented in \(setter) }),
                titleVisibility: .visible,
                presenting: toolbarTransferRequest
            ) { request in
                Button(ToolbarTransferPlan.confirmLabel(side: request.side)) {
                    \(confirmAction)
                }
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                    \(cancelAction)
                }
                \(extraButton)
            } message: { request in
                Text(ToolbarTransferPlan.message(
                    side: request.side, itemCount: request.itemCount,
                    includesFolders: request.includesFolders, destinationPath: request.destinationPath))
            }
        }
        """
    }

    @Test func theDialogScannerAcceptsTheIntendedShape() throws {
        let violations = try Self.dialogViolations(Self.dialogFixture())
        #expect(violations.isEmpty, "\(violations)")
        let cleared = try Self.dialogViolations(Self.dialogFixture(cancelAction: "toolbarTransferRequest = nil"))
        #expect(cleared.isEmpty, "\(cleared)")
    }

    @Test("a wrongly wired question is reported", arguments: [
        ["cancel": "confirmToolbarTransfer(request)"],
        ["cancel": "transferSelection(request.selection, from: request.side, in: request.tab, session: request.session)"],
        ["confirm": "toolbarTransferRequest = nil"],
        ["confirm": "transferSelection(request.selection, from: request.side, in: request.tab, session: request.session)"],
        ["setter": "if !isPresented { confirmToolbarTransfer(toolbarTransferRequest!) }"],
        ["extra": "Button(L10n.string(\"browser.upload\", \"Upload\")) { confirmToolbarTransfer(request) }"],
        ["extra": "Button(\"Transfer\") { }"],
    ])
    func theDialogScannerSeesAMiswiring(_ planted: [String: String]) throws {
        let fixture = Self.dialogFixture(
            confirmAction: planted["confirm"] ?? "confirmToolbarTransfer(request)",
            cancelAction: planted["cancel"] ?? "",
            setter: planted["setter"] ?? "if !isPresented { toolbarTransferRequest = nil }",
            extraButton: planted["extra"] ?? "")
        #expect(try Self.dialogViolations(fixture).isEmpty == false, "planted \(planted) passed")
    }

    @Test func theDialogScannerFailsClosedWhenNoDialogIsBound() {
        #expect(throws: ScanError.self) {
            try Self.dialogViolations(Self.dialogFixture()
                .replacingOccurrences(of: "toolbarTransferRequest", with: "otherRequest"))
        }
    }

    // MARK: - Checks

    /// Claims 1-3 over `ContentView+Transfers.swift` (or a fixture of it).
    /// Empty means wired right; throws when an anchor is missing, so a moved
    /// function is a loud failure rather than an empty span.
    private static func transfersViolations(_ source: String) throws -> [String] {
        let strict = try SwiftSource.blankingCommentsAndStrings(source)
        var violations: [String] = []

        for (button, side) in [("uploadButton", ".local"), ("downloadButton", ".remote")] {
            let body = try Self.body(after: "func \(button)(", in: strict)
            if !Self.squeezed(body).contains("requestToolbarTransfer(selected,from:\(side),") {
                violations.append("\(button) does not call requestToolbarTransfer( with its own selection and side \(side)")
            }
            if body.contains("transferSelection(") {
                violations.append("\(button) calls transferSelection( directly")
            }
        }

        let request = try Self.body(after: "func requestToolbarTransfer(", in: strict)
        if !request.contains("ToolbarTransferPlan.plan(") {
            violations.append("requestToolbarTransfer( does not ask ToolbarTransferPlan.plan(")
        }
        if let now = request.range(of: "case .transferNow"), let ask = request.range(of: "case .ask"),
           now.upperBound <= ask.lowerBound {
            let nowBranch = request[now.upperBound..<ask.lowerBound]
            let askBranch = request[ask.upperBound...]
            if !nowBranch.contains("transferSelection(") {
                violations.append("the .transferNow case does not call transferSelection(")
            }
            if askBranch.contains("transferSelection(") {
                violations.append("the .ask case calls transferSelection(")
            }
            let squeezedAsk = Self.squeezed(String(askBranch))
            if !squeezedAsk.contains("toolbarTransferRequest=ToolbarTransferRequest(")
                || !squeezedAsk.contains("selection:selection") {
                violations.append("the .ask case does not store a ToolbarTransferRequest( carrying the pressed selection")
            }
        } else {
            violations.append("requestToolbarTransfer( has no .transferNow case followed by a .ask case")
        }
        if Self.occurrences(of: "transferSelection(", in: request) != 1 {
            violations.append("transferSelection( occurs \(Self.occurrences(of: "transferSelection(", in: request)) times in requestToolbarTransfer(, not once")
        }

        let confirm = try Self.body(after: "func confirmToolbarTransfer(", in: strict)
        if !Self.squeezed(confirm).contains(
            "transferSelection(request.selection,from:request.side,in:request.tab,session:request.session)") {
            violations.append("confirmToolbarTransfer( does not transfer the request's own selection, side, tab and session")
        }
        if confirm.contains("selectedItems") {
            violations.append("confirmToolbarTransfer( re-reads a pane's selectedItems at confirm")
        }

        // The declaration, the .transferNow case and the confirm action: no
        // fourth route to the transfer in this file.
        let total = Self.occurrences(of: "transferSelection(", in: strict)
        if total != 3 {
            violations.append("transferSelection( occurs \(total) times in the file, not 3 (declaration, .transferNow, confirm)")
        }
        return violations
    }

    /// Claim 4 over `ContentView+Sheets.swift` (or a fixture of it).
    private static func dialogViolations(_ source: String) throws -> [String] {
        let strict = Array(try SwiftSource.blankingCommentsAndStrings(source))
        let literal = Array(try SwiftSource.blankingComments(source))
        guard strict.count == literal.count else { throw ScanError.dialogNotFound }
        let opener = Array(".confirmationDialog(")
        var start = 0
        var violations: [String] = []
        while let found = Self.firstOffset(of: opener, in: strict, from: start) {
            start = found + opener.count
            let parenOpen = found + opener.count - 1
            guard let parenClose = Self.closingOffset(from: parenOpen, in: strict, open: "(", close: ")")
            else { throw ScanError.unbalanced }
            let arguments = String(strict[parenOpen...parenClose])
            guard arguments.contains("toolbarTransferRequest") else { continue }
            guard let buttonsOpen = Self.firstOffset(of: ["{"], in: strict, from: parenClose),
                  let buttonsClose = Self.closingOffset(from: buttonsOpen, in: strict, open: "{", close: "}"),
                  let label = Self.firstOffset(of: Array("message:"), in: strict, from: buttonsClose),
                  let messageOpen = Self.firstOffset(of: ["{"], in: strict, from: label),
                  let messageClose = Self.closingOffset(from: messageOpen, in: strict, open: "{", close: "}"),
                  let setLabel = Self.firstOffset(of: Array("set:"), in: strict, from: parenOpen),
                  setLabel < parenClose,
                  let setterOpen = Self.firstOffset(of: ["{"], in: strict, from: setLabel),
                  let setterClose = Self.closingOffset(from: setterOpen, in: strict, open: "{", close: "}"),
                  setterClose < parenClose
            else { throw ScanError.dialogNotFound }

            let squeezedArguments = Self.squeezed(arguments)
            if !squeezedArguments.contains("presenting:toolbarTransferRequest") {
                violations.append("the request does not reach the buttons through presenting:")
            }
            if !squeezedArguments.hasPrefix("(toolbarTransferRequest.map{ToolbarTransferPlan.title(") {
                violations.append("the title is not ToolbarTransferPlan.title(")
            }
            let setter = String(strict[setterOpen...setterClose])
            if !Self.squeezed(setter).contains("toolbarTransferRequest=nil") {
                violations.append("the setter does not clear toolbarTransferRequest")
            }
            if setter.contains("confirmToolbarTransfer(") || setter.contains("transferSelection(") {
                violations.append("the setter runs a transfer")
            }

            let buttons = String(strict[buttonsOpen...buttonsClose])
            let transfers = Self.occurrences(of: "confirmToolbarTransfer(", in: buttons)
            if transfers != 1 {
                violations.append("confirmToolbarTransfer( occurs \(transfers) times in the buttons closure, not once")
            }
            if buttons.contains("transferSelection(") {
                violations.append("a button calls transferSelection( directly")
            }

            var spans: [(arguments: String, literalArguments: String, action: String)] = []
            var from = buttonsOpen
            let token = Array("Button(")
            while let hit = Self.firstOffset(of: token, in: strict, from: from), hit < buttonsClose {
                let argsOpen = hit + token.count - 1
                guard let argsClose = Self.closingOffset(from: argsOpen, in: strict, open: "(", close: ")"),
                      let actionOpen = Self.firstOffset(of: ["{"], in: strict, from: argsClose),
                      strict[(argsClose + 1)..<actionOpen].allSatisfy(\.isWhitespace),
                      let actionClose = Self.closingOffset(from: actionOpen, in: strict, open: "{", close: "}")
                else { throw ScanError.dialogNotFound }
                spans.append((
                    String(strict[argsOpen...argsClose]), String(literal[argsOpen...argsClose]),
                    String(strict[actionOpen...actionClose])))
                from = actionClose
            }
            if spans.count != 2 { violations.append("\(spans.count) buttons, not 2") }
            let confirms = spans.filter { Self.squeezed($0.arguments).hasPrefix("(ToolbarTransferPlan.confirmLabel(") }
            let cancels = spans.filter {
                Self.squeezed($0.literalArguments).hasPrefix("(L10n.string(\"common.cancel\"")
                    && $0.arguments.contains(".cancel")
            }
            if confirms.count != 1 { violations.append("\(confirms.count) confirm buttons, not 1") }
            if cancels.count != 1 { violations.append("\(cancels.count) cancel-role Cancel buttons, not 1") }
            for button in confirms {
                if !Self.squeezed(button.action).contains("confirmToolbarTransfer(request)") {
                    violations.append("the confirm button does not call confirmToolbarTransfer(request)")
                }
                if button.arguments.contains(".cancel") {
                    violations.append("the confirm button carries the cancel role")
                }
            }
            for button in cancels {
                let rest = Self.squeezed(button.action)
                    .replacingOccurrences(of: "toolbarTransferRequest=nil", with: "")
                if rest != "{}" {
                    violations.append("the cancel button does something besides clearing the request: \(button.action)")
                }
            }

            let message = Self.squeezed(String(strict[messageOpen...messageClose]))
            if !message.contains("Text(ToolbarTransferPlan.message(") {
                violations.append("the message is not Text(ToolbarTransferPlan.message(")
            }
            if Self.occurrences(of: "Text(", in: message) != 1 {
                violations.append("the message shows more than the plan's one text")
            }
            return violations
        }
        throw ScanError.dialogNotFound
    }

    // MARK: - Scanner

    private static func squeezed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    /// The anchor through the balanced close of the first `{` after it, read
    /// from an already blanked view.
    private static func body(after anchor: String, in strict: String) throws -> String {
        guard let anchorRange = strict.range(of: anchor) else { throw ScanError.anchorNotFound }
        let characters = Array(strict[anchorRange.lowerBound...])
        guard let open = firstOffset(of: ["{"], in: characters, from: 0),
              let close = closingOffset(from: open, in: characters, open: "{", close: "}")
        else { throw ScanError.unbalanced }
        return String(characters[0...close])
    }

    private static func firstOffset(of token: [Character], in text: [Character], from start: Int) -> Int? {
        guard !token.isEmpty, text.count >= token.count, start <= text.count - token.count else { return nil }
        for offset in start...(text.count - token.count)
        where text[offset..<(offset + token.count)].elementsEqual(token) {
            return offset
        }
        return nil
    }

    private static func closingOffset(
        from open: Int, in text: [Character], open opener: Character, close closer: Character
    ) -> Int? {
        var depth = 0
        for offset in open..<text.count {
            if text[offset] == opener { depth += 1 }
            if text[offset] == closer {
                depth -= 1
                if depth == 0 { return offset }
            }
        }
        return nil
    }
}
