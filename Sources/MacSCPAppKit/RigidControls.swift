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
struct AtLeastIdealWidth: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ideal = subviews[0].sizeThatFits(.unspecified)
        let width = max(ideal.width, proposal.width ?? ideal.width)
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
        AtLeastIdealWidth {
            Picker(accessibilityLabel, selection: selection) {
                ForEach(Array(Value.allCases), id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }
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
        AtLeastIdealWidth {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)
        }
    }
}
