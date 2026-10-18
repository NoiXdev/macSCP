import AppKit
import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Holds the three rigid components to what they exist for: a control whose
/// minimum width equals its ideal width cannot be squeezed, so squeezing it
/// becomes overflow, and overflow is what the bounded-view guard measures.
///
/// Every sample is built INSIDE the closure `LayoutMeasure` takes, so its
/// labels resolve under the locale being measured.
@Suite("Rigid controls", .serialized)
@MainActor
struct RigidControlTests {
    private enum Sample: Hashable { case first, second }

    // MARK: - Samples, bare and rigid

    private static func bareSegmented() -> some View {
        Picker("", selection: .constant(Sample.first)) {
            Text(L10n.string("snippets.variables.kind.freeText", "Free text")).tag(Sample.first)
            Text(L10n.string("snippets.variables.kind.selection", "Choice")).tag(Sample.second)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private static func rigidSegmented() -> some View {
        SegmentedChoice(
            "", selection: .constant(Sample.first),
            options: [
                (Sample.first, L10n.string("snippets.variables.kind.freeText", "Free text")),
                (Sample.second, L10n.string("snippets.variables.kind.selection", "Choice")),
            ])
    }

    private static func bareRadio() -> some View {
        Picker("", selection: .constant(FileActionPerSelection.oncePerFile)) {
            ForEach(FileActionPerSelection.allCases, id: \.self) { form in
                Text(fileActionFormLabel(form)).tag(form)
            }
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
    }

    private static func rigidRadio() -> some View {
        RadioChoice(
            "", selection: .constant(FileActionPerSelection.oncePerFile),
            label: fileActionFormLabel)
    }

    private static func bareCheckbox() -> some View {
        Toggle(L10n.string("fileAction.editor.side.remote", "Remote pane"), isOn: .constant(true))
            .toggleStyle(.checkbox)
    }

    private static func bareCheckboxes() -> some View {
        HStack(spacing: 16) {
            Toggle(L10n.string("fileAction.editor.side.remote", "Remote pane"), isOn: .constant(true))
            Toggle(L10n.string("fileAction.editor.side.local", "Local pane"), isOn: .constant(true))
        }
        .toggleStyle(.checkbox)
    }

    private static func singleCheckbox() -> some View {
        CheckboxRow(
            L10n.string("fileAction.editor.side.remote", "Remote pane"), isOn: .constant(true))
    }

    private static func rigidCheckboxes() -> some View {
        HStack(spacing: 16) {
            CheckboxRow(
                L10n.string("fileAction.editor.side.remote", "Remote pane"), isOn: .constant(true))
            CheckboxRow(
                L10n.string("fileAction.editor.side.local", "Local pane"), isOn: .constant(true))
        }
    }

    // MARK: - Helpers

    private static let offered: CGFloat = 2_000

    /// The width the content takes when offered `offered`.
    private static func width<V: View>(
        locale: String, offered: CGFloat = RigidControlTests.offered,
        of build: @MainActor () -> V
    ) -> CGFloat {
        L10n.$localeOverride.withValue(locale) {
            NSHostingController(rootView: build())
                .sizeThatFits(in: CGSize(width: offered, height: 100_000)).width
        }
    }

    /// `[minimum, ideal]` for one locale.
    private static func figures<V: View>(
        _ locale: String, _ build: @MainActor () -> V
    ) -> [CGFloat] {
        [
            LayoutMeasure.minimumWidth(locale: locale, of: build),
            LayoutMeasure.idealWidth(locale: locale, of: build),
        ]
    }

    // MARK: - The properties

    /// The negative check: the components are rigid in every shipped
    /// language. It means nothing without `theRawControlsAreNotRigid` beside
    /// it, nor without `theComponentsIdealIsTheBareControlsIdeal`.
    @Test func eachComponentIsRigidInEveryLanguage() {
        for locale in LayoutMeasure.shippedLocales {
            let measured: [(String, [CGFloat])] = [
                ("segmented", Self.figures(locale) { Self.rigidSegmented() }),
                ("radio", Self.figures(locale) { Self.rigidRadio() }),
                ("checkbox", Self.figures(locale) { Self.singleCheckbox() }),
                ("checkbox pair", Self.figures(locale) { Self.rigidCheckboxes() }),
            ]
            for (name, pair) in measured {
                #expect(pair[0] == pair[1], "\(name) \(locale): minimum \(pair[0]), ideal \(pair[1])")
                #expect(pair[0] > 0, "\(name) \(locale): \(pair)")
            }
        }
    }

    /// Without this, `eachComponentIsRigidInEveryLanguage` passes for ANY
    /// floor, because both of its figures go through the wrapper: a wrong
    /// constant (the review's mutation was an ideal taken at a `.zero`
    /// proposal) agrees with itself. The wrapper's ideal has to be the
    /// control's own.
    @Test func theComponentsIdealIsTheBareControlsIdeal() {
        func ideals<R: View, B: View>(
            _ locale: String, _ rigid: @MainActor () -> R, _ bare: @MainActor () -> B
        ) -> [CGFloat] {
            [
                LayoutMeasure.idealWidth(locale: locale, of: rigid),
                LayoutMeasure.idealWidth(locale: locale, of: bare),
            ]
        }
        for locale in LayoutMeasure.shippedLocales {
            let measured: [(String, [CGFloat])] = [
                ("segmented", ideals(locale, { Self.rigidSegmented() }, { Self.bareSegmented() })),
                ("radio", ideals(locale, { Self.rigidRadio() }, { Self.bareRadio() })),
                ("checkbox", ideals(locale, { Self.singleCheckbox() }, { Self.bareCheckbox() })),
                (
                    "checkbox pair",
                    ideals(locale, { Self.rigidCheckboxes() }, { Self.bareCheckboxes() })
                ),
            ]
            for (name, pair) in measured {
                #expect(pair[0] == pair[1], "\(name) \(locale): component \(pair[0]), bare \(pair[1])")
                #expect(pair[1] > 0, "\(name) \(locale)")
            }
        }
    }

    /// The positive beside the negatives above, and the measurement that
    /// justifies the work: the same controls, bare, report a minimum BELOW
    /// their ideal in at least one catalogue. This test IS that measurement;
    /// its failure message prints the per-locale [minimum, ideal] figures.
    /// The single checkbox is measured on its own as well as in a pair, so
    /// the pair's compressibility cannot be the `HStack`'s alone. If SwiftUI
    /// ever made a bare control rigid this goes red, and the components can be
    /// retired.
    @Test func theRawControlsAreNotRigid() {
        func compressible<V: View>(_ build: @MainActor () -> V) -> [String: [CGFloat]] {
            var result: [String: [CGFloat]] = [:]
            for locale in LayoutMeasure.shippedLocales {
                result[locale] = Self.figures(locale, build)
            }
            return result
        }
        let segmented = compressible { Self.bareSegmented() }
        let radio = compressible { Self.bareRadio() }
        let checkbox = compressible { Self.bareCheckbox() }
        let checkboxes = compressible { Self.bareCheckboxes() }
        #expect(segmented.values.contains { $0[0] < $0[1] }, "\(segmented)")
        #expect(radio.values.contains { $0[0] < $0[1] }, "\(radio)")
        #expect(checkbox.values.contains { $0[0] < $0[1] }, "\(checkbox)")
        #expect(checkboxes.values.contains { $0[0] < $0[1] }, "\(checkboxes)")
    }

    /// Per kind, in both directions. The segmented picker is a FLOOR at its
    /// ideal that still stretches: offered 2000 pt it reports 2000, which
    /// `.fixedSize()` would not (the positive beside it). A checkbox and a
    /// radio group are rigid AT the ideal: offered 2000 pt they still report
    /// their ideal, which is what the raw controls do
    /// (`aBareCheckboxOrRadioGroupDoesNotStretch`).
    @Test func eachKindStretchesOrHoldsAsItsRawControlDoes() {
        for locale in LayoutMeasure.shippedLocales {
            #expect(
                Self.width(locale: locale) { Self.rigidSegmented() } == Self.offered,
                "segmented \(locale)")
            #expect(
                Self.width(locale: locale) { Self.rigidSegmented().fixedSize() } < Self.offered,
                "segmented under fixedSize \(locale)")

            let radioIdeal = LayoutMeasure.idealWidth(locale: locale) { Self.rigidRadio() }
            #expect(
                Self.width(locale: locale) { Self.rigidRadio() } == radioIdeal,
                "radio \(locale): ideal \(radioIdeal)")
            let checkboxIdeal = LayoutMeasure.idealWidth(locale: locale) { Self.singleCheckbox() }
            #expect(
                Self.width(locale: locale) { Self.singleCheckbox() } == checkboxIdeal,
                "checkbox \(locale): ideal \(checkboxIdeal)")
        }
    }

    /// The measurement that decides which kind gets which shape. A raw
    /// checkbox reports less than the 2000 pt it is offered (101 pt in the
    /// Task 8 review); this test is the command that reproduces it. The rigid
    /// components for these two kinds hold their ideal because stretching
    /// them would be the change, not its preservation.
    @Test func aBareCheckboxOrRadioGroupDoesNotStretch() {
        for locale in LayoutMeasure.shippedLocales {
            #expect(
                Self.width(locale: locale) { Self.bareCheckbox() } < Self.offered,
                "checkbox \(locale)")
            #expect(
                Self.width(locale: locale) { Self.bareRadio() } < Self.offered,
                "radio \(locale)")
        }
    }

    /// Stacks probe for a maximum with an infinite proposal; the segmented
    /// component answers with a finite width.
    @Test func anInfiniteProposalGetsAFiniteAnswer() {
        for locale in LayoutMeasure.shippedLocales {
            let reported = Self.width(locale: locale, offered: .infinity) { Self.rigidSegmented() }
            #expect(reported.isFinite && reported > 0, "\(locale): \(reported)")
        }
    }

    /// The measurement behind the segmented component's stretch. A bare
    /// segmented picker reports its ideal when offered far more, so it does not
    /// grow past its ideal. The component, which reports the whole offer,
    /// therefore claims row width the bare control never did. This test
    /// records that; it is the command that reproduces it.
    @Test func aBareSegmentedPickerDoesNotGrowPastItsIdeal() {
        for locale in LayoutMeasure.shippedLocales {
            let ideal = LayoutMeasure.idealWidth(locale: locale) { Self.bareSegmented() }
            let reported = Self.width(locale: locale) { Self.bareSegmented() }
            #expect(
                reported == ideal,
                "\(locale): offered \(Self.offered), reported \(reported), ideal \(ideal)")
        }
    }

    /// Placement: the component draws the control at the leading edge of the
    /// slot it was given (a bare picker is centred in it). The control is
    /// found in the hosted view tree and its frame read. This guards the
    /// origin only; see the note on `AtLeastIdealWidth`.
    @Test func theSegmentedControlIsPlacedAtTheLeadingEdge() throws {
        let host = NSHostingView(rootView: Self.rigidSegmented())
        host.frame = CGRect(x: 0, y: 0, width: Self.offered, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func find(in view: NSView) -> NSView? {
            if "\(type(of: view))".contains("AppKitPlatformViewHost") { return view }
            for child in view.subviews { if let hit = find(in: child) { return hit } }
            return nil
        }
        let control = try #require(find(in: host))
        #expect(control.frame.minX == 0, "\(control.frame)")
        #expect(control.frame.width < Self.offered, "\(control.frame)")
    }
}
