import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Every place that chooses a group reads `GroupPickerEntries.build` and
/// labels a group with its path (jump-and-groups plan, Task 5, closing the
/// Interface row of 2026-09-18: "Group pickers should show the tree,
/// everywhere a group is chosen"). None of these views can be rendered in a
/// test, so this is a SOURCE-TEXT scan, comments and string literals blanked
/// (`SwiftSource.blankingCommentsAndStrings`), the stripper this target's
/// other wiring guards share.
///
/// The places, counted with `grep -n` on 2026-09-18 — four choosers, read
/// from three spots in the App target, and since the final review (T5-6)
/// one place that SHOWS a session's group by the same path, a fourth spot:
///
/// | Place                               | Reads the builder in                          |
/// |-------------------------------------|-----------------------------------------------|
/// | Session editor's group picker       | `SessionEditorGroupPicker.swift`, its `body`  |
/// | Session row "Move to"               | `SessionSidebar.swift`, `moveToMenuItems`     |
/// | Folder row "Move to"                | the same `moveToMenuItems`                    |
/// | "Import from Cyberduck" group choice | `ImportFromSourceViewModel.swift`, its `init` |
/// | Session overview's "Group" fact     | `SessionOverviewView.swift`, `SessionOverviewNames.resolve` |
///
/// That the overview's resolver answers the path is
/// `SessionOverviewNamesTests`' claim, tested on values; this suite only
/// counts it among the readers.
///
/// Both rows calling `moveToMenuItems` is `SidebarMoveToWiringGuardTests`'
/// claim; this suite does not restate it. That the editor's group row draws
/// `SessionEditorGroupPicker` is this suite's, since the picker moved out of
/// `ConnectionFormView.swift` with this task.
///
/// ## The negative checks have positive partners
///
/// CLAUDE.md, "Guards that name what they watch". Each "no longer labels a
/// group by its bare name" check reads a span a positive check on the same
/// span proves still holds the builder, so a span that moved or emptied
/// fails loudly instead of reading as satisfied. And the reader count is
/// itself positive: a whole-map equality, so a reader that vanished and one
/// that appeared are both red.
@Suite("Group picker wiring")
struct GroupPickerWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/GroupPickerWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appDirectory = "Sources/MacSCPAppKit"
    private static let formPath = "Sources/MacSCPAppKit/ConnectionFormView.swift"
    private static let pickerPath = "Sources/MacSCPAppKit/SessionEditorGroupPicker.swift"
    private static let sidebarPath = "Sources/MacSCPAppKit/SessionSidebar.swift"
    private static let importPath = "Sources/MacSCPAppKit/Presentation/ImportFromSourceViewModel.swift"
    private static let overviewPath = "Sources/MacSCPAppKit/SessionOverviewView.swift"
    private static let orderingPath = "Sources/macSCPCore/Sessions/SidebarOrdering.swift"

    /// The call, derived from the type rather than spelled, so a rename of
    /// the type moves this guard with it.
    private static let builderCall = "\(GroupPickerEntries.self).build("

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func code(_ path: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try raw(path))
    }

    private static func codeKeepingLiterals(_ path: String) throws -> String {
        try SwiftSource.blankingComments(try raw(path))
    }

    // MARK: - Who reads the builder

    /// Every `.swift` file under `Sources/MacSCPAppKit`, by its path from the
    /// repo root, mapped to how often its CODE calls the builder. Files that
    /// never call it are left out, so the map names the readers only.
    private static func appReaders() throws -> [String: Int] {
        let root = repoRoot.appendingPathComponent(appDirectory)
        let enumerator = try #require(
            FileManager.default.enumerator(atPath: root.path(percentEncoded: false)))
        var readers: [String: Int] = [:]
        var scanned = 0
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            scanned += 1
            let path = "\(appDirectory)/\(relative)"
            let count = TransferQueueBarCancelGuardTests.occurrenceCount(
                of: builderCall, in: try code(path))
            if count > 0 { readers[path] = count }
        }
        // The walk itself is a claim: a scan that read no files would find
        // no readers and could only disagree with the map below by accident.
        #expect(scanned > 100, "only \(scanned) Swift file(s) scanned under \(appDirectory)")
        return readers
    }

    @Test func theBuilderIsReadExactlyByTheListedPlaces() throws {
        let readers = try Self.appReaders()
        let expected = [
            Self.pickerPath: 1, Self.sidebarPath: 1, Self.importPath: 1, Self.overviewPath: 1,
        ]
        #expect(readers == expected, """
            \(Self.builderCall) is called from \(readers.sorted { $0.key < $1.key }) in the App \
            target, expected \(expected.sorted { $0.key < $1.key }) — the session editor's \
            picker, moveToMenuItems (both rows' "Move to"), the Cyberduck import, and the \
            session overview's group name. A place missing reads a flat list or a bare name \
            again; a new place is one this suite's table does not account for.
            """)
    }

    /// The Core half of "Move to": the targets themselves come from
    /// `SidebarOrdering.moveTargets`, which reads the builder too — so the
    /// ids a submenu offers and the paths it labels them with are one list.
    @Test func moveTargetsReadsTheBuilder() throws {
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "public static func moveTargets(", in: try Self.code(Self.orderingPath))
        #expect(body.contains(Self.builderCall), """
            SidebarOrdering.moveTargets no longer calls \(Self.builderCall) — the "Move to" \
            targets and the labels moveToMenuItems gives them come from two lists again.
            """)
    }

    // MARK: - Each place labels a group with its path

    /// The form's group row draws the picker view — the positive half that
    /// keeps the checks on that view's body from reading a view nobody shows.
    @Test func theEditorsGroupRowDrawsThePickerView() throws {
        let row = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "FormRow(label: groupLabel)", in: try Self.code(Self.formPath))
        #expect(row.contains("\(SessionEditorGroupPicker.self)("), """
            The group FormRow in \(Self.formPath) no longer draws \(SessionEditorGroupPicker.self) \
            — the editor's group choice is not the tree-labelled picker with its "New group…".
            """)
    }

    /// The picker's rows come from exactly one `ForEach(`, and that one
    /// iterates the builder. A COUNT, not a "no `ForEach(groups)`" check:
    /// the negative spelled one receiver, and `ForEach(sessionList.groups)`
    /// — or any other flat list — slipped past it (final review, T5-4).
    /// Planted exactly that way on 2026-09-18, the old check stayed green
    /// and this one went red.
    @Test func theEditorsGroupPickerListsTheBuilderByPath() throws {
        let body = try Self.pickerBody()
        #expect(body.contains(Self.builderCall), """
            \(Self.pickerPath)'s body no longer reads \(Self.builderCall).
            """)
        #expect(body.contains(".path)"), """
            \(Self.pickerPath)'s body no longer labels an entry with its path.
            """)
        let forEachCount = TransferQueueBarCancelGuardTests.occurrenceCount(of: "ForEach(", in: body)
        #expect(forEachCount == 1, """
            \(Self.pickerPath)'s body holds \(forEachCount) `ForEach(`, expected exactly one — \
            the builder's. A second one lists groups some other way: store order, bare names, \
            the flat list this task retired.
            """)
        #expect(body.contains("ForEach(\(Self.builderCall)"), """
            \(Self.pickerPath)'s one `ForEach(` no longer iterates \(Self.builderCall).
            """)
    }

    /// The picker lists, titles its prompt and creates from ONE list: the
    /// groups of the session list it hands the plan's `commit` (final
    /// review, T5-1). It used to list a `groups` parameter while the title
    /// and the commit read `sessionList.groups`, so the rows and the parent
    /// the prompt named agreed only because its one caller passed the same
    /// list twice.
    ///
    /// Read, not spelled: the session list is whatever the body passes as
    /// `commit`'s `sessionList:` argument, and both the builder's and the
    /// title's `groups:` argument must be that expression's `.groups`.
    @Test func theEditorsPickerListsAndTitlesTheListItCommitsTo() throws {
        let body = try Self.pickerBody()
        let plan = "\(SessionEditorNewGroupPlan.self)"
        let commitCall = try #require(Self.callText(after: "\(plan).commit(", in: body), """
            \(Self.pickerPath)'s body no longer calls \(plan).commit(.
            """)
        let sessionList = try #require(Self.argument("sessionList", in: commitCall), """
            \(plan).commit( in \(Self.pickerPath) no longer passes a `sessionList:` argument.
            """)
        let listed = try #require(Self.callText(after: Self.builderCall, in: body)
            .flatMap { Self.argument("groups", in: $0) }, """
            \(Self.builderCall) in \(Self.pickerPath)'s body no longer takes a `groups:` argument.
            """)
        let titled = try #require(Self.callText(after: "\(plan).title(", in: body)
            .flatMap { Self.argument("groups", in: $0) }, """
            \(plan).title( in \(Self.pickerPath)'s body no longer takes a `groups:` argument.
            """)
        #expect(listed == "\(sessionList).groups", """
            The picker lists `\(listed)`, but commits through `\(sessionList)` — its rows and \
            the list a new group is created in are two inputs again.
            """)
        #expect(titled == "\(sessionList).groups", """
            The prompt is titled from `\(titled)`, but the picker commits through \
            `\(sessionList)` — the parent it names and the one it creates in can disagree.
            """)
    }

    /// The text between `opener` (which ends in its `(`) and the parenthesis
    /// that closes it, or `nil` when `opener` does not occur.
    private static func callText(after opener: String, in code: String) -> String? {
        guard let start = code.range(of: opener)?.upperBound else { return nil }
        var depth = 0
        var index = start
        while index < code.endIndex {
            let character = code[index]
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                if depth == 0 { return String(code[start..<index]) }
                depth -= 1
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The expression passed as `label:` at the top level of an argument
    /// list, whitespace collapsed, or `nil` when there is none.
    private static func argument(_ label: String, in arguments: String) -> String? {
        var depth = 0
        var current = ""
        var pieces: [String] = []
        for character in arguments {
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        let prefix = "\(label):"
        for piece in pieces {
            let collapsed = piece.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard collapsed.hasPrefix(prefix) else { continue }
            return collapsed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func pickerBodyRange() throws -> Range<Int> {
        try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "var body: some View", in: try code(pickerPath))
    }

    private static func pickerBody() throws -> String {
        TransferQueueBarCancelGuardTests.slice(try pickerBodyRange(), of: try code(pickerPath))
    }

    @Test func theMoveToEntriesAreLabelledByPath() throws {
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func moveToMenuItems(", in: try Self.code(Self.sidebarPath))
        #expect(body.contains(Self.builderCall), """
            moveToMenuItems in \(Self.sidebarPath) no longer reads \(Self.builderCall).
            """)
        #expect(body.contains(".path)"), """
            moveToMenuItems no longer labels a target with its path.
            """)
        #expect(!body.contains("group.name"), """
            moveToMenuItems labels a target with its bare name again.
            """)
    }

    @Test func theImportsGroupChoicesComeFromTheBuilderAndShowAPath() throws {
        let code = try Self.code(Self.importPath)
        let initBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "init(sessions: [StoredSession], groups: [StoredGroup])", in: code)
        #expect(initBody.contains(Self.builderCall), """
            ImportFromSourceViewModel's init no longer reads \(Self.builderCall).
            """)
        let labelBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func groupPath(for choice: GroupChoice)", in: code)
        #expect(labelBody.contains(".path"), """
            ImportFromSourceViewModel.groupPath(for:) no longer answers an existing group's \
            path.
            """)
    }

    // MARK: - The editor's "New group…"

    @Test func theEditorOffersNewGroupBesideThePicker() throws {
        let range = try Self.pickerBodyRange()
        let bodyWithLiterals = TransferQueueBarCancelGuardTests.slice(
            range, of: try Self.codeKeepingLiterals(Self.pickerPath))
        #expect(bodyWithLiterals.contains("Button(L10n.string(\"sidebar.newGroup\""), """
            \(Self.pickerPath)'s body no longer offers a button reading the sidebar.newGroup \
            key — the wording every other "New group…" entry uses.
            """)
        #expect(try Self.pickerBody().contains("isShowingNewGroupPrompt = true"), """
            \(Self.pickerPath)'s "New group…" button no longer opens the name prompt.
            """)
    }

    @Test func theEditorsPromptCreatesAndTitlesThroughThePlan() throws {
        let body = try Self.pickerBody()
        let plan = "\(SessionEditorNewGroupPlan.self)"
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(of: "\(plan).commit(", in: body) == 1, """
            \(Self.pickerPath)'s body does not call \(plan).commit( exactly once — the prompt's \
            Create button no longer creates the group and selects it through the tested plan.
            """)
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(of: "\(plan).title(", in: body) == 1, """
            \(Self.pickerPath)'s body does not call \(plan).title( exactly once — the prompt no \
            longer names the folder the group lands in.
            """)
    }
}
