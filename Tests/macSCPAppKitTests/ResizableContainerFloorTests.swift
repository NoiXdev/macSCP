import AppKit
import Foundation
import SwiftUI
import Testing
import MacSCPTestSupport
import macSCPCore

@testable import MacSCPAppKit

/// Holds every container the USER resizes to the width its window leaves it,
/// in every language the app ships.
///
/// `BoundedViewLayoutGuardTests` covers views that bound their own size. These
/// are the other kind: the main window's connection form, the Settings window's
/// two sections that carry a segmented control, the file pane's search bar and
/// the two sidebar controls. Each lives in something the user can make
/// narrower, and a rigid control (`RigidControls.swift`) raises how narrow that
/// can be, so the migration of their controls is only safe while this holds.
///
/// **What "offered" means for each.** Every ceiling is built from the
/// constant the window declares, never from a copy of its value:
///
/// - `ConnectionFormView`: `MainWindowSizePlan.formSize.width` less the
///   sidebar's lower bound, `SettingsStore.sidebarWidthRange`. The form's own
///   cap (420 to 460) is stricter and `BoundedViewLayoutGuardTests` holds it;
///   this is the figure for the window.
/// - `TerminalSettingsTab`, `CLISettingsSection`:
///   `SettingsView.minimumSize.width` less `SettingsView.sidebarColumnWidth`.
///   **Measured by one row each, not whole.** A grouped `Form` reports the same
///   minimum width whatever its rows hold, so the sections cannot be measured
///   (`aGroupedFormReportsTheSameWidthWhateverItHolds` pins that and will go red
///   the day it stops being true). What is measured instead is the one row of
///   each section that carries a segmented control, as the real view the
///   section itself draws (`TerminalCursorStyleRow`, `CompletionShellRow`), in a
///   plain stack. That is the row without the form's own insets, and the state
///   name says so. A figure for either is not a figure for the section.
/// - `FileSearchBar`: `BrowserPane.minimumWidth`, the width both panes take as
///   their `.frame(minWidth:)`.
/// - `TagFilterJoinPicker`, `SheetSearchField` in the sidebar: the sidebar's
///   lower bound less `SessionSidebar.horizontalInset` on each side.
///
/// **The figures**, minimum width in pt, de / en / fr / pl. "Before" was
/// measured at `a78ca9ca` with a throwaway test (`LayoutMeasure.minimumWidth`
/// of each view as the tree drew it, the sidebar's two controls with their
/// `isInAResizableContainer: true` opt-out); "after" is this suite's own report.
///
/// | container | before | after | ceiling |
/// |---|---|---|---|
/// | ConnectionFormView, both registry entries | 399 / 399 / 438 / 399 | unchanged | 530 |
/// | TerminalSettingsTab, the cursor row | 222 / 192.5 / 223 / 226 | 284 / 255.5 / 330.5 / 314 | 500 |
/// | CLISettingsSection, the shell row | 153.5 in all four | 168.5 in all four | 500 |
/// | FileSearchBar, with or without the invalid-regex message | 284 in all four | 268.5 / 247.5 / 269.5 / 243.5 | 280 |
/// | TagFilterJoinPicker | 189 / 140 / 241 / 211 | 114.5 / 79.5 / 137.5 / 115.5 | 150 |
/// | SheetSearchField, no message / message | 52 / 60 in all four | 90 / 98 in all four | 150 |
///
/// For the two Settings rows "before" is the compressible `Picker` the section
/// had, in the same plain stack as "after". The sections' own whole-view
/// figures at `a78ca9ca`, 321 in all four for the terminal section and 110 for
/// the command-line section, are not row figures and are not in the table: they
/// are what a grouped form reports, and say nothing about its rows.
///
/// Two containers were over their ceiling before this task and nothing could
/// see it, because a compressible control reports a small minimum: the search
/// bar (284 against a pane that can be dragged to 280) and the join picker (189,
/// 241 and 211 against 150). Held rigid as the segmented controls they were,
/// both would have been worse: the filter or jump choice takes 157 and 159 in
/// German and French against the 118 pt slot it was squeezed into, and the join
/// choice takes 220, 274 and 224. Each became a pop-up button, which shows one
/// label; the join choice's is drawn at the small control size, because at the
/// regular size French takes 160.5 against 150.
///
/// The form figures are reproduced by `MACSCP_BOUND_FIGURES=1 swift test
/// --filter BoundedViewFigureReportTests`, the others by this suite's own
/// report, `MACSCP_FLOOR_FIGURES=1 swift test --filter
/// ResizableContainerFloorReportTests`.
@Suite("Resizable container floors", .serialized)
@MainActor
struct ResizableContainerFloorTests {

    // MARK: - What is measured

    /// One container in one state, with what its window offers it and the
    /// rigid controls it holds.
    struct Container {
        /// The type's own name, for the failure message and the set check.
        let typeName: String
        /// What this puts on screen, in English.
        let stateName: String
        /// The width the window leaves it.
        let ceiling: CGFloat
        /// Whether the view's own `SheetBound` is lifted for the measurement
        /// (only the connection form has one).
        let suspendsBound: Bool
        /// The view, built fresh on every call (see `LayoutMeasure` for why).
        let content: @MainActor () -> AnyView
        /// The rigid controls the container holds, as they are drawn alone.
        /// The container's minimum may not be below any one of their ideals.
        let held: [(name: String, content: @MainActor () -> AnyView)]
    }

    static let sidebarCeiling: CGFloat =
        CGFloat(SettingsStore.sidebarWidthRange.lowerBound) - 2 * SessionSidebar.horizontalInset

    static var containers: [Container] {
        var all: [Container] = []

        for entry in BoundedViewRegistry.all where entry.typeName == "ConnectionFormView" {
            all.append(
                Container(
                    typeName: entry.typeName, stateName: entry.stateName,
                    ceiling: MainWindowSizePlan.formSize.width
                        - CGFloat(SettingsStore.sidebarWidthRange.lowerBound),
                    suspendsBound: true, content: entry.content, held: []))
        }

        let settingsCeiling = SettingsView.minimumSize.width - SettingsView.sidebarColumnWidth
        all.append(
            Container(
                typeName: "TerminalSettingsTab", stateName: Self.rowStateName("cursor style"),
                ceiling: settingsCeiling, suspendsBound: false,
                content: {
                    AnyView(VStack { TerminalCursorStyleRow(style: .constant(.block)) })
                },
                held: [
                    (
                        "the cursor style choice",
                        {
                            AnyView(
                                SegmentedChoice(
                                    L10n.string("settings.terminal.cursor", "Cursor"),
                                    selection: .constant(TerminalCursorStyle.block),
                                    options: [
                                        (
                                            TerminalCursorStyle.block,
                                            L10n.string("settings.terminal.cursor.block", "Block")
                                        ),
                                        (
                                            TerminalCursorStyle.bar,
                                            L10n.string("settings.terminal.cursor.bar", "Bar")
                                        ),
                                        (
                                            TerminalCursorStyle.underline,
                                            L10n.string(
                                                "settings.terminal.cursor.underline", "Underline")
                                        ),
                                    ]))
                        }
                    )
                ]))
        all.append(
            Container(
                typeName: "CLISettingsSection", stateName: Self.rowStateName("shell"),
                ceiling: settingsCeiling, suspendsBound: false,
                content: {
                    AnyView(
                        VStack {
                            CompletionShellRow(shell: .constant(ShellCompletionRecipe.Shell.allCases[0]))
                        })
                },
                held: [
                    (
                        "the shell choice",
                        {
                            AnyView(
                                SegmentedChoice(
                                    L10n.string("settings.cli.completion.shell", "Shell"),
                                    selection: .constant(ShellCompletionRecipe.Shell.allCases[0]),
                                    options: ShellCompletionRecipe.Shell.allCases.map {
                                        ($0, $0.rawValue)
                                    }))
                        }
                    )
                ]))

        let browser = RemoteBrowserViewModel(
            fs: LocalFileSystem(), startPath: NSTemporaryDirectory())
        all.append(
            Container(
                typeName: "FileSearchBar", stateName: "an empty query",
                ceiling: BrowserPane.minimumWidth, suspendsBound: false,
                content: {
                    AnyView(FileSearchBar(viewModel: browser, focusToken: 0, onClose: {}))
                },
                held: []))
        let invalid = RemoteBrowserViewModel(
            fs: LocalFileSystem(), startPath: NSTemporaryDirectory())
        invalid.searchIsRegex = true
        invalid.searchQuery = "("
        all.append(
            Container(
                typeName: "FileSearchBar", stateName: "a regular expression that does not compile",
                ceiling: BrowserPane.minimumWidth, suspendsBound: false,
                content: {
                    AnyView(FileSearchBar(viewModel: invalid, focusToken: 0, onClose: {}))
                },
                held: []))

        let twoTags = SidebarTagFilter(tags: ["a", "b"], join: .all)
        all.append(
            Container(
                typeName: "TagFilterJoinPicker", stateName: "two tags selected",
                ceiling: Self.sidebarCeiling, suspendsBound: false,
                content: { Self.sidebarJoinPicker(twoTags) },
                held: [("the join choice drawn alone", { Self.sidebarJoinPicker(twoTags) })]))

        all.append(
            Container(
                typeName: "SheetSearchField", stateName: "an empty query",
                ceiling: Self.sidebarCeiling, suspendsBound: false,
                content: {
                    AnyView(
                        SheetSearchField(
                            text: .constant(""), isRegex: .constant(false), errorText: nil))
                },
                held: [Self.regexCheckbox]))
        all.append(
            Container(
                typeName: "SheetSearchField", stateName: "a regular expression that does not compile",
                ceiling: Self.sidebarCeiling, suspendsBound: false,
                content: {
                    AnyView(
                        SheetSearchField(
                            text: .constant("("), isRegex: .constant(true),
                            errorText: L10n.string(
                                "search.regex.invalid", "Invalid regular expression")))
                },
                held: [Self.regexCheckbox]))
        return all
    }

    private static var regexCheckbox: (name: String, content: @MainActor () -> AnyView) {
        (
            "the regular expression checkbox",
            {
                AnyView(
                    CheckboxRow(L10n.string("search.regex", "Regex"), isOn: .constant(false)))
            }
        )
    }

    /// The join choice as the sidebar draws it: the same call `HostTagFilterRow`
    /// makes, so a change to the sidebar's presentation is measured here.
    private static func sidebarJoinPicker(_ filter: SidebarTagFilter) -> AnyView {
        AnyView(TagFilterJoinPicker(filter: .constant(filter), presentation: .compactMenu))
    }

    /// The two Settings sections are measured by their one row that carries a
    /// segmented control, in a plain stack, because the sections themselves
    /// cannot be measured (`aGroupedFormReportsTheSameWidthWhateverItHolds`).
    /// The name says so, so that a figure for one is not read as a figure for
    /// the whole section.
    private static func rowStateName(_ row: String) -> String {
        "the \(row) row alone, without the form's own insets"
    }

    private static func neededWidth(_ container: Container, _ locale: String) -> CGFloat {
        SheetBound.$isSuspendedForMeasurement.withValue(container.suspendsBound) {
            LayoutMeasure.minimumWidth(locale: locale, of: container.content)
        }
    }

    // MARK: - The guard

    @Test func noResizableContainerOutgrowsTheWindowItLivesIn() {
        for container in Self.containers {
            for locale in LayoutMeasure.shippedLocales {
                let width = Self.neededWidth(container, locale)
                #expect(
                    width <= container.ceiling,
                    """
                    \(container.typeName), \(container.stateName), \(locale): \
                    needs \(width) pt, its window leaves \(container.ceiling) pt
                    """)
            }
        }
    }

    // MARK: - Positive checks: the guard measures something

    /// The six containers are all in the list, in more than one language, and
    /// each is measured at a width that is not nothing. A list that lost a
    /// container, or a measurement that came back zero, would make the guard
    /// above pass by comparing nothing.
    @Test func allSixContainersAreMeasuredAndNoneMeasuresAsNothing() {
        let names = Set(Self.containers.map(\.typeName))
        #expect(
            names
                == [
                    "ConnectionFormView", "TerminalSettingsTab", "CLISettingsSection",
                    "FileSearchBar", "TagFilterJoinPicker", "SheetSearchField",
                ], "\(names.sorted())")
        let locales = LayoutMeasure.shippedLocales
        #expect(Set(locales).isSuperset(of: ["en", "de", "fr", "pl"]), "\(locales)")
        for container in Self.containers {
            for locale in locales {
                let width = Self.neededWidth(container, locale)
                #expect(
                    width > 0, "\(container.typeName), \(container.stateName), \(locale): \(width)")
            }
            #expect(container.ceiling > 0, "\(container.typeName): \(container.ceiling)")
        }
    }

    /// A container that holds a rigid control cannot be measured below that
    /// control's ideal. If one went back to a compressible control it would
    /// report a small minimum, pass the guard above, and cut its labels —
    /// the defect this plan removes — and the minimum here would fall under
    /// the control's ideal.
    @Test func aContainerIsAsWideAsTheRigidControlsItHolds() {
        var checked = 0
        for container in Self.containers {
            for control in container.held {
                for locale in LayoutMeasure.shippedLocales {
                    let needed = Self.neededWidth(container, locale)
                    let ideal = LayoutMeasure.idealWidth(locale: locale, of: control.content)
                    checked += 1
                    #expect(
                        needed >= ideal,
                        """
                        \(container.typeName), \(container.stateName), \(locale): \
                        measures \(needed) pt, below \(control.name) at \(ideal) pt
                        """)
                }
            }
        }
        #expect(checked > 0)
    }

    /// `sidebarJoinPicker` above copies the one call `HostTagFilterRow` makes,
    /// because that row is `private` and cannot be built from here. This holds
    /// the copy to the original: the row's source spells the same
    /// presentation, once, and the tag dialog's does not.
    @Test func theSidebarRowDrawsTheJoinPickerTheWayThisSuiteMeasuresIt() throws {
        let sources = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let file = sources.appendingPathComponent("SidebarTagFilterBar.swift")
        let code = try SourceCorpus.code(of: file)
        let calls = code.components(separatedBy: "TagFilterJoinPicker(filter:")
            .dropFirst().map { String($0.prefix { $0 != ")" }) }
        #expect(calls.count == 2, "\(calls)")
        #expect(calls.filter { $0.contains("presentation: .compactMenu") }.count == 1, "\(calls)")
    }

    /// Why the two Settings sections are measured by a row and not whole: a
    /// grouped `Form` is backed by a scrolling table, and the width
    /// `sizeThatFits` returns for it does not depend on what its rows hold.
    /// Measured 2026-10-18 on Darwin 27: a grouped form reported a minimum of
    /// 60.0 pt with a 600 pt rectangle in a row and with a short text in the
    /// same row, and a plain stack with the same rectangle reported 608.0.
    ///
    /// This is the tripwire for the day that stops being true. It compares a
    /// form holding something very wide with one holding something narrow; if
    /// the two ever differ, the form has become measurable, and the two rows
    /// above should be replaced by `TerminalSettingsTab` and
    /// `CLISettingsSection` whole. Its positive half is the plain stack, which
    /// must report the wide row as wide, so that "the same" is not the answer
    /// a measurement that sees nothing at all would also give.
    @Test func aGroupedFormReportsTheSameWidthWhateverItHolds() {
        func form(_ width: CGFloat) -> some View {
            Form {
                Section {
                    LabeledContent("x") { Color.clear.frame(width: width, height: 10) }
                }
            }
            .formStyle(.grouped)
        }
        func stack(_ width: CGFloat) -> some View {
            VStack { LabeledContent("x") { Color.clear.frame(width: width, height: 10) } }
        }
        let wideForm = LayoutMeasure.minimumWidth(locale: "en") { form(600) }
        let narrowForm = LayoutMeasure.minimumWidth(locale: "en") { form(20) }
        #expect(wideForm == narrowForm, "a wide row: \(wideForm) pt, a narrow row: \(narrowForm) pt")
        let wideStack = LayoutMeasure.minimumWidth(locale: "en") { stack(600) }
        let narrowStack = LayoutMeasure.minimumWidth(locale: "en") { stack(20) }
        #expect(wideStack > narrowStack + 500, "a wide row: \(wideStack) pt, a narrow row: \(narrowStack) pt")
    }
}
