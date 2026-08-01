import AppKit
import SwiftUI
import macSCPCore

/// Share-link sheet (M14/T5): generates a presigned GET/PUT URL for a single
/// S3 object. Opened from the remote pane's "Share Link…" context-menu entry
/// (`ContentView`'s `presignedSheetItem`), for S3 sessions only — the entry
/// only ever appears when the selected file's backend conforms to
/// `PresignedURLProvider` (see `BackendDescriptor.s3Descriptor.fileActions`).
///
/// The generated URL is clipboard-only: it is never logged, persisted, or
/// surfaced in `errorText` — only ever assigned to `generatedURL`, which
/// feeds the read-only field and the "Copy" button below.
struct PresignedURLSheet: View {
    let itemKey: String
    let provider: any PresignedURLProvider

    @Environment(\.dismiss) private var dismiss

    @State private var method: PresignedMethod = .get
    /// Pre-filled from `settingsStore.presignedDefaultExpiry` at presentation
    /// time (see `init` below); the picker below lets the user override it
    /// per link without touching the setting itself.
    @State private var expiry: PresignedExpiry
    /// The object key a PUT link is signed for — editable (unlike the GET
    /// path, which always signs `itemKey`), defaulting to `itemKey` so the
    /// common case ("share/overwrite the file I right-clicked") needs no
    /// typing.
    @State private var targetKey: String
    @State private var generatedURL: String?
    @State private var errorText: String?
    /// Transient "Copied" note next to the Copy button — cleared whenever a
    /// new link is generated or the method/target changes, so it never lies
    /// about a link the user is no longer looking at.
    @State private var showCopiedNote = false

    init(itemKey: String, provider: any PresignedURLProvider, settingsStore: SettingsStore) {
        self.itemKey = itemKey
        self.provider = provider
        _expiry = State(initialValue: settingsStore.presignedDefaultExpiry)
        _targetKey = State(initialValue: itemKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("presigned.sheet.title", "Share Link")).font(.headline)

            Picker("", selection: $method) {
                Text(L10n.string("presigned.method.get", "Download (GET)")).tag(PresignedMethod.get)
                Text(L10n.string("presigned.method.put", "Upload (PUT)")).tag(PresignedMethod.put)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: method) { _, _ in resetOutput() }

            Picker(L10n.string("presigned.expiry.label", "Expires after"), selection: $expiry) {
                ForEach(PresignedExpiry.allCases, id: \.self) { candidate in
                    Text(expiryLabel(candidate)).tag(candidate)
                }
            }
            .onChange(of: expiry) { _, _ in resetOutput() }

            if method == .put {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L10n.string("presigned.put.targetKey", "Target key"), text: $targetKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: targetKey) { _, _ in resetOutput() }
                    Text(L10n.string(
                        "presigned.put.overwriteWarning",
                        "Anyone with this link can overwrite this key until it expires."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(itemKey)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            if let generatedURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("presigned.url.label", "Link"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(generatedURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button(L10n.string("presigned.copy", "Copy")) { copyToPasteboard(generatedURL) }
                            .buttonStyle(.polished)
                        if showCopiedNote {
                            Text(L10n.string("presigned.copied", "Copied"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("presigned.generate", "Generate")) { generate() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(method == .put && targetKey.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func expiryLabel(_ expiry: PresignedExpiry) -> String {
        switch expiry {
        case .fifteenMinutes: return L10n.string("presigned.expiry.15min", "15 Minutes")
        case .oneHour: return L10n.string("presigned.expiry.1h", "1 Hour")
        case .oneDay: return L10n.string("presigned.expiry.1d", "1 Day")
        case .sevenDays: return L10n.string("presigned.expiry.7d", "7 Days")
        }
    }

    /// Clears any previously generated link/error whenever an input that
    /// would change the next `generate()` result changes — otherwise a
    /// stale URL from a different method/expiry/key would sit on screen
    /// looking current.
    private func resetOutput() {
        generatedURL = nil
        errorText = nil
        showCopiedNote = false
    }

    private func generate() {
        do {
            let key = method == .put ? targetKey : itemKey
            let url = try provider.presignedURL(method: method, key: key, expiresIn: expiry.seconds)
            generatedURL = url.absoluteString
            errorText = nil
        } catch {
            // Never surface the underlying error (or any URL/key material)
            // here — a fixed, generic message only.
            generatedURL = nil
            errorText = L10n.string("presigned.error", "Couldn't create the link.")
        }
        showCopiedNote = false
    }

    /// Clipboard-only output (spec constraint): the link is never logged or
    /// persisted anywhere else.
    private func copyToPasteboard(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showCopiedNote = true
    }
}
