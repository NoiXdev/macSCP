import SwiftUI
import macSCPCore

/// Shared name-entry sheet for Rename and New Folder (M7b). `onConfirm`
/// returns nil on success (sheet closes) or a localized error message
/// (shown inline, sheet stays open).
struct NameEntrySheet: View {
    let title: String
    let confirmLabel: String
    let initialName: String
    let onConfirm: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(title, text: $name, prompt: nil)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .disabled(isWorking)
                .onSubmit { confirm() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(.polished)
                    .disabled(isWorking)
                Button(confirmLabel) { confirm() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !RemoteBrowserViewModel.isValidEntryName(name))
            }
        }
        .padding(20)
        .onAppear { name = initialName }
    }

    private func confirm() {
        guard RemoteBrowserViewModel.isValidEntryName(name), !isWorking else { return }
        isWorking = true
        let candidate = name
        Task { @MainActor in
            let error = await onConfirm(candidate)
            isWorking = false
            if let error { errorMessage = error } else { dismiss() }
        }
    }
}

/// Info & permissions sheet (M7b): metadata block plus the rwx grid and
/// octal field bound through `PosixPermissions`. Never offered for
/// symlinks (the menu model excludes them — chmod follows links).
struct InfoPermissionsSheet: View {
    let item: RemoteFileItem
    let onApply: (UInt32) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var permissions = PosixPermissions(rawValue: 0)
    @State private var octalText = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var hasPermissions: Bool { item.permissions != nil }

    /// The octal field's parse state gates Apply (T3 review): while the
    /// user types an invalid intermediate value, `permissions` keeps the
    /// last good parse — committing that silently would apply something
    /// other than what the field shows.
    private var octalIsValid: Bool { PosixPermissions(octalString: octalText) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                infoRow(L10n.string("info.path", "Path"), item.path)
                infoRow(L10n.string("info.kind", "Kind"), kindLabel)
                infoRow(L10n.string("info.size", "Size"), FileListFormatter.sizeString(for: item))
                infoRow(L10n.string("info.modified", "Modified"), FileListFormatter.dateString(for: item))
            }
            Divider()
            Text(L10n.string("info.permissions", "Permissions"))
                .font(.system(size: 12, weight: .semibold))
            if hasPermissions {
                permissionsGrid
                HStack(spacing: 8) {
                    Text(L10n.string("info.octal", "Octal"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.inkSecondary)
                    // Typing NEVER echoes a reformatted value back into the
                    // field (T3 review: the zero-padded echo corrupted
                    // digit-by-digit entry) — the field only updates the
                    // grid; the grid's toggles write the field explicitly.
                    TextField("", text: $octalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: octalText) { _, newValue in
                            if let parsed = PosixPermissions(octalString: newValue) {
                                permissions = parsed
                            }
                        }
                    if !octalIsValid {
                        Text(L10n.string("info.octalInvalid", "Invalid octal value"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Text(L10n.string(
                    "info.permissionsUnavailable",
                    "Permissions are not available for this entry."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.string("common.close", "Close"), role: .cancel) { dismiss() }
                    .buttonStyle(.polished)
                    .disabled(isWorking)
                if hasPermissions {
                    Button(L10n.string("common.apply", "Apply")) { apply() }
                        .buttonStyle(.polishedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !octalIsValid)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear {
            permissions = PosixPermissions(rawValue: item.permissions ?? 0)
            octalText = permissions.octalString
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .directory: return L10n.string("info.kind.directory", "Folder")
        case .file: return L10n.string("info.kind.file", "File")
        case .symlink: return L10n.string("info.kind.symlink", "Symbolic link")
        case .other: return L10n.string("info.kind.other", "Other")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(DesignTokens.inkSecondary)
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private var permissionsGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text(L10n.string("info.perm.read", "Read"))
                Text(L10n.string("info.perm.write", "Write"))
                Text(L10n.string("info.perm.execute", "Execute"))
            }
            .font(.system(size: 11, weight: .semibold))
            permissionRow(L10n.string("info.perm.owner", "Owner"), .owner)
            permissionRow(L10n.string("info.perm.group", "Group"), .group)
            permissionRow(L10n.string("info.perm.other", "Others"), .other)
        }
    }

    private func permissionRow(_ label: String, _ c: PosixPermissions.Class) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).gridColumnAlignment(.leading)
            ForEach([PosixPermissions.Right.read, .write, .execute], id: \.self) { right in
                Toggle("", isOn: Binding(
                    get: { permissions[c, right] },
                    set: {
                        permissions[c, right] = $0
                        // Toggles write the octal field explicitly — there
                        // is deliberately no permissions→octalText echo,
                        // so typing in the field is never reformatted.
                        octalText = permissions.octalString
                    }
                ))
                .labelsHidden()
                .disabled(isWorking)
            }
        }
    }

    private func apply() {
        guard !isWorking else { return }
        isWorking = true
        let value = permissions.rawValue
        Task { @MainActor in
            let error = await onApply(value)
            isWorking = false
            if let error { errorMessage = error } else { dismiss() }
        }
    }
}
