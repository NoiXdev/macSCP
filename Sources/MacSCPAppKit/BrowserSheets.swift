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
///
/// M11c/T3 adds an optional recursive path, directory items only: a
/// "apply to all enclosed items" switch reveals a same/separate mode
/// picker and (in separate mode) a SECOND, fully independent permissions
/// editor for directories, prefilled from `PosixPermissions.directoryDefault`.
/// The single-item path (switch off) is untouched byte-for-byte from M7b.
struct InfoPermissionsSheet: View {
    let item: RemoteFileItem
    let onApply: (UInt32) async -> String?
    /// Recursive walk entry point (M11c/T2's `applyPermissionsRecursively`),
    /// forwarded verbatim by `BrowserPane`. `progress` is called with the
    /// running tally after every entry the walk processes — potentially off
    /// the main actor (it is declared `@Sendable`), so this view always
    /// hops back to `@MainActor` before touching its own state from inside
    /// it (see `runRecursive` below).
    let onApplyRecursively: (
        _ filePermissions: UInt32,
        _ directoryPermissions: UInt32,
        _ progress: @escaping @Sendable (PermissionsTreeResult) -> Void
    ) async -> PermissionsTreeResult

    /// The procedure the checksum button asks for, from the settings.
    let checksumAlgorithm: ChecksumAlgorithm
    /// Whether this pane's backend can answer the checksum question at
    /// all. `false` does NOT produce a disabled button — it produces the
    /// sentence that says so, which is an answer where a greyed-out
    /// control is not.
    let supportsChecksum: Bool
    /// Asks for THIS file's checksum, once, on request. Never called on
    /// opening the sheet: a checksum reads the whole file on the far side,
    /// so it happens because somebody asked for it.
    let onComputeChecksum: @MainActor () async -> ChecksumRequestResult

    @Environment(\.dismiss) private var dismiss
    @State private var permissions = PosixPermissions(rawValue: 0)
    @State private var octalText = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    /// The answer to the one checksum request this sheet can make, once it
    /// is there. `nil` while nothing has been asked, which is the resting
    /// state: nothing is computed by opening the sheet.
    @State private var checksumResult: ChecksumRequestResult?
    /// Non-nil exactly while a checksum is being computed — the handle the
    /// Cancel button cancels, mirroring `recursiveTask` below.
    @State private var checksumTask: Task<Void, Never>?

    /// Whether the recursive grid(s) and the same/separate picker apply
    /// files and directories independently — visible only for directory
    /// items (spec §4.1). Off by default; the single-item path stays the
    /// pre-M11c default.
    @State private var applyRecursively = false
    private enum RecursiveMode { case same, separate }
    @State private var recursiveMode: RecursiveMode = .same
    /// Second, independent permissions editor (directories, "separate"
    /// mode only) — its own state, never shared with `permissions`/
    /// `octalText` above, so its octal field gets the identical one-way
    /// treatment without any risk of cross-talk between the two grids.
    @State private var directoryPermissions = PosixPermissions(rawValue: 0)
    @State private var directoryOctalText = ""
    /// Seeded once, the first time "separate" is picked, from
    /// `PosixPermissions.directoryDefault(from:)` applied to the file
    /// grid's CURRENT value at that moment. Left alone after that even if
    /// the user flips back to "same" and forward to "separate" again, so
    /// their edits to the directory grid are never silently discarded.
    @State private var directoryGridSeeded = false

    @State private var showRecursiveConfirmation = false
    /// Non-nil exactly while a recursive run is in flight — drives the
    /// live progress line, gates the Cancel button, and is what `cancel()`
    /// calls `.cancel()` on for cooperative cancellation.
    @State private var recursiveTask: Task<Void, Never>?
    @State private var recursiveProgress: PermissionsTreeResult?
    /// Set once the walk returns; unlike the single-item path, a recursive
    /// run does NOT auto-dismiss on completion (even success) — the result
    /// line is the whole point of showing it, so the sheet stays open
    /// until the user closes it themselves.
    @State private var recursiveResult: PermissionsTreeResult?

    private var hasPermissions: Bool { item.permissions != nil }

    /// The octal field's parse state gates Apply (T3 review): while the
    /// user types an invalid intermediate value, `permissions` keeps the
    /// last good parse — committing that silently would apply something
    /// other than what the field shows. The spec requires a 3–4 digit
    /// value; shorter prefixes still parse (so the grid tracks typing)
    /// but must not be applied — Return after a lone "6" would chmod 006.
    private var octalIsValid: Bool {
        (3...4).contains(octalText.count) && PosixPermissions(octalString: octalText) != nil
    }

    /// Same gate as `octalIsValid`, independently, for the directory grid.
    private var directoryOctalIsValid: Bool {
        (3...4).contains(directoryOctalText.count)
            && PosixPermissions(octalString: directoryOctalText) != nil
    }

    private var recursiveApplyDisabled: Bool {
        isWorking || !octalIsValid || (recursiveMode == .separate && !directoryOctalIsValid)
    }

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
                if applyRecursively && recursiveMode == .separate {
                    Text(L10n.string("info.recursive.filesLabel", "Files"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.inkSecondary)
                }
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
                        // Locked only during an actual recursive run, NOT
                        // during a plain single-item apply — the M7b field
                        // was never disabled during `isWorking` there, and
                        // spec §4.5 requires that path stay byte-for-byte
                        // unchanged.
                        .disabled(recursiveTask != nil)
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

                if item.kind == .directory {
                    Divider()
                    Toggle(
                        L10n.string("info.recursive.toggle", "Apply to all enclosed items"),
                        isOn: $applyRecursively
                    )
                    .disabled(isWorking)

                    if applyRecursively {
                        Picker("", selection: $recursiveMode) {
                            Text(L10n.string("info.recursive.same", "Same permissions"))
                                .tag(RecursiveMode.same)
                            Text(L10n.string("info.recursive.separate", "Separate"))
                                .tag(RecursiveMode.separate)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isWorking)
                        .onChange(of: recursiveMode) { _, newValue in
                            if newValue == .separate && !directoryGridSeeded {
                                let seeded = PosixPermissions.directoryDefault(from: permissions.rawValue)
                                directoryPermissions = PosixPermissions(rawValue: seeded)
                                directoryOctalText = directoryPermissions.octalString
                                directoryGridSeeded = true
                            }
                        }

                        if recursiveMode == .separate {
                            Text(L10n.string("info.recursive.directoriesLabel", "Folders"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignTokens.inkSecondary)
                            directoryPermissionsGrid
                            HStack(spacing: 8) {
                                Text(L10n.string("info.octal", "Octal"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(DesignTokens.inkSecondary)
                                // Independent one-way field, mirroring the
                                // file grid's field above — no echo back
                                // from `directoryPermissions` either.
                                TextField("", text: $directoryOctalText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                    .disabled(isWorking)
                                    .onChange(of: directoryOctalText) { _, newValue in
                                        if let parsed = PosixPermissions(octalString: newValue) {
                                            directoryPermissions = parsed
                                        }
                                    }
                                if !directoryOctalIsValid {
                                    Text(L10n.string("info.octalInvalid", "Invalid octal value"))
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            } else {
                Text(L10n.string(
                    "info.permissionsUnavailable",
                    "Permissions are not available for this entry."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            checksumSection
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if isWorking, recursiveTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("info.recursive.progressPrefix", "Applying…") + " " + countLine(recursiveProgress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("common.cancel", "Cancel")) { recursiveTask?.cancel() }
                        .buttonStyle(.polished)
                }
            }
            if let recursiveResult {
                VStack(alignment: .leading, spacing: 2) {
                    Text(countLine(recursiveResult)).font(.caption)
                    Text(L10n.string(
                        "info.recursive.skippedHint",
                        "Skipped items are symlinks, which are left untouched."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if recursiveResult.cancelled {
                        Text(L10n.string(
                            "info.recursive.cancelledHint",
                            "Cancelled — some items may not have been updated."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let firstErrorMessage = recursiveResult.firstErrorMessage {
                        Text(firstErrorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            HStack {
                Spacer()
                if isWorking, recursiveTask == nil { ProgressView().controlSize(.small) }
                Button(L10n.string("common.close", "Close"), role: .cancel) { dismiss() }
                    .buttonStyle(.polished)
                    .disabled(isWorking)
                if hasPermissions {
                    Button(applyRecursively
                        ? L10n.string("info.recursive.applyButton", "Apply Recursively")
                        : L10n.string("common.apply", "Apply")
                    ) {
                        if applyRecursively {
                            showRecursiveConfirmation = true
                        } else {
                            apply()
                        }
                    }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(applyRecursively ? recursiveApplyDisabled : (isWorking || !octalIsValid))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear {
            permissions = PosixPermissions(rawValue: item.permissions ?? 0)
            octalText = permissions.octalString
        }
        .alert(
            L10n.string("info.recursive.confirmTitle", "Apply Recursively?"),
            isPresented: $showRecursiveConfirmation
        ) {
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
            Button(L10n.string("info.recursive.applyButton", "Apply Recursively")) {
                runRecursive()
            }
        } message: {
            Text(String(format: L10n.string(
                "info.recursive.confirmMessage",
                "Apply permissions to every item inside %@? This cannot be undone."), item.path))
        }
    }

    /// The checksum block — files only, because a folder has no digest and
    /// a symlink never reaches this sheet at all (the menu model excludes
    /// it).
    ///
    /// Four branches, counted here, and not one of them is a disabled
    /// control: a backend that cannot answer SAYS so; a request in flight
    /// shows its progress with a way out; a result is shown with where it
    /// came from; and a file not yet asked about offers a button naming the
    /// procedure. Everything shown about a result comes out of
    /// `ChecksumResultView`, so the digest and the sentence about where it
    /// came from cannot be separated here.
    @ViewBuilder
    private var checksumSection: some View {
        if item.kind == .file {
            Divider()
            Text(L10n.string("info.checksum", "Checksum"))
                .font(.system(size: 12, weight: .semibold))
            if !supportsChecksum {
                ChecksumResultView(result: .unavailableOnThisConnection)
            } else if checksumTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("checksum.computing", "Computing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("common.cancel", "Cancel")) { checksumTask?.cancel() }
                        .buttonStyle(.polished)
                }
            } else if let checksumResult {
                ChecksumResultView(result: checksumResult)
                // A failure is about this ATTEMPT — a dropped connection, a
                // far side that answered nothing — so asking again is
                // offered. A value is not: the file has not changed under
                // the sheet, and a second identical digest says nothing.
                if case .failed = checksumResult { computeButton }
            } else {
                computeButton
            }
        }
    }

    private var computeButton: some View {
        Button(String(
            format: L10n.string("info.checksum.compute", "Compute %@"),
            checksumAlgorithm.displayName)
        ) { computeChecksum() }
            .buttonStyle(.polished)
    }

    /// Asks once, and records the answer only if it is one — see
    /// `ChecksumInterruption`, which is the same rule `ChecksumBatch`
    /// applies to a selection, in one place rather than two.
    private func computeChecksum() {
        guard checksumTask == nil else { return }
        checksumResult = nil
        checksumTask = Task { @MainActor in
            let result = await onComputeChecksum()
            if ChecksumInterruption.isWorthRecording(result, cancelled: Task.isCancelled) {
                checksumResult = result
            }
            checksumTask = nil
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

    /// The directory grid (M11c/T3, "separate" mode): structurally
    /// identical to `permissionsGrid`/`permissionRow` above but bound to
    /// `directoryPermissions`/`directoryOctalText` instead — a deliberate
    /// duplication rather than a shared parameterized helper, so the file
    /// grid's one-way octal behavior (the M7b review finding) can never be
    /// affected by anything this second grid does.
    private var directoryPermissionsGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text(L10n.string("info.perm.read", "Read"))
                Text(L10n.string("info.perm.write", "Write"))
                Text(L10n.string("info.perm.execute", "Execute"))
            }
            .font(.system(size: 11, weight: .semibold))
            directoryPermissionRow(L10n.string("info.perm.owner", "Owner"), .owner)
            directoryPermissionRow(L10n.string("info.perm.group", "Group"), .group)
            directoryPermissionRow(L10n.string("info.perm.other", "Others"), .other)
        }
    }

    private func directoryPermissionRow(_ label: String, _ c: PosixPermissions.Class) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).gridColumnAlignment(.leading)
            ForEach([PosixPermissions.Right.read, .write, .execute], id: \.self) { right in
                Toggle("", isOn: Binding(
                    get: { directoryPermissions[c, right] },
                    set: {
                        directoryPermissions[c, right] = $0
                        // Same one-way rule as the file grid: toggles push
                        // into the octal field, the field never echoes back.
                        directoryOctalText = directoryPermissions.octalString
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

    /// Formats a running or final tally per spec §4's literal string
    /// ("%lld changed, %lld skipped, %lld failed" / the German
    /// equivalent) — used for BOTH the live progress line and the final
    /// result line, since they show the same three counters.
    private func countLine(_ result: PermissionsTreeResult?) -> String {
        let r = result ?? PermissionsTreeResult()
        return String(format: L10n.string(
            "info.recursive.resultFormat", "%lld changed, %lld skipped, %lld failed"),
            Int64(r.changed), Int64(r.skippedSymlinks), Int64(r.failed))
    }

    /// Runs the recursive walk after the user confirms. `permissions`
    /// supplies the file value always; `directoryPermissions` supplies the
    /// directory value only in "separate" mode ("same" mode reuses the
    /// file value for both, per spec §4.2). The task is kept in
    /// `recursiveTask` so the Cancel button can cooperatively cancel it;
    /// the sheet does NOT auto-dismiss when the walk finishes — the result
    /// line stays visible until the user closes the sheet themselves.
    private func runRecursive() {
        guard !isWorking else { return }
        isWorking = true
        recursiveResult = nil
        recursiveProgress = PermissionsTreeResult()
        let filePermissions = permissions.rawValue
        let directoryValue = recursiveMode == .same ? filePermissions : directoryPermissions.rawValue
        recursiveTask = Task { @MainActor in
            let result = await onApplyRecursively(filePermissions, directoryValue) { partial in
                Task { @MainActor in
                    recursiveProgress = partial
                }
            }
            recursiveResult = result
            isWorking = false
            recursiveTask = nil
        }
    }
}
