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
/// 2. `requestToolbarTransfer(` asks `ToolbarTransferPlan.plan(`, reads the
///    destination once through `ToolbarTransferPlan.destinationPath(`,
///    reaches `transferSelection(` only in its `.transferNow` case — passing
///    that destination — and in its `.ask` case stores a
///    `ToolbarTransferRequest(` built from the selection it was handed and
///    that same destination — captured at press.
/// 3. `confirmToolbarTransfer(` first compares the tab's current session id
///    with the captured one and returns when they differ, then transfers the
///    request's own selection, side, tab, session and captured destination,
///    and reads no pane's `selectedItems`. `transferSelection(` resolves a
///    nil `destinationDirectory` to the other pane's current path, in both
///    directions, so the routes that pass none are unchanged.
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
        case anchorNotFound, unbalanced
    }

    // MARK: - 1-3. The buttons, the plan branch, the confirm action

    @Test func theToolbarButtonsReachTheTransferOnlyThroughThePlan() throws {
        let source = try SourceCorpus.text(of: Self.transfersFile)
        let violations = try Self.transfersViolations(source)
        #expect(violations.isEmpty, "the toolbar transfer wiring is broken: \(violations)")
    }

    // MARK: - 4. The question

    @Test func theQuestionIsAConfirmationDialogBoundToTheRequest() throws {
        let source = try SourceCorpus.text(of: Self.sheetsFile)
        let violations = try Self.dialogViolations(source)
        #expect(violations.isEmpty, "the toolbar transfer question is wired wrong: \(violations)")
    }

    // MARK: - Scanner self-tests

    private static func transfersFixture(
        upload: String = "requestToolbarTransfer(selected, from: .local, in: tab, session: session)",
        download: String = "requestToolbarTransfer(selected, from: .remote, in: tab, session: session)",
        transferNow: String = "transferSelection(selection, from: side, in: tab, session: session, destinationDirectory: destination)",
        ask: String = Self.fixtureAsk,
        identity: String = "guard request.tab.session?.id == request.session.id else { return }",
        confirm: String = Self.fixtureConfirm,
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
                let destination = ToolbarTransferPlan.destinationPath(side: side, localPath: session.local.currentPath, remotePath: session.remote.currentPath)
                switch ToolbarTransferPlan.plan(for: selection) {
                case .transferNow:
                    \(transferNow)
                case .ask(let count, let folders):
                    \(ask)
                }
            }
            func confirmToolbarTransfer(_ request: ToolbarTransferRequest) {
                \(identity)
                \(confirm)
            }
            func transferSelection(_ selection: [RemoteFileItem], from side: BrowserPaneSide, in tab: SessionTab, session: BrowserSession, destinationDirectory: String? = nil) {
                \(extra)
                let remoteDestination = destinationDirectory ?? session.remote.currentPath
                let localDestination = destinationDirectory ?? session.local.currentPath
                queue.enqueue(fileName: item.name, destinationDirectory: remoteDestination, onCompleted: {})
            }
        }
        """
    }

    private static let fixtureAsk = "toolbarTransferRequest = ToolbarTransferRequest(tab: tab, session: session, side: side, selection: selection, itemCount: count, includesFolders: folders, destinationPath: destination)"
    private static let fixtureConfirm = "transferSelection(request.selection, from: request.side, in: request.tab, session: request.session, destinationDirectory: request.destinationPath)"

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
        ["identity": ""],
        ["identity": "guard request.tab.session != nil else { return }"],
        ["identity": "if request.tab.session?.id == request.session.id { print(1) }"],
        ["confirmThenIdentity": ""],
        ["confirm": "transferSelection(request.selection, from: request.side, in: request.tab, session: request.session)"],
        ["transferNow": "transferSelection(selection, from: side, in: tab, session: session)"],
        ["extra": "queue.enqueueTree(directoryName: item.name, destinationDirectory: session.local.currentPath, onCompleted: {})"],
        ["ask": "toolbarTransferRequest = ToolbarTransferRequest(tab: tab, session: session, side: side, selection: selection, itemCount: count, includesFolders: folders, destinationPath: session.remote.currentPath)"],
    ])
    func theTransfersScannerSeesABypass(_ planted: [String: String]) throws {
        let fixture = Self.transfersFixture(
            upload: planted["upload"] ?? "requestToolbarTransfer(selected, from: .local, in: tab, session: session)",
            download: planted["download"] ?? "requestToolbarTransfer(selected, from: .remote, in: tab, session: session)",
            transferNow: planted["transferNow"] ?? "transferSelection(selection, from: side, in: tab, session: session, destinationDirectory: destination)",
            ask: planted["ask"] ?? Self.fixtureAsk,
            identity: planted["confirmThenIdentity"] != nil
                ? Self.fixtureConfirm : (planted["identity"] ?? "guard request.tab.session?.id == request.session.id else { return }"),
            confirm: planted["confirmThenIdentity"] != nil
                ? "guard request.tab.session?.id == request.session.id else { return }" : (planted["confirm"] ?? Self.fixtureConfirm),
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
        #expect(throws: ConfirmationDialogScan.ScanError.self) {
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
        if !Self.squeezed(request).contains("letdestination=ToolbarTransferPlan.destinationPath(") {
            violations.append("requestToolbarTransfer( does not read the destination once through ToolbarTransferPlan.destinationPath(")
        }
        if let now = request.range(of: "case .transferNow"), let ask = request.range(of: "case .ask"),
           now.upperBound <= ask.lowerBound {
            let nowBranch = request[now.upperBound..<ask.lowerBound]
            let askBranch = request[ask.upperBound...]
            if !nowBranch.contains("transferSelection(") {
                violations.append("the .transferNow case does not call transferSelection(")
            }
            if !Self.squeezed(String(nowBranch)).contains("destinationDirectory:destination)") {
                violations.append("the .transferNow case does not pass the destination it read")
            }
            if askBranch.contains("transferSelection(") {
                violations.append("the .ask case calls transferSelection(")
            }
            let squeezedAsk = Self.squeezed(String(askBranch))
            if !squeezedAsk.contains("toolbarTransferRequest=ToolbarTransferRequest(")
                || !squeezedAsk.contains("selection:selection")
                || !squeezedAsk.contains("destinationPath:destination)") {
                violations.append("the .ask case does not store a ToolbarTransferRequest( carrying the pressed selection")
            }
        } else {
            violations.append("requestToolbarTransfer( has no .transferNow case followed by a .ask case")
        }
        if Self.occurrences(of: "transferSelection(", in: request) != 1 {
            violations.append("transferSelection( occurs \(Self.occurrences(of: "transferSelection(", in: request)) times in requestToolbarTransfer(, not once")
        }

        let confirm = try Self.body(after: "func confirmToolbarTransfer(", in: strict)
        let squeezedConfirm = Self.squeezed(confirm)
        let transferCall = "transferSelection(request.selection,from:request.side,in:request.tab,"
            + "session:request.session,destinationDirectory:request.destinationPath)"
        let identityGuard = "guardrequest.tab.session?.id==request.session.idelse{return}"
        let callAt = squeezedConfirm.range(of: transferCall)
        if callAt == nil {
            violations.append("confirmToolbarTransfer( does not transfer the request's own selection, side, tab, session and captured destination")
        }
        if let identityAt = squeezedConfirm.range(of: identityGuard) {
            if let callAt, identityAt.lowerBound > callAt.lowerBound {
                violations.append("confirmToolbarTransfer( compares the session identity only after transferring")
            }
        } else {
            violations.append("confirmToolbarTransfer( does not return when the tab's session is no longer the captured one")
        }
        if confirm.contains("selectedItems") {
            violations.append("confirmToolbarTransfer( re-reads a pane's selectedItems at confirm")
        }

        let transfer = Self.squeezed(try Self.body(after: "func transferSelection(", in: strict))
        if !transfer.contains("destinationDirectory:String?=nil)") {
            violations.append("transferSelection( has no defaulted destinationDirectory parameter")
        }
        for side in ["remote", "local"]
        where !transfer.contains("destinationDirectory??session.\(side).currentPath") {
            violations.append("transferSelection( does not fall back to session.\(side).currentPath")
        }
        // Beside the fallback above: an enqueue that still reads a pane's
        // path itself ignores the destination it was handed.
        if transfer.contains("destinationDirectory:session.") {
            violations.append("an enqueue in transferSelection( reads a pane's currentPath instead of the resolved destination")
        }

        // The declaration, the .transferNow case and the confirm action: no
        // fourth route to the transfer in this file.
        let total = Self.occurrences(of: "transferSelection(", in: strict)
        if total != 3 {
            violations.append("transferSelection( occurs \(total) times in the file, not 3 (declaration, .transferNow, confirm)")
        }
        return violations
    }

    /// Claim 4 over `ContentView+Sheets.swift` (or a fixture of it), read
    /// through the target's one dialog scanner (`ConfirmationDialogScan`,
    /// which `ConvertKeyWiringGuardTests` reads too). Throws when no dialog
    /// is bound to `toolbarTransferRequest` or its shape cannot be read.
    private static func dialogViolations(_ source: String) throws -> [String] {
        let dialog = try ConfirmationDialogScan.bound(to: "toolbarTransferRequest", in: source)
        var violations: [String] = []

        let squeezedArguments = Self.squeezed(dialog.arguments)
        if !squeezedArguments.contains("presenting:toolbarTransferRequest") {
            violations.append("the request does not reach the buttons through presenting:")
        }
        if !squeezedArguments.hasPrefix("(toolbarTransferRequest.map{ToolbarTransferPlan.title(") {
            violations.append("the title is not ToolbarTransferPlan.title(")
        }
        if !Self.squeezed(dialog.setter).contains("toolbarTransferRequest=nil") {
            violations.append("the setter does not clear toolbarTransferRequest")
        }
        if dialog.setter.contains("confirmToolbarTransfer(") || dialog.setter.contains("transferSelection(") {
            violations.append("the setter runs a transfer")
        }

        let transfers = Self.occurrences(of: "confirmToolbarTransfer(", in: dialog.buttons)
        if transfers != 1 {
            violations.append("confirmToolbarTransfer( occurs \(transfers) times in the buttons closure, not once")
        }
        if dialog.buttons.contains("transferSelection(") {
            violations.append("a button calls transferSelection( directly")
        }

        let spans = dialog.buttonSpans
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

        let message = Self.squeezed(dialog.message)
        if !message.contains("Text(ToolbarTransferPlan.message(") {
            violations.append("the message is not Text(ToolbarTransferPlan.message(")
        }
        if Self.occurrences(of: "Text(", in: message) != 1 {
            violations.append("the message shows more than the plan's one text")
        }
        return violations
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
        guard let open = ConfirmationDialogScan.firstOffset(of: ["{"], in: characters, from: 0),
              let close = ConfirmationDialogScan.closingOffset(
                  from: open, in: characters, open: "{", close: "}")
        else { throw ScanError.unbalanced }
        return String(characters[0...close])
    }
}
