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
    /// width, because both of its figures come from the component itself: a
    /// component pinned to a wrong width agrees with itself (the review's
    /// mutation against the first version, a custom layout since deleted, took
    /// the ideal at a `.zero` proposal and left every other test green). The
    /// component's ideal has to be the bare control's own.
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

    /// Rigid AT the ideal, with no stretch, for all three kinds: offered 2000
    /// pt each component still reports its ideal, which is what the raw
    /// controls do (`aBareSegmentedPickerDoesNotGrowPastItsIdeal`,
    /// `aBareCheckboxOrRadioGroupDoesNotStretch`).
    @Test func eachComponentHoldsItsIdealWhenOfferedMore() {
        for locale in LayoutMeasure.shippedLocales {
            let segmentedIdeal = LayoutMeasure.idealWidth(locale: locale) { Self.rigidSegmented() }
            #expect(
                Self.width(locale: locale) { Self.rigidSegmented() } == segmentedIdeal,
                "segmented \(locale): ideal \(segmentedIdeal)")

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

    /// One of the two measurements that make `.fixedSize()` the
    /// behaviour-preserving shape. A raw checkbox reports less than the 2000 pt
    /// it is offered (101 pt in the Task 8 review); this test is the command
    /// that reproduces it. Stretching the component would be the change, not
    /// its preservation.
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

    /// The other measurement that makes `.fixedSize()` the right shape for the
    /// segmented kind. The premise that once justified a stretching custom
    /// layout was "several of the twenty-one segmented sites currently stretch
    /// to fill their row"; no command produced it. This test is the command
    /// that contradicts it: a bare segmented picker is DRAWN at its ideal width
    /// in a 2000-pt host, alone and beside a flexible `TextField` in an `HStack`
    /// (the shape of the variable rows in `FileActionEditor` and `SnippetsSheet`),
    /// with the picker on either side of the field.
    ///
    /// The positive beside it: the `HStack` reports the whole 2000 pt, so the
    /// field is flexible and the picker really was offered slack.
    @Test func aBareSegmentedPickerDoesNotGrowPastItsIdeal() throws {
        func picker() -> some View { Self.bareSegmented() }
        func field() -> some View { TextField("", text: .constant("")) }
        for locale in LayoutMeasure.shippedLocales {
            let ideal = LayoutMeasure.idealWidth(locale: locale) { picker() }
            let shapes: [(String, CGFloat?, CGFloat)] = [
                (
                    "alone", Self.renderedSegmentedWidth(locale: locale) { picker() },
                    Self.width(locale: locale) { picker() }
                ),
                (
                    "beside a field",
                    Self.renderedSegmentedWidth(locale: locale) {
                        HStack(spacing: 8) { field(); picker() }
                    },
                    Self.width(locale: locale) { HStack(spacing: 8) { field(); picker() } }
                ),
                (
                    "before a field",
                    Self.renderedSegmentedWidth(locale: locale) {
                        HStack(spacing: 8) { picker(); field() }
                    },
                    Self.width(locale: locale) { HStack(spacing: 8) { picker(); field() } }
                ),
            ]
            for (shape, drawn, reported) in shapes {
                let drawnWidth = try #require(drawn, "\(locale) \(shape): no segmented control found")
                #expect(
                    drawnWidth == ideal,
                    "\(locale) \(shape): drawn \(drawnWidth), ideal \(ideal), offered \(Self.offered)")
                if shape != "alone" {
                    #expect(reported == Self.offered, "\(locale) \(shape): row reports \(reported)")
                }
            }
        }
    }

    /// The width the segmented control is drawn at when `build` is hosted in a
    /// `offered`-wide view, found by walking the AppKit tree for the platform
    /// host of the segmented control. `nil` when none is found, which the caller
    /// turns into a failure rather than a pass.
    private static func renderedSegmentedWidth<V: View>(
        locale: String, of build: @MainActor () -> V
    ) -> CGFloat? {
        L10n.$localeOverride.withValue(locale) {
            let host = NSHostingView(rootView: build())
            host.frame = CGRect(x: 0, y: 0, width: offered, height: 200)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            @MainActor func find(in view: NSView) -> NSView? {
                let name = "\(type(of: view))"
                if name.contains("AppKitPlatformViewHost") && name.contains("Segmented") {
                    return view
                }
                for child in view.subviews { if let hit = find(in: child) { return hit } }
                return nil
            }
            return find(in: host)?.frame.width
        }
    }
}
