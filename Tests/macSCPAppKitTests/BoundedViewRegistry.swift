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
/// **`BoundedViewCoverageTests` holds this list to the conformances in
/// `Sources/`.** It is a set equality between the `typeName`s here and the
/// conforming types the blanked source of `MacSCPAppKit` declares, so a view
/// added there and not here, or listed here and no longer declared there, is
/// a red that names which side holds the extra type.
@MainActor
enum BoundedViewRegistry {
    static var all: [BoundedViewEntry] { valueInSheets + keySheets + listingSheets + cappedViews }

    // MARK: - States other tests must name

    /// The three states whose whole reason for being is that a particular
    /// section is on screen. `BoundedViewStateOnScreenTests` looks them up by
    /// these names and asserts the section really is there, so the name is
    /// read from here rather than spelled in two places.
    static let jumpHostState = "a new SSH connection through a jump host, entered by hand"
    static let collapsedDeclarationsState = "a stored snippet with tags and two declarations"
    static let openDeclarationsState = "a stored snippet whose declarations are open on a fault"

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

    // MARK: - Pass 3: the listing sheets and the two editors

    /// One path these stores read from, and it **does not exist**.
    ///
    /// Every store below is asked only to read, and every one of them answers
    /// an absent file with an empty result — which is the state these entries
    /// are measured in anyway, since `.onAppear` never runs under
    /// `sizeThatFits`. So no directory is created, and there is nothing to
    /// remove. A distinctive path component rather than `temporaryDirectory`
    /// itself, so that a `snippets.json` some other test left in `$TMPDIR`
    /// cannot be read as this registry's content.
    ///
    /// It was a `UUID`-named directory created per call until fix round 1 of
    /// 2026-10-18. A builder runs once per locale per test, so one filtered
    /// run of the guard left 138 of them behind: counted with
    /// `ls -d "$TMPDIR"/bounded-view-registry-* | wc -l`, 4428 before the run
    /// and 4566 after.
    private static var unwrittenDirectory: URL {
        temporaryDirectory.appendingPathComponent(
            "bounded-view-registry-unwritten", isDirectory: true)
    }

    /// `SessionListViewModel` reads its stores in `init`, so a view model
    /// over an empty directory is an empty one — which is the state
    /// `LoginSetsSheet` is measured in. See `listingSheets` for why.
    private static func emptySessionList() -> SessionListViewModel {
        let directory = unwrittenDirectory
        return SessionListViewModel(
            store: SessionStore(directory: directory), secrets: UnreachableSecretStore(),
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
    }

    /// Never called: no measurement asks for a secret. `SessionListViewModel`
    /// requires one to exist.
    private struct UnreachableSecretStore: SecretStore {
        func savePassword(_ password: String, for sessionID: UUID) throws {}
        func password(for sessionID: UUID) throws -> String? { nil }
        func deletePassword(for sessionID: UUID) throws {}
    }

    private static var storedSession: StoredSession {
        StoredSession(
            name: "staging", kind: .ssh,
            ssh: StoredSSHConfig(
                host: "staging.example.net", username: "deploy", authKind: .agent))
    }

    private static var snippetWithVariables: Snippet {
        Snippet(
            name: "Deploy a release", command: "deploy {{TARGET}} {{TAG}}",
            tags: ["deploy", "release"],
            variables: [
                variable("TARGET", .selection(["staging", "production"]), .placeholder),
                variable("TAG", .freeText, .placeholder),
            ])
    }

    /// A snippet whose two declarations share a name. A faulty declaration
    /// is drawn open and offers no fold control (`SnippetVariableFolding`),
    /// so this is the way to put an open declaration card on screen without
    /// a click: the kind picker, the remember checkbox and the allowed-values
    /// field are all on it.
    private static var snippetWithOpenDeclarations: Snippet {
        Snippet(
            name: "Deploy a release", command: "deploy {{TARGET}}",
            tags: [],
            variables: [
                variable("TARGET", .selection(["staging", "production"]), .placeholder),
                variable("TARGET", .freeText, .placeholder),
            ])
    }

    private static var changelog: [ChangelogRelease] {
        [
            ChangelogRelease(
                version: "1.6.0", date: "2026-10-01",
                sections: [
                    ChangelogRelease.Section(
                        title: "Features",
                        entries: [
                            .init(scope: "views", text: "every sheet states the width it grants"),
                            .init(scope: nil, text: "the transfer queue reports what it skipped"),
                        ]),
                    ChangelogRelease.Section(
                        title: "Bug Fixes",
                        entries: [.init(scope: "terminal", text: "a pasted command keeps its newlines")]),
                ]),
        ]
    }

    /// The sheets whose bound fixes both axes, plus the two editors those
    /// sheets present.
    ///
    /// **Eight of them are measured empty, and that is a property of the
    /// instrument rather than a choice.** `AuditLogSheet`,
    /// `FileActionsSheet`, `HiddenImportsSheet`, `KnownHostsSheet`,
    /// `LoginSetsSheet`, `ServerCertificatesSheet`, `SnippetsSheet` and
    /// `SSHKeysSheet` (pass 2) read their rows in `.onAppear`, and
    /// `NSHostingController.sizeThatFits` never appears a view:
    /// `aSheetThatLoadsItsRowsOnAppearIsMeasuredEmpty` measures a seeded
    /// store and an empty one and gets the same figure from both. So what
    /// these entries measure is each sheet's chrome and its empty-state
    /// sentence, and for seven of the nine that is not enough to call the
    /// sheet covered.
    ///
    /// **Corrected 2026-10-18.** The sentence above ended "— which, for
    /// `HiddenImportsSheet` and the others like it, IS the longest localized
    /// text the sheet ever shows." Nothing ever measured that, and for at
    /// least one of these sheets it is false: `KnownHostsSheet`'s row
    /// affordances (`knownHosts.copyFingerprint`, `knownHosts.remove`) and its
    /// two error sentences (`knownHosts.loadError %@`,
    /// `knownHosts.removeError %@`) are localized, are never rendered in the
    /// state this registry puts up, and nothing compares their width with the
    /// empty-state sentence's.
    ///
    /// What IS measured is the Task 6 review's classification. Two of the nine
    /// are genuinely covered: `AuditLogSheet`, whose minimum moves with the
    /// catalogue (157.5 / 157.5 / 202.5 / 207.5 of 640), and
    /// `HiddenImportsSheet`, the only entry on either axis whose HEIGHT moves
    /// with it (207 / 191 / 207 / 207 of 460). The other seven —
    /// `FileActionsSheet`, `ImportFromSourceSheet`, `KnownHostsSheet`,
    /// `LoginSetsSheet`, `ServerCertificatesSheet`, `SnippetsSheet` and
    /// `SSHKeysSheet` — report one width in all four catalogues and sit
    /// between 2.4x and 8.3x inside what their bound grants (`FileActionsSheet`
    /// 267.0 of 640, `ImportFromSourceSheet` 94.0 of 780). Measured 2026-10-18
    /// on Darwin 27.0.0 with
    /// `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests`.
    /// What the seven still buy is what that review said they buy: the rows the
    /// type-set equality needs, and a red if a later task narrows a bound below
    /// the chrome minimum.
    /// `ImportFromSourceSheet` is the ninth, for a different reason: its
    /// rows arrive through `await model.load(...)`, and an entry's builder
    /// is synchronous.
    ///
    /// The three that are NOT empty — `TagFilterSheet`, `WhatsNewSheet` and
    /// the two editors — take their content as plain inputs, so their
    /// entries put real rows up.
    private static var listingSheets: [BoundedViewEntry] {
        [
            BoundedViewEntry("a session's log, before its events are read") {
                AuditLogSheet(
                    session: storedSession, store: AuditLogStore(directory: unwrittenDirectory))
            },
            BoundedViewEntry("no stored actions, with the empty-state sentence") {
                FileActionsSheet(store: FileActionStore(directory: unwrittenDirectory))
            },
            BoundedViewEntry("nothing hidden, with the empty-state sentence") {
                HiddenImportsSheet(
                    store: HiddenImportStore(directory: unwrittenDirectory),
                    hosts: [
                        SSHConfigHost(
                            alias: "staging", hostName: "staging.example.net", user: "deploy",
                            port: 22, identityFile: nil)
                    ],
                    onChange: {})
            },
            BoundedViewEntry("a source chosen, before its bookmarks are read") {
                ImportFromSourceSheet(
                    model: ImportFromSourceViewModel(sessions: [storedSession], groups: []),
                    onImport: {})
            },
            BoundedViewEntry("no known hosts, with the facet bar and the search field") {
                KnownHostsSheet(store: KnownHostsStore(directory: unwrittenDirectory))
            },
            BoundedViewEntry("no stored logins, with the overflow menu and the search field") {
                LoginSetsSheet(sessionList: emptySessionList())
            },
            BoundedViewEntry("no trusted certificates, with the search field") {
                ServerCertificatesSheet(
                    store: TrustedCertificateStore(directory: unwrittenDirectory))
            },
            BoundedViewEntry("no stored snippets, with the tag filter and the search field") {
                SnippetsSheet(
                    store: SnippetStore(directory: unwrittenDirectory),
                    rememberedValue: { _, _ in nil })
            },

            // Content in, so these three really do put rows up.
            BoundedViewEntry("a release with two sections of entries") {
                WhatsNewSheet(currentVersion: "1.6.0", releases: changelog, onClose: {})
            },
            BoundedViewEntry("two tags selected, so the join choice is on screen") {
                TagFilterSheet(
                    tags: ["deploy", "production", "staging"],
                    filter: .constant(SidebarTagFilter(tags: ["deploy", "production"], join: .any)))
            },
            BoundedViewEntry("a new snippet") {
                SnippetEditorView(
                    existing: nil, allSnippets: [], store: SnippetStore(directory: unwrittenDirectory),
                    rememberedValue: { _, _ in nil }, onSaved: {})
            },
            BoundedViewEntry(collapsedDeclarationsState) {
                SnippetEditorView(
                    existing: snippetWithVariables, allSnippets: [snippetWithVariables],
                    store: SnippetStore(directory: unwrittenDirectory),
                    rememberedValue: { _, _ in nil }, onSaved: {})
            },
            BoundedViewEntry(openDeclarationsState) {
                SnippetEditorView(
                    existing: snippetWithOpenDeclarations,
                    allSnippets: [snippetWithOpenDeclarations],
                    store: SnippetStore(directory: unwrittenDirectory),
                    rememberedValue: { _, _ in nil }, onSaved: {})
            },
            BoundedViewEntry("a new login") {
                LoginSetEditorView(existing: nil, onSave: { _, _ in }, onCancel: {})
            },
            BoundedViewEntry("a stored login that authenticates with a key file") {
                LoginSetEditorView(
                    existing: LoginSet(
                        name: "deploy key", username: "deploy", authKind: .privateKey,
                        keyPath: "~/.ssh/id_ed25519"),
                    onSave: { _, _ in }, onCancel: {})
            },
        ]
    }

    // MARK: - Pass 4: the capped views

    /// The surface a failed connect shows with everything on it: dialed
    /// from a stored session (so Retry and Edit session are there) and with
    /// a key the remedy can convert (so Convert key and Copy command are
    /// too). Eight buttons in one row is what this view is widest in.
    private static var failureContentWithEveryAction: ConnectFailureContent {
        ConnectFailurePlan.content(
            hasStoredSession: true, remedy: .convertKey(path: "~/.ssh/id_rsa"))
    }

    /// The technical message, reachable only through `read(from:)` — the
    /// type's initializer is `fileprivate` so that nothing but the dialog
    /// can build one out of arbitrary text.
    private static var failureDetails: ConnectFailureDetailText? {
        ConnectFailureDetailText.read(
            from: .failed(
                message: "ssh: handshake failed: no matching host key algorithm",
                field: nil))
    }

    private static var hostKeyCandidate: HostKeyCandidate {
        HostKeyCandidate(
            host: "staging.example.net", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIGVzdGluZ2tleWZvcm1lYXN1cmVtZW50cw==")
    }

    private static var certificateCandidate: ServerCertificateCandidate {
        ServerCertificateCandidate(
            host: "s3.example.net", port: 443, derBase64: "MIIBITCBxaADAgECAgEB",
            subject: "CN=s3.example.net", issuer: "CN=Example Issuing CA",
            notAfter: Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// Never dialed: nothing in a measurement presses Connect.
    private static func connectionForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in
            fatalError("not exercised by a layout measurement — nothing here dials")
        })
    }

    /// The views whose bound is a cap, plus `TerminalSnippetPopover`.
    ///
    /// A cap is compared against its MAXIMUM: it clips there, so comparing
    /// against the minimum would pass every view always
    /// (`SheetBoundTests.aCapIsMeasuredAgainstItsMaximum`).
    private static var cappedViews: [BoundedViewEntry] {
        [
            BoundedViewEntry("a server's own refusal text, selectable") {
                ConnectFailureDetailsSheet(
                    title: failureContentWithEveryAction.detailsTitle,
                    details: failureDetails
                        ?? ConnectFailureDetailText.read(from: .failed(message: "", field: nil))!,
                    onClose: {})
            },
            BoundedViewEntry("a new SSH connection, with the schema's own fields") {
                ConnectionFormView(
                    viewModel: connectionForm(),
                    sessionList: emptySessionList(),
                    globalTerminalType: .default,
                    managedKeyStore: keyStore,
                    secretStore: UnreachableSecretStore(),
                    currentReconnectAttempt: { UUID() },
                    onConnected: { _, _ in })
            },
            BoundedViewEntry(jumpHostState) {
                let viewModel = connectionForm()
                viewModel.jumpEnabled = true
                return ConnectionFormView(
                    viewModel: viewModel,
                    sessionList: emptySessionList(),
                    globalTerminalType: .default,
                    managedKeyStore: keyStore,
                    secretStore: UnreachableSecretStore(),
                    currentReconnectAttempt: { UUID() },
                    onConnected: { _, _ in })
            },
            BoundedViewEntry("a probe that gave up on a known target") {
                LostConnectionView(
                    content: LostConnectionPlan.content(
                        reason: .probeGaveUp, targetIsKnown: true,
                        behaviour: .offerOnly, attempts: 3),
                    onReconnect: {}, onDismiss: {})
            },
            BoundedViewEntry("every action offered, with a key to convert") {
                ConnectFailureView(
                    content: failureContentWithEveryAction, details: failureDetails,
                    onRetry: {}, onEdit: {}, onEditSession: {}, onDiagnose: {},
                    onConvertKey: {}, onCopyCommand: {}, onClose: {})
            },
            BoundedViewEntry("a dial in flight, with its cancel button") {
                ConnectingAttemptView(onCancel: {})
            },
            BoundedViewEntry("an unknown host key, awaiting consent") {
                TunnelHostKeyPromptView(
                    candidate: hostKeyCandidate, onTrust: {}, onCancel: {})
            },
            BoundedViewEntry("an untrusted certificate, awaiting consent") {
                CertificatePromptView(
                    candidate: certificateCandidate, onTrust: {}, onCancel: {})
            },
            BoundedViewEntry("two tagged snippets, with the hover line") {
                TerminalSnippetPopover(
                    snippets: [snippetWithVariables, Snippet(
                        name: "Tail the log", command: "tail -f /var/log/syslog",
                        tags: ["ops"])],
                    supportsShell: true,
                    theme: TerminalThemePreset.default.theme,
                    onRunSnippet: { _, _ in },
                    isPresented: .constant(true),
                    searchText: .constant(""),
                    searchIsRegex: .constant(false),
                    selectedSnippetID: .constant(nil),
                    hoveredRow: .constant(nil),
                    previewPinnedRow: .constant(nil),
                    actionSheetSnippet: .constant(nil))
            },
        ]
    }
}
