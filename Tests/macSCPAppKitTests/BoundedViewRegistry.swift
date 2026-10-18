import AppKit
import Foundation
import SwiftUI
import macSCPCore

@testable import MacSCPAppKit

/// One view that bounds its own size, in one state, ready to be measured.
///
/// **Nothing here is spelled that can be read.** `typeName` and `bound` come
/// off the type the builder returns, so renaming a conformer or changing its
/// bound moves this entry with it and cannot leave a guard comparing against
/// a number that used to be true. The builder's return type is what fixes
/// both: an entry cannot be made to measure a stand-in, because the view it
/// renders IS the view whose name and bound it reports.
@MainActor
struct BoundedViewEntry {
    /// The conforming type's own name, read from the type.
    let typeName: String
    /// What this entry puts on screen, in English, for a failure message.
    let stateName: String
    /// The bound the type declares.
    let bound: SheetBound
    /// The view, built fresh on every call.
    ///
    /// Built fresh because `LayoutMeasure` invokes it inside
    /// `L10n.$localeOverride.withValue`: a view constructed outside the
    /// override carries the process language's top-level labels into a
    /// measurement taken under it, silently and plausibly
    /// (`LayoutMeasureTests.buildingOutsideTheOverrideUnderMeasures`).
    let content: @MainActor () -> AnyView

    init<V: BoundedView>(_ stateName: String, _ build: @escaping @MainActor () -> V) {
        self.typeName = String(describing: V.self)
        self.stateName = stateName
        self.bound = V.bound
        self.content = { AnyView(build()) }
    }
}

/// Every `BoundedView` in `MacSCPAppKit`, paired with the state it is
/// measured in.
///
/// **What a state is chosen for.** Each entry puts that view's widest and
/// tallest *realistic* content up — a listing with rows rather than an empty
/// one, an error sentence shown rather than absent, a draft with its optional
/// sections present. Realistic is the operative word: the figure a
/// measurement returns is the longest unbreakable run in the content, so a
/// fixture carrying an invented 200-character path would report a width no
/// catalogue is responsible for and turn this registry into a generator of
/// reds about its own test data. What is being measured is the four
/// catalogues against a bound, so the data is ordinary and the text is the
/// variable.
///
/// A view gets two entries where it has an either/or branch with localized
/// text on both sides, and one otherwise.
///
/// `BoundedViewCoverageTests` holds this list to the `: BoundedView`
/// conformances in `Sources/`, so a view added there and not here is a
/// failure rather than a gap.
@MainActor
enum BoundedViewRegistry {
    static var all: [BoundedViewEntry] { valueInSheets + keySheets }

    // MARK: - Shared fixtures

    /// A store over the temporary directory: these sheets read it to render,
    /// and none of them is asked to write during a measurement.
    private static var temporaryDirectory: URL { FileManager.default.temporaryDirectory }

    static func fileActionEditor(existing: FileAction?) -> FileActionEditor {
        FileActionEditor(
            existing: existing,
            store: FileActionStore(directory: temporaryDirectory),
            onSaved: {})
    }

    private static func variable(
        _ name: String, _ kind: SnippetVariable.Kind, _ placement: SnippetVariable.Placement
    ) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name.capitalized, kind: kind, placement: placement,
            defaultValue: "", remembersLastValue: false)
    }

    /// The action the deleted `FileActionEditorLayoutGuardTests` used for its
    /// second draft: a declared variable of each kind and each placement, so
    /// the variable row's own pickers are on screen.
    private static var actionWithVariables: FileAction {
        FileAction(
            name: "Zip", command: "zip out.zip {{PATHS}} {{WHERE}}",
            variables: [
                variable("WHERE", .selection(["a", "b"]), .placeholder),
                variable("NOTE", .freeText, .environment),
            ],
            runsOn: [.remote, .local], perSelection: .onceWithEveryPath)
    }

    /// An action the planner accepts, which `actionWithVariables` is not:
    /// that one declares `NOTE` without placing it, which
    /// `FileActionTemplate.firstProblem` refuses — exactly why the editor
    /// shows it, and exactly why the confirmation sheet cannot. Planned with
    /// it, both of that sheet's entries rendered the same template refusal
    /// and measured identically in all four catalogues;
    /// `BoundedViewLayoutGuardTests.entriesOfOneTypeMeasureDifferentStates`
    /// is the check that now refuses that.
    private static var plannableAction: FileAction {
        FileAction(
            name: "Zip the selection", command: "zip archive.zip {{PATHS}} {{WHERE}}",
            variables: [variable("WHERE", .freeText, .placeholder)],
            runsOn: [.remote], perSelection: .onceWithEveryPath)
    }

    private static var twoFiles: [RemoteFileItem] {
        [
            RemoteFileItem(name: "report.txt", path: "/home/testuser/report.txt", kind: .file),
            RemoteFileItem(name: "notes.txt", path: "/home/testuser/notes.txt", kind: .file),
        ]
    }

    /// Never called: no measurement presses Generate. It exists because
    /// `PresignedURLSheet` takes a provider to render at all.
    private struct UnreachableProvider: PresignedURLProvider {
        func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws
            -> URL
        {
            throw CocoaError(.featureUnsupported)
        }
    }

    // MARK: - Pass 1: value-in, closures-out sheets

    /// Sheets built from plain values and callbacks, with no store, model or
    /// binding to stand up.
    private static var valueInSheets: [BoundedViewEntry] {
        [
            BoundedViewEntry("a snippet with a name and a command") {
                SnippetActionSheet(
                    snippet: Snippet(name: "Tail the log", command: "tail -f /var/log/syslog"),
                    onInsert: {}, onExecute: {}, onCancel: {})
            },

            // The refusal branch is the widest: it adds the red two-line
            // block, and "send anyway" is offered, which is the three-button
            // row rather than the two-button one. A multi-line command that
            // is inserted rather than executed, on a shell with no bracketed
            // paste, is what `SnippetSendPlanner` refuses.
            BoundedViewEntry("a refused multi-line insert, with send-anyway offered") {
                SnippetDryRunSheet(
                    snippetName: "Restart the service",
                    dryRun: SnippetDryRun.describing(
                        command: "systemctl restart nginx\nsystemctl status nginx",
                        variables: [], skipsPlacementCheck: false, values: [:],
                        execute: false, bracketedPaste: false),
                    onSendAnyway: {}, onClose: {})
            },

            // One declaration of each kind the field builder branches on,
            // including a selection with no options, whose own sentence is
            // the only localized text in that branch.
            BoundedViewEntry("one declaration of each kind, including a selection with no options") {
                SnippetVariablePromptSheet(
                    snippet: Snippet(
                        name: "Deploy", command: "deploy {{TARGET}} {{TAG}} {{EMPTY}}",
                        variables: [
                            variable("TARGET", .selection(["staging", "production"]), .placeholder),
                            variable("TAG", .freeText, .placeholder),
                            variable("EMPTY", .selection([]), .placeholder),
                        ]),
                    initialValues: [:], onConfirm: { _ in }, onCancel: {})
            },

            // Two states, because the two branches of `allowsSubfolder` share
            // no localized text: the folder choice carries the radio group
            // and the collision sentence, the compressed file carries its own
            // two captions and the plan's refusal sentence.
            BoundedViewEntry("a folder choice whose names already exist here") {
                ExtractDestinationSheet(
                    archiveName: "backup.tar.gz",
                    preview: ExtractPreview.make(
                        archiveName: "backup.tar.gz", format: .tarGz,
                        archiveEntries: ["backup/notes.txt", "backup/report.txt"],
                        namesInFolder: ["backup"]),
                    onExtract: { _ in }, onCancel: {})
            },
            BoundedViewEntry("a compressed file whose output name is taken") {
                ExtractDestinationSheet(
                    archiveName: "report.txt.gz",
                    preview: ExtractPreview.make(
                        archiveName: "report.txt.gz", format: .gz,
                        archiveEntries: nil, namesInFolder: ["report.txt"]),
                    onExtract: { _ in }, onCancel: {})
            },

            // Two states, for the same reason: the plan branch shows the
            // command list and the Run button, the refusal branch shows a
            // sentence neither of the others carries.
            BoundedViewEntry("a remote plan over two files") {
                FileActionConfirmSheet(
                    request: FileActionRequest(
                        action: plannableAction, selection: twoFiles,
                        outcome: FileActionPlanner.plan(
                            action: plannableAction, selection: twoFiles, side: .remote,
                            promptedValues: ["WHERE": "archive"])),
                    onRun: {}, onCancel: {})
            },
            BoundedViewEntry("a refused plan with nothing selected") {
                FileActionConfirmSheet(
                    request: FileActionRequest(
                        action: plannableAction, selection: [],
                        outcome: FileActionPlanner.plan(
                            action: plannableAction, selection: [], side: .remote)),
                    onRun: {}, onCancel: {})
            },

            // One state: `method` is this sheet's own `@State` and starts at
            // GET, so the PUT branch cannot be put on screen from outside.
            BoundedViewEntry("a download link for a stored key") {
                PresignedURLSheet(
                    itemKey: "exports/2026-10/report.txt",
                    provider: UnreachableProvider(),
                    settingsStore: SettingsStore(directory: temporaryDirectory))
            },

            // The two drafts the deleted `FileActionEditorLayoutGuardTests`
            // measured, unchanged: a new editor, and one whose variable row
            // has a declaration of each kind and each placement on screen.
            BoundedViewEntry("a new draft") { fileActionEditor(existing: nil) },
            BoundedViewEntry("a draft with a declaration of each kind") {
                fileActionEditor(existing: actionWithVariables)
            },
        ]
    }

    // MARK: - Pass 2: the key sheets

    /// A stored key with every field filled: the listing row shows its name,
    /// comment, type and fingerprint, and the rename sheet fills its two
    /// fields from it.
    private static var storedKey: ManagedKey {
        ManagedKey(
            name: "work laptop", comment: "testuser@workstation", type: .ed25519,
            fingerprint: "SHA256:0123456789abcdefghijklmnopqrstuvwxyzABCDEFG",
            publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 testuser@workstation",
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            hasPassphrase: true, fileName: "work-laptop")
    }

    private static var keyStore: ManagedKeyStore {
        ManagedKeyStore(directory: temporaryDirectory)
    }

    /// `SSHKeysSheet` and the five sheets it presents.
    ///
    /// **One state each, and the reason is a limit worth naming.** Every
    /// branch these six take beyond their first render is driven by their
    /// own `@State` — a failure message, a run in flight, a chosen key type,
    /// a loaded listing — which a constructor cannot reach. `SSHKeysSheet`
    /// in particular renders the empty listing its `@State` starts at, not a
    /// listing with rows, so the figures below are its chrome: its toolbar,
    /// its search field and its table headers. Widening that would mean
    /// giving these views a seam for their initial state, which is a change
    /// to `Sources/` that this task does not make.
    private static var keySheets: [BoundedViewEntry] {
        [
            BoundedViewEntry("the empty listing, with the toolbar and the search field") {
                SSHKeysSheet()
            },
            BoundedViewEntry("a fresh form, with the type choice on screen") {
                GenerateKeySheet(store: keyStore, onGenerated: { _ in })
            },
            BoundedViewEntry("a key file picked, with its name prefilled") {
                ImportKeySheet(
                    fileURL: temporaryDirectory.appendingPathComponent("id_ed25519"),
                    store: keyStore, onImported: { _, _ in })
            },
            BoundedViewEntry("a stored key's name and comment in the fields") {
                RenameKeySheet(key: storedKey, store: keyStore, onRenamed: {})
            },
            BoundedViewEntry("a stored key whose passphrase is being corrected") {
                CorrectKeyPassphraseSheet(key: storedKey, store: keyStore, onCorrected: {})
            },
            BoundedViewEntry("a stored key whose passphrase is being changed") {
                ChangeKeyPassphraseSheet(key: storedKey, store: keyStore, onChanged: { _ in })
            },
        ]
    }
}
