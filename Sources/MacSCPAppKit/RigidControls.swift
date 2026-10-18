import SwiftUI

/// Takes the larger of its subview's ideal width and what is proposed, so
/// the subview stretches but is never compressed below its ideal. This is
/// what "rigid" means here: a floor at the ideal, not a shrink to it.
///
/// **Why not `.fixedSize()`.** It would make a control rigid by shrinking it
/// to its ideal, which visibly changes every picker that today stretches to
/// fill its row. A floor keeps the stretch and removes only the squeeze.
///
/// **Why the squeeze matters more than an overflow.** A compressed control
/// reports a small minimum, is shrunk inside its row and truncates its
/// labels, and NOTHING overflows, so no width measurement can see it. Once a
/// control cannot be compressed, squeezing it becomes overflow, and overflow
/// is what `BoundedView` measures.
///
/// **Which control kinds use it.** Only the segmented picker, on the premise
/// that some segmented pickers fill their row and shrinking them to their
/// ideal would be the visible change this work excludes. That premise is
/// OPEN: `RigidControlTests.aBareSegmentedPickerDoesNotGrowPastItsIdeal`
/// measures a bare segmented picker that reports its ideal at a 2000-pt
/// proposal and is drawn at its ideal, so on the OS that test ran on the floor
/// makes the control claim row width the bare control never claimed. A raw checkbox does
/// not stretch (it reports 101 pt at a 2000-pt proposal, see
/// `RigidControlTests.aBareCheckboxOrRadioGroupDoesNotStretch`), nor does a
/// radio group, so for those two the behaviour-preserving shape is rigid AT
/// the ideal with no stretch, and they use `.fixedSize()` instead.
///
/// **Not guarded by a test.** `placeSubviews` is guarded only for the origin
/// (`theSegmentedControlIsPlacedAtTheLeadingEdge`): the control does not grow
/// into the slot it is given, so a change to the proposal it is placed with
/// draws identically and no test sees it. `proposal.height` handling, and the
/// `.labelsHidden()` the components apply, are exercised by no test either:
/// removing any of these leaves the suite green.
struct AtLeastIdealWidth: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ideal = subviews[0].sizeThatFits(.unspecified)
        // Stacks probe for a maximum with an infinite proposal; answer with the
        // ideal rather than an infinite width.
        let offered = proposal.width.map { $0.isFinite ? $0 : ideal.width } ?? ideal.width
        let width = max(ideal.width, offered)
        return CGSize(
            width: width,
            height: subviews[0].sizeThatFits(
                ProposedViewSize(width: width, height: proposal.height)).height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

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
        AtLeastIdealWidth {
            Picker(accessibilityLabel, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

/// A radio group that cannot be compressed below its ideal width. One radio
/// per case of `Value`; `label` turns a case into the text beside it.
///
/// Rigid AT the ideal, with no stretch: a raw radio group reports less than
/// 2000 pt at a 2000-pt proposal, so stretching it would change the layout
/// rather than preserve it. See `AtLeastIdealWidth` for the segmented
/// picker, which does stretch.
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
/// Rigid AT the ideal, with no stretch: a raw checkbox reports 101 pt at a
/// 2000-pt proposal (measured by the Task 8 review), so stretching it would
/// move the neighbours in an `HStack` and flip a `Spacer()` layout, which is
/// the change rather than its preservation.
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
