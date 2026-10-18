import SwiftUI

// Three controls that hold their ideal width by default, and the one
// per-site seam that lets a call site say otherwise.
//
// **Corrected 2026-10-18, Task 10.** The line above read "Three controls that
// hold their ideal width by default, and the two per-site seams that let a call
// site say otherwise." The second seam is gone: item 2 of the list below read
//
// > `isInAResizableContainer: true` on `TagFilterJoinPicker` and
// > `SheetSearchField`, the two shared views that wrap these components.
//
// and both opt-outs are removed. The session sidebar was the one caller of
// each, because it is a container the user narrows, and neither needed it:
// `SheetSearchField` held rigid fits the width the sidebar leaves it, and
// `TagFilterJoinPicker` there became a small pop-up button
// (`TagFilterJoinPicker.Presentation.compactMenu`), which fits where the
// segmented form does not. `ResizableContainerFloorTests` measures both against
// that width in every catalogue. What remains is the wrapping checkbox, so a
// contributor who finds `wraps: true` is looking at the only seam.
//
// **Corrected 2026-10-18, fix round 3.** This header opened "Three controls
// that cannot be compressed below their ideal width." and said of the
// components "The compressible form is not writable through these types: each
// takes a label, never a styled control." Neither is true of the tree any
// more. Two compressibility seams exist, a test asserts that one of them
// compresses, and a contributor reading the old header would conclude that
// adding another is forbidden or, finding these, that they are accidents.
// They are neither; they are listed below with the reason each is allowed.
//
// **Why the components exist.** A compressed control reports a small minimum,
// is shrunk inside its row and truncates its labels, and NOTHING overflows, so
// no width measurement can see it. Once a control cannot be compressed,
// squeezing it becomes overflow, and overflow is what `BoundedView` measures.
// Each component takes a label, never a styled control, so the bare
// compressible spelling is not what a call site writes.
//
// **The seam, and why it is justified.** RIGID IS THE DEFAULT, so forgetting the
// argument is safe: a compressible control keeps the guard green while its
// label is cut, which is the defect this work removes, and an opt-in would
// reproduce it silently at every call site that forgot it.
//
// `CheckboxRow(_:isOn:wraps:)`, `wraps: true`. Rigid vertically, free to
// break across lines horizontally. Allowed because the invariant is "no text
// is silently lost", and a WRAPPED label loses none; only a truncated one
// does. It is for a sentence (`.fixedSize()` fixes both axes, so a sentence
// held to one line sets the minimum width of the whole view it sits in).
// `RigidControlTests.aWrappingCheckboxBreaksTheLabelInsteadOfLosingIt` pins
// that it neither truncates nor reports its one-line ideal as its minimum.
//
// Rigid menu pickers are NOT components: a `Picker` in the menu style held
// with `.fixedSize()`, written by hand. A pop-up shows one label, which is why
// it fits where a segmented control of the same labels did not. Nothing but
// review keeps their `.fixedSize()` in place.
//
// **Corrected 2026-10-18, Task 10.** The paragraph below says the command it
// names "prints five lines" and that "All five carry `.fixedSize()`". It now
// prints seven: the same five and two more, `FileSearchBar` (1, the filter or
// jump choice, a pop-up since this task) and `SidebarTagFilterBar` (1, the
// sidebar's join choice, a small pop-up). Both carry `.fixedSize()`, read by
// eye at the site. Re-run it to confirm; the figure is only as good as the
// day it was counted.
//
// **Corrected 2026-10-18, fix round 4.** This paragraph first read "Three more
// rigid controls are NOT components", naming `AuditLogSheet` and the jump
// source and jump authentication rows of `ConnectionFormView`. The three are
// real; the count was not, and it was written without counting. Counted with
// `grep -rn 'pickerStyle[(][.]menu[)]' Sources/MacSCPAppKit` (bracketed so this
// comment does not match its own pattern), which prints five lines:
// `AuditLogSheet` (1), `ConnectionFormView` (2, the jump source and jump
// authentication rows), `SheetFacetPicker` (1, drawn inside `SSHKeysSheet`,
// `KnownHostsSheet` and `LoginSetsSheet`) and `DiagnosticsPanel` (1, outside
// any bounded view). All five carry `.fixedSize()`, read by eye at each site,
// not by the command: it finds the style, not the modifier. Treat the list as
// "at least these": a menu written in another spelling is not found by it.
//
// **Why `.fixedSize()` and no custom layout.** "Rigid" here means rigid AT the
// ideal, with no stretch, because none of the three kinds stretches to begin
// with. `RigidControlTests` holds the measurements that make this the
// behaviour-preserving shape, and they stay runnable:
//
// - `aBareCheckboxOrRadioGroupDoesNotStretch`: a raw checkbox and a raw radio
//   group report less than the width they are offered.
// - `aBareSegmentedPickerDoesNotGrowPastItsIdeal`: a bare segmented picker,
//   alone and beside a flexible `TextField` in an `HStack`, is drawn at its
//   ideal width however much room it is offered.
//
// An earlier version gave the segmented picker a custom `Layout`, a floor at the
// ideal that still stretched, on the stated premise "several of the twenty-one
// segmented sites currently stretch to fill their row". No command ever
// produced that sentence; the two measurements above contradict it, so the
// layout was deleted.

/// A segmented picker that cannot be compressed below its ideal width.
///
/// `accessibilityLabel` names the control for assistive technology only; the
/// picker's own label stays hidden, as at every call site. The labels are
/// parameters, so this type spells no display string.
struct SegmentedChoice<Value: Hashable>: View {
    private let accessibilityLabel: String
    private let selection: Binding<Value>
    private let options: [(value: Value, label: String)]

    init(
        _ accessibilityLabel: String, selection: Binding<Value>,
        options: [(value: Value, label: String)]
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.selection = selection
        self.options = options
    }

    var body: some View {
        Picker(accessibilityLabel, selection: selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].label).tag(options[index].value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

/// A radio group that cannot be compressed below its ideal width. One radio
/// per case of `Value`; `label` turns a case into the text beside it.
struct RadioChoice<Value: Hashable & CaseIterable>: View {
    private let accessibilityLabel: String
    private let selection: Binding<Value>
    private let label: (Value) -> String

    init(
        _ accessibilityLabel: String, selection: Binding<Value>,
        label: @escaping (Value) -> String
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.selection = selection
        self.label = label
    }

    var body: some View {
        Picker(accessibilityLabel, selection: selection) {
            ForEach(Array(Value.allCases), id: \.self) { value in
                Text(label(value)).tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
        .fixedSize()
    }
}

/// A checkbox that cannot be compressed below its ideal width.
///
/// **Two forms, and the call site chooses.** The default holds the label on one
/// line at its ideal width in both axes: right for a word or a short phrase,
/// where a squeezed label truncates and a truncated label loses text. With
/// `wraps: true` the label is rigid vertically only: it may break across
/// lines to fit the width it is given, and takes the height that needs. That
/// is the form for a SENTENCE, which cannot sensibly be held to one line
/// (`.fixedSize()` fixes both axes, so a sentence held to one line sets the
/// minimum width of the whole view it sits in). A wrapped label loses nothing;
/// `RigidControlTests.aWrappingCheckboxBreaksTheLabelInsteadOfLosingIt` pins
/// that it neither truncates nor reports a minimum equal to its one-line ideal.
struct CheckboxRow: View {
    private let label: String
    private let isOn: Binding<Bool>
    private let wraps: Bool

    init(_ label: String, isOn: Binding<Bool>, wraps: Bool = false) {
        self.label = label
        self.isOn = isOn
        self.wraps = wraps
    }

    var body: some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: !wraps, vertical: true)
    }
}
