import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Direct tests over `ToolbarTransferPlan` — whether the toolbar's Upload or
/// Download button asks before transferring (maintainer decision of
/// 2026-09-16: ask only when the selection holds more than one item or a
/// folder) — plus the question's catalog text in all four languages.
///
/// Which buttons call the plan, and what the dialog's buttons do, is
/// `ToolbarTransferConfirmationGuardTests`' job: nothing in this project
/// renders SwiftUI.
@Suite("Toolbar transfer plan")
struct ToolbarTransferPlanTests {
    private static let languages = ["en", "de", "fr", "pl"]
    private static let sides: [BrowserPaneSide] = [.local, .remote]

    private static func item(_ name: String, _ kind: RemoteFileKind) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/data/\(name)", kind: kind)
    }

    // MARK: - The decision

    @Test func oneFileTransfersWithoutAQuestion() {
        #expect(ToolbarTransferPlan.plan(for: [Self.item("a.txt", .file)]) == .transferNow)
    }

    @Test func twoFilesAsk() {
        let plan = ToolbarTransferPlan.plan(for: [Self.item("a.txt", .file), Self.item("b.txt", .file)])
        #expect(plan == .ask(itemCount: 2, includesFolders: false))
    }

    @Test func oneFolderAsks() {
        #expect(ToolbarTransferPlan.plan(for: [Self.item("dir", .directory)])
            == .ask(itemCount: 1, includesFolders: true))
    }

    @Test func aFileAndAFolderAsk() {
        let plan = ToolbarTransferPlan.plan(for: [Self.item("a.txt", .file), Self.item("dir", .directory)])
        #expect(plan == .ask(itemCount: 2, includesFolders: true))
    }

    /// `transferSelection` skips symlinks, so a symlink is not an item that
    /// will be transferred and does not count toward "more than one".
    @Test func aSymlinkBesideOneFileDoesNotMakeItAsk() {
        let plan = ToolbarTransferPlan.plan(for: [Self.item("a.txt", .file), Self.item("link", .symlink)])
        #expect(plan == .transferNow)
    }

    @Test func symlinksAreLeftOutOfTheCount() {
        let plan = ToolbarTransferPlan.plan(for: [
            Self.item("a.txt", .file), Self.item("link", .symlink), Self.item("b.txt", .file),
        ])
        #expect(plan == .ask(itemCount: 2, includesFolders: false))
    }

    /// Nothing that would be transferred, nothing to ask about.
    @Test func aSelectionOfOnlySymlinksAsksNothing() {
        #expect(ToolbarTransferPlan.plan(for: [Self.item("l1", .symlink), Self.item("l2", .symlink)])
            == .transferNow)
        #expect(ToolbarTransferPlan.plan(for: []) == .transferNow)
    }

    /// `transferSelection` enqueues an `.other` row like a file, so it counts
    /// as an item and not as a folder.
    @Test func anOtherKindCountsAsAnItemNotAFolder() {
        let plan = ToolbarTransferPlan.plan(for: [Self.item("a.txt", .file), Self.item("fifo", .other)])
        #expect(plan == .ask(itemCount: 2, includesFolders: false))
        #expect(ToolbarTransferPlan.plan(for: [Self.item("fifo", .other)]) == .transferNow)
    }

    /// The destination a toolbar transfer goes to, and the question names,
    /// is the OTHER pane's directory: upload goes to the remote pane's,
    /// download to the local pane's.
    @Test func theDestinationIsTheOtherPanesDirectory() {
        #expect(ToolbarTransferPlan.destinationPath(side: .local, localPath: "/Users/me", remotePath: "/srv/in")
            == "/srv/in")
        #expect(ToolbarTransferPlan.destinationPath(side: .remote, localPath: "/Users/me", remotePath: "/srv/in")
            == "/Users/me")
    }

    // MARK: - The question's text

    /// Four message keys and two titles, one per direction and folder case,
    /// no two alike, each naming its direction.
    @Test func eachDirectionAndFolderCaseHasItsOwnKey() {
        var messageKeys: Set<String> = []
        for side in Self.sides {
            let direction = side == .local ? "upload" : "download"
            #expect(ToolbarTransferPlan.titleKey(side: side).key.contains(".\(direction)."))
            for folders in [false, true] {
                let key = ToolbarTransferPlan.messageKey(side: side, includesFolders: folders).key
                #expect(key.contains(".\(direction)."), "\(key) does not name \(direction)")
                messageKeys.insert(key)
            }
        }
        #expect(messageKeys.count == 4)
        #expect(ToolbarTransferPlan.titleKey(side: .local).key != ToolbarTransferPlan.titleKey(side: .remote).key)
    }

    private static func bundle(forLanguage language: String) -> Bundle? {
        guard let path = L10n.bundle.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    private static let unresolved = "ZZ-UNRESOLVED-ZZ"
    private static let path = "/srv/incoming"

    private static func resolved(
        _ key: String, language: String, count: Int? = nil
    ) -> String? {
        guard let languageBundle = bundle(forLanguage: language) else { return nil }
        let format = NSLocalizedString(key, bundle: languageBundle, value: unresolved, comment: "")
        guard let count else { return format }
        return String(format: format, locale: Locale(identifier: language), count, path)
    }

    private static func wordingIgnoringDigits(_ text: String?) -> String? {
        text.map { $0.filter { !$0.isNumber } }
    }

    private static func allMessageKeys() -> [String] {
        sides.flatMap { side in
            [false, true].map { ToolbarTransferPlan.messageKey(side: side, includesFolders: $0).key }
        }
    }

    @Test(arguments: ToolbarTransferPlanTests.languages)
    func everyKeyResolvesInEveryLanguage(language: String) {
        #expect(Self.bundle(forLanguage: language) != nil, "\(language) is missing its .lproj bundle")
        for side in Self.sides {
            let title = Self.resolved(ToolbarTransferPlan.titleKey(side: side).key, language: language)
            #expect(title != Self.unresolved && title?.isEmpty == false, "\(language): title for \(side)")
        }
        for key in Self.allMessageKeys() {
            let text = Self.resolved(key, language: language, count: 3)
            #expect(text?.contains(Self.unresolved) == false, "\(language) does not resolve \(key)")
            #expect(text?.contains(Self.path) == true, "\(language) \(key) drops the destination: \(text ?? "nil")")
            #expect(text?.contains("3") == true, "\(language) \(key) drops the count: \(text ?? "nil")")
        }
    }

    @Test(arguments: ToolbarTransferPlanTests.languages)
    func everyLanguageDistinguishesOneFromTwo(language: String) {
        for key in Self.allMessageKeys() {
            let one = Self.wordingIgnoringDigits(Self.resolved(key, language: language, count: 1))
            let two = Self.wordingIgnoringDigits(Self.resolved(key, language: language, count: 2))
            #expect(one != nil && one != two, "\(language) \(key): 1=\(one ?? "nil") 2=\(two ?? "nil")")
        }
    }

    @Test func polishSelectsTheThirdCategoryForFive() {
        for key in Self.allMessageKeys() {
            let one = Self.wordingIgnoringDigits(Self.resolved(key, language: "pl", count: 1))
            let few = Self.wordingIgnoringDigits(Self.resolved(key, language: "pl", count: 2))
            let many = Self.wordingIgnoringDigits(Self.resolved(key, language: "pl", count: 5))
            #expect(one != few && few != many && one != many,
                    "\(key): 1=\(one ?? "nil") 2=\(few ?? "nil") 5=\(many ?? "nil")")
        }
    }

    /// The helpers the dialog calls go through the production lookup
    /// (`L10n.string` + plain `String(format:)`) with the key the plan names.
    @Test func theHelpersReadTheKeysThePlanNames() {
        for side in Self.sides {
            let titleKey = ToolbarTransferPlan.titleKey(side: side)
            #expect(ToolbarTransferPlan.title(side: side) == L10n.string(titleKey.key, titleKey.defaultValue))
            #expect(!ToolbarTransferPlan.title(side: side).isEmpty)
            let label = ToolbarTransferPlan.confirmLabel(side: side)
            #expect(label == (side == .local
                ? L10n.string("browser.upload", "Upload") : L10n.string("browser.download", "Download")))
            for folders in [false, true] {
                let key = ToolbarTransferPlan.messageKey(side: side, includesFolders: folders)
                let expected = String(format: L10n.string(key.key, key.defaultValue), 4, Self.path)
                let message = ToolbarTransferPlan.message(
                    side: side, itemCount: 4, includesFolders: folders, destinationPath: Self.path)
                #expect(message == expected)
                #expect(message.contains(Self.path) && message.contains("4"), "\(message)")
            }
        }
    }
}
