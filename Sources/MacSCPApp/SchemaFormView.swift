import SwiftUI
import macSCPCore

/// Renders any backend's schema (M22). One view for every protocol: the
/// dispatcher this replaces had a hand-written section per backend, which is
/// why adding WebDAV in M21 meant touching six switch statements.
///
/// The App contributes exactly one thing -- `resolve`, which turns an
/// `OptionSource` into options -- because managed keys and login sets live in
/// stores Core cannot see. Everything else (which fields exist, which of them
/// are visible right now, what they are called) belongs to the schema and is
/// tested in Core; this view walks the result and holds no rules of its own.
///
/// Takes a LIST of schemas, never one. A backend declares two
/// (`connectionSchema` and `credentialSchema`), and taking a single one is
/// exactly how the credential rows vanished: once M22/T4-T5 moved S3's and
/// WebDAV's credentials into `credentialSchema`, a view reading only
/// `connectionSchema` silently stopped rendering them, and no new S3 or WebDAV
/// connection could be created at all. `SchemaConformance` cannot catch that --
/// it checks the UNION of a descriptor's schemas, which stays correct however
/// many the form actually reads -- and there is no App test target to catch it
/// either. A list makes "only one schema" unexpressible at the call site.
struct SchemaFormView: View {
    /// Rendered in order, each schema's presets first (see `presets`).
    let schemas: [ConnectionFieldSchema]
    @Binding var values: FieldValues
    /// The backend field enum's declared `namespace`, so a condition resolves
    /// against the owning backend and not a same-named field in another.
    let namespace: String
    let isEditMode: Bool
    let resolve: (OptionSource) -> [FieldOption]

    /// The provider preset currently shown. Real state, mirroring the M12 S3
    /// picker: without it the field would snap back to blank after each pick.
    /// Starts unset -- applying a preset is always the user's own act, so a
    /// freshly opened (or reopened) form never silently refills fields from
    /// whichever provider happens to be listed first.
    @State private var selectedPresetID: String = ""

    /// Every collected schema's presets. Only one schema in a backend carries
    /// any today, which is why a single `selectedPresetID` suffices; pooling
    /// them keeps that an observation rather than an assumption.
    private var presets: [ConnectionPreset] { schemas.flatMap(\.presets) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !presets.isEmpty { presetPicker }
            // The filter is Core's, and tested there.
            ForEach(Array(schemas.enumerated()), id: \.offset) { _, schema in
                ForEach(schema.visibleFields(in: values, namespace: namespace)) { field in
                    row(for: field)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for field: ConnectionField) -> some View {
        if let leafKind = field.kind.asLeafKind {
            leafRow(label: L10n.string(field.labelKey, field.labelDefault),
                    kind: leafKind, binding: binding(field.id))
        } else {
            // A nil `asLeafKind` means `.group` -- the one kind without a leaf
            // twin, and the only one that nests.
            GroupBox(label: Text(L10n.string(field.labelKey, field.labelDefault))) {
                VStack(alignment: .leading, spacing: 10) {
                    // `owner:`, not a namespace this view builds: Core
                    // qualifies it with the group's id, so a leaf's condition
                    // cannot be resolved against the top-level field of the
                    // same name from here. See `visibleLeaves`.
                    ForEach(ConnectionFieldSchema.visibleLeaves(
                        of: field, in: values, owner: namespace)) { leaf in
                        leafRow(label: L10n.string(leaf.labelKey, leaf.labelDefault),
                                kind: leaf.kind, binding: binding(field.id, leaf.id))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// One form row per leaf-shaped field. Exhaustive over `LeafField.Kind`
    /// with no default arm: a kind added later must be given a control here,
    /// not silently dropped.
    ///
    /// The control keeps its own title for VoiceOver -- `FormRow` hides its
    /// visible label from it (M6a) -- while `prompt:` stays empty so the title
    /// does not also surface as an in-field placeholder.
    @ViewBuilder
    private func leafRow(
        label: String, kind: LeafField.Kind, binding: Binding<String>
    ) -> some View {
        switch kind {
        case .text, .number:
            FormRow(label: label) {
                TextField(label, text: binding, prompt: Text(verbatim: ""))
            }
        case .secret:
            FormRow(label: label) {
                // In edit mode a stored secret is never read back out of the
                // Keychain to prefill the field; an empty field means "keep
                // the stored one", which the placeholder has to say out loud.
                SecureField(
                    label, text: binding,
                    prompt: isEditMode
                        ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                        : Text(verbatim: ""))
            }
        case .toggle:
            // A checkbox carries its own label (the house idiom since M12), so
            // the label column stays empty rather than putting a caption next
            // to an unlabeled box.
            FormRow(label: "") {
                Toggle(label, isOn: boolBinding(binding))
            }
        case .picker(let source):
            FormRow(label: label) {
                Picker(label, selection: binding) {
                    ForEach(resolve(source)) { option in
                        Text(optionLabel(option)).tag(option.id)
                    }
                }
                .labelsHidden()
            }
        }
    }

    /// Mirrors the M12 S3 preset picker: the selection is real state, and
    /// applying writes only the ids the preset actually names -- the fields it
    /// stays silent about keep whatever the user typed.
    private var presetPicker: some View {
        // Reuses the key both the S3 and the WebDAV sections already used; the
        // string is protocol-neutral even though the key name carries `s3`.
        let label = L10n.string("connection.s3.preset.label", "Provider preset")
        return FormRow(label: label) {
            Picker(label, selection: Binding(
                get: { selectedPresetID },
                set: { id in
                    selectedPresetID = id
                    guard let preset = presets.first(where: { $0.id == id })
                    else { return }
                    for (fieldID, value) in preset.values {
                        values.setRaw("\(namespace).\(fieldID)", to: value)
                    }
                }
            )) {
                // "—" is a pure symbol for "no preset applied", identical in
                // every locale, so it stays a literal rather than a catalog
                // key -- the same rule the "…" browse button follows.
                Text(verbatim: "—").tag("")
                ForEach(presets) { preset in
                    Text(L10n.string(preset.nameKey, preset.nameDefault)).tag(preset.id)
                }
            }
            .labelsHidden()
        }
    }

    /// A schema-declared option carries a catalog key. One resolved at runtime
    /// -- a managed key's name, a login set's -- has no key to carry and brings
    /// its display text along instead.
    private func optionLabel(_ option: FieldOption) -> String {
        option.labelKey.isEmpty
            ? option.labelDefault
            : L10n.string(option.labelKey, option.labelDefault)
    }

    /// Toggles round-trip through the same "true"/"false" strings
    /// `FieldValues`'s own boolean subscript writes, so a value set here and
    /// one written by a persistence adapter are the same value.
    private func boolBinding(_ binding: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue == "true" },
            set: { binding.wrappedValue = $0 ? "true" : "false" })
    }

    /// Reads and writes by full namespaced key -- the same key `FieldValues`'s
    /// typed subscripts build, which is what lets a form driven by id strings
    /// and a config factory driven by enum cases meet in the middle.
    private func binding(_ fieldID: String, _ leafID: String? = nil) -> Binding<String> {
        let key = leafID.map { "\(namespace).\(fieldID).\($0)" }
            ?? "\(namespace).\(fieldID)"
        return Binding(
            get: { values.raw[key] ?? "" },
            set: { values.setRaw(key, to: $0) })
    }
}
