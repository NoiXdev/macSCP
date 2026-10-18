import SwiftUI

// Three controls that cannot be compressed below their ideal width.
//
// **Why they exist.** A compressed control reports a small minimum, is shrunk
// inside its row and truncates its labels, and NOTHING overflows, so no width
// measurement can see it. Once a control cannot be compressed, squeezing it
// becomes overflow, and overflow is what `BoundedView` measures. The compressible
// form is not writable through these types: each takes a label, never a styled
// control.
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
struct CheckboxRow: View {
    private let label: String
    private let isOn: Binding<Bool>

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self.isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .fixedSize()
    }
}
