import SwiftUI
import macSCPCore

/// One `PreviewRow` as four columns of text (design §4). Kept apart from the
/// view below because a SwiftUI body is not testable in this project and
/// this is the part worth testing: every status has a line of its own, and
/// the mapper switches over `PreviewStatus` exhaustively, so a sixth status
/// in Core is a compile error here rather than a row that draws nothing.
enum ImportPreviewPresentation {
    /// The name column: what the source called it, else the host, else the
    /// file — the last is what an unreadable bookmark has instead of both
    /// (design §5 asks for the file name on that row).
    static func name(for bookmark: ExternalBookmark) -> String {
        if let nickname = bookmark.nickname, !nickname.isEmpty { return nickname }
        return bookmark.host.isEmpty ? bookmark.fileName : bookmark.host
    }

    /// The protocol badge. For the two protocols macSCP speaks it is the
    /// backend's OWN badge — the same text the sidebar and the tab strip
    /// put on a session of that kind, rather than a second spelling of it
    /// here. A protocol macSCP has no backend for has no descriptor to read
    /// from, so the source's own name is shown as the source wrote it.
    static func badge(for bookmark: ExternalBookmark) -> String {
        switch bookmark.protocol {
        case .sftp: return badge(for: .ssh)
        case .s3: return badge(for: .s3)
        case .unsupported(let name): return name.uppercased()
        }
    }

    private static func badge(for kind: ConnectionKind) -> String {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    /// The target column: `user@host:port` for a shell connection, endpoint
    /// and bucket for an S3 one. An S3 bookmark with an empty `Path` opens
    /// at the bucket list, which is a target too and says so.
    static func target(for bookmark: ExternalBookmark) -> String {
        switch bookmark.protocol {
        case .s3:
            let bucket = bookmark.path ?? ""
            return String(
                format: L10n.string("import.cyberduck.target.s3 %1$@ %2$@", "%1$@ · %2$@"),
                bookmark.host,
                bucket.isEmpty
                    ? L10n.string("import.cyberduck.target.allBuckets", "all buckets")
                    : bucket)
        case .sftp, .unsupported:
            var text = bookmark.host
            if let username = bookmark.username, !username.isEmpty {
                text = "\(username)@\(text)"
            }
            if let port = bookmark.port { text += ":\(port)" }
            return text
        }
    }

    /// The status column. `.knownChanged` spells out every field a re-import
    /// would overwrite, because that is the whole reason the row is offered
    /// rather than silently applied.
    static func statusText(for status: PreviewStatus) -> String {
        switch status {
        case .new:
            return L10n.string("import.cyberduck.status.new", "New")
        case .knownUnchanged:
            return L10n.string("import.cyberduck.status.unchanged", "Known, unchanged")
        case .knownChanged(_, let changes):
            return String(
                format: L10n.string("import.cyberduck.status.changed %@", "Changed: %@"),
                changeList(changes))
        case .unsupported:
            return L10n.string("import.cyberduck.status.unsupported", "Not supported yet")
        case .unreadable:
            return L10n.string("import.cyberduck.status.unreadable", "Not readable")
        }
    }

    /// The one row the design tints: a change is the only status the user
    /// has to read rather than recognise.
    static func isChange(_ status: PreviewStatus) -> Bool {
        if case .knownChanged = status { return true }
        return false
    }

    /// "port 22 → 2222, host a → b". The field NAME comes out of the catalog
    /// under the key Core composed (`ImportPreviewPlanner.FieldKey`); the
    /// fallback is the key's own last component, so a key added in Core
    /// before its catalog entry reads as `port` rather than as nothing.
    private static func changeList(_ changes: [FieldChange]) -> String {
        changes.map { change in
            String(
                format: L10n.string(
                    "import.cyberduck.change %1$@ %2$@ %3$@", "%1$@ %2$@ → %3$@"),
                fieldName(change.field), change.old, change.new)
        }
        .joined(separator: ", ")
    }

    private static func fieldName(_ key: String) -> String {
        L10n.string(key, String(key.split(separator: ".").last ?? Substring(key)))
    }
}

/// The import preview (design §4): every bookmark the source holds, with a
/// checkbox, a status and — for a changed one — what a re-import would
/// overwrite; the two switches; the group picker; and the summary line.
///
/// The model arrives already loaded. This view starts nothing when it
/// appears and reads no folder: `ContentView.beginExternalImport` does that
/// before presenting, which is what lets a missing default folder raise a
/// picker instead of an error inside a sheet.
struct ImportFromSourceSheet: View {
    @Bindable var model: ImportFromSourceViewModel
    /// The user pressed Import. The window dismisses the sheet and applies —
    /// planning cannot happen while this sheet is up, because the shared
    /// connection-conflict sheet may have to present.
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                format: L10n.string("import.cyberduck.title %@", "Import from %@"),
                model.sourceName))
                .font(.headline)

            if let loadError = model.loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
                Spacer(minLength: 0)
            } else if model.rows.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.string(
                    "import.cyberduck.empty", "No bookmarks were found in this folder."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                header
                List(model.rows) { row in
                    self.row(row)
                }
                switchesSection
                Text(summaryText).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("import.cyberduck.action", "Import")) { onImport() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
            }
        }
        .padding(20)
        .frame(width: 780, height: 540)
    }

    private var header: some View {
        HStack {
            Text(String(
                format: L10n.string("import.cyberduck.count %lld", "%lld bookmarks"),
                model.rows.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.string("import.cyberduck.selectAll", "Select All")) { model.selectAll() }
                .buttonStyle(.link)
            Button(L10n.string("import.cyberduck.selectNone", "Select None")) { model.selectNone() }
                .buttonStyle(.link)
        }
    }

    private func row(_ row: PreviewRow) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { row.selected },
                set: { _ in model.toggle(row: row) }))
                .labelsHidden()
                .disabled(!row.isSelectable)
            Text(ImportPreviewPresentation.name(for: row.bookmark))
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Text(ImportPreviewPresentation.badge(for: row.bookmark))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(ImportPreviewPresentation.target(for: row.bookmark))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)
                .lineLimit(1)
            Text(ImportPreviewPresentation.statusText(for: row.status))
                .font(.caption)
                .foregroundStyle(
                    ImportPreviewPresentation.isChange(row.status)
                        ? AnyShapeStyle(DesignTokens.remoteBlue)
                        : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .opacity(row.isSelectable ? 1 : 0.5)
    }

    private var switchesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $model.takeSecrets) {
                Text(L10n.string(
                    "import.cyberduck.takeSecrets",
                    "Take passwords and S3 secrets from the keychain (macOS asks per entry)"))
            }
            HStack(spacing: 8) {
                // "NEW sessions" is load-bearing, not padding: an update
                // keeps the group its stored record already has (the group is
                // a macSCP-side property the source knows nothing about),
                // while the labels half of the same line DOES apply to an
                // update. See `ImportFromSourceViewModel.takesGroupAndLabels`.
                Toggle(isOn: $model.takesGroupAndLabels) {
                    Text(L10n.string(
                        "import.cyberduck.takeGroupAndLabels",
                        "New sessions go into a group, labels as tags"))
                }
                Picker(
                    L10n.string("import.cyberduck.group", "Group"),
                    selection: $model.groupChoice
                ) {
                    ForEach(model.groupChoices, id: \.self) { choice in
                        Text(groupLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(!model.takesGroupAndLabels)
            }
        }
    }

    private func groupLabel(_ choice: ImportFromSourceViewModel.GroupChoice) -> String {
        guard let name = model.groupName(for: choice) else {
            return L10n.string("import.cyberduck.group.none", "No group")
        }
        if case .create = choice {
            return String(
                format: L10n.string("import.cyberduck.group.create %@", "New group “%@”"), name)
        }
        return name
    }

    private var summaryText: String {
        let summary = model.summary
        return String(
            format: L10n.string(
                "import.cyberduck.summary %1$lld %2$lld %3$lld %4$lld",
                "%1$lld to import, %2$lld of them updates · %3$lld skipped · %4$lld not supported"),
            summary.importing, summary.updating, summary.skipped, summary.unimportable)
    }
}
