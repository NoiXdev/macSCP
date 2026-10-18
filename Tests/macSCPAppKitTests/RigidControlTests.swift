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

    // MARK: - The properties

    /// The negative check: the components are rigid in every shipped
    /// language. It means nothing without `theRawControlsAreNotRigid` beside it.
    @Test func eachComponentIsRigidInEveryLanguage() {
        func figures<V: View>(_ locale: String, _ build: @MainActor () -> V) -> [CGFloat] {
            [
                LayoutMeasure.minimumWidth(locale: locale, of: build),
                LayoutMeasure.idealWidth(locale: locale, of: build),
            ]
        }
        for locale in LayoutMeasure.shippedLocales {
            let measured: [(String, [CGFloat])] = [
                ("segmented", figures(locale) { Self.rigidSegmented() }),
                ("radio", figures(locale) { Self.rigidRadio() }),
                ("checkbox", figures(locale) { Self.singleCheckbox() }),
                ("checkbox pair", figures(locale) { Self.rigidCheckboxes() }),
            ]
            for (name, pair) in measured {
                #expect(pair[0] == pair[1], "\(name) \(locale): minimum \(pair[0]), ideal \(pair[1])")
                #expect(pair[0] > 0, "\(name) \(locale): \(pair)")
            }
        }
    }

    /// The positive beside the negative above, and the measurement that
    /// justifies the work: the same controls, bare, report a minimum BELOW
    /// their ideal in at least one catalogue. Measured 2026-10-17: the
    /// segmented kind picker pl 173.5 vs 219.0, the radio group de 21.0 vs
    /// 213.0, the checkbox pair de 58.0 vs 251.0. If SwiftUI ever made a bare
    /// control rigid this goes red, and the components can be retired.
    @Test func theRawControlsAreNotRigid() {
        func compressible<V: View>(_ build: @MainActor () -> V) -> [String: [CGFloat]] {
            var figures: [String: [CGFloat]] = [:]
            for locale in LayoutMeasure.shippedLocales {
                figures[locale] = [
                    LayoutMeasure.minimumWidth(locale: locale, of: build),
                    LayoutMeasure.idealWidth(locale: locale, of: build),
                ]
            }
            return figures
        }
        let segmented = compressible { Self.bareSegmented() }
        let radio = compressible { Self.bareRadio() }
        let checkboxes = compressible { Self.bareCheckboxes() }
        #expect(segmented.values.contains { $0[0] < $0[1] }, "\(segmented)")
        #expect(radio.values.contains { $0[0] < $0[1] }, "\(radio)")
        #expect(checkboxes.values.contains { $0[0] < $0[1] }, "\(checkboxes)")
    }

    /// A floor, not a shrink. Offered far more than its ideal, the component
    /// reports what it was offered, so it keeps stretching to fill a row.
    /// `.fixedSize()` on the same control reports its ideal instead; that
    /// half is the positive beside the check, and the property `.fixedSize()`
    /// would fail.
    @Test func aRigidControlStillStretches() {
        let offered: CGFloat = 2_000
        func width<V: View>(locale: String, of build: @MainActor () -> V) -> CGFloat {
            L10n.$localeOverride.withValue(locale) {
                NSHostingController(rootView: build())
                    .sizeThatFits(in: CGSize(width: offered, height: 100_000)).width
            }
        }
        for locale in LayoutMeasure.shippedLocales {
            #expect(width(locale: locale) { Self.rigidSegmented() } == offered, "segmented \(locale)")
            #expect(width(locale: locale) { Self.rigidRadio() } == offered, "radio \(locale)")
            #expect(width(locale: locale) { Self.singleCheckbox() } == offered, "checkbox \(locale)")

            let shrunk = width(locale: locale) { Self.rigidSegmented().fixedSize() }
            #expect(shrunk < offered, "fixedSize \(locale): \(shrunk)")
        }
    }
}
