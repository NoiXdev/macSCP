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

    /// A CORS sheet in the text pane over `text`, which the fields cannot all
    /// show: the form-off states of `BucketCORSSheet`, each a different
    /// sentence on screen.
    static func corsModel(text: String) -> BucketCORSModel {
        let model = BucketCORSModel(rules: [])
        model.text = text
        model.pane = .text
        return model
    }

    /// How many characters of the widest letter an overlong name or method has.
    ///
    /// **What it must beat.** It exists so that taking the clip off a sentence
    /// makes the layout guard red. That happens when the unclipped text wraps
    /// onto enough extra lines to carry the state past the sheet's 620 pt, and
    /// the room there is is the state's headroom: 620 less 536 for the method
    /// entry, 84 pt. It
    /// is a property of the sheet's layout and says nothing about `nameLimit`,
    /// so the figure is a number of its own and not a multiple of the limit: a
    /// multiple would shrink if the limit were lowered while the headroom it
    /// has to overrun did not (decided 2026-10-20, fix round 3; the first
    /// version was `BucketCORSModel.nameLimit * 20`).
    ///
    /// **What was measured.** With the method's clip planted out
    /// (`scripts/mutation-probe --filter BoundedViewLayoutGuardTests`, the
    /// `String(format: line.text, Self.clipped(method))` plant of the commit
    /// message of 9ba2d1d2) the guard is GREEN at 120 characters, GREEN at 200,
    /// RED at 400 and RED at 800, each run through the probe with the fixture
    /// changed in the same `perl` (probes F120, F200, F400 and F800 of the
    /// commit that wrote this comment, which hold the exact commands). So the
    /// smallest length known to work is 400, and
    /// 800 is twice that and four times the longest known to fail. It is also
    /// longer than the 600 that took the sheet to 653 pt in the re-review.
    /// `theOverlongFixtureIsLongEnoughToCatchTheClip` pins the floor of 400.
    static let corsOverlongLength = 800

    /// `tag` followed by `corsOverlongLength` of the widest letter, so the entry
    /// measures what the clip lets through and goes red if the clip goes.
    static func corsOverlong(_ tag: String) -> String {
        tag + String(repeating: "W", count: corsOverlongLength)
    }

    /// Two CORS rules: the first with every field and all five methods, the
    /// second the plainest rule there is. Ordinary values, not invented long
    /// ones (see the note on what a state is chosen for, above).
    static let corsRules: [CORSRule] = [
        CORSRule(
            id: "website", allowedOrigins: ["https://app.example.com", "https://www.example.com"],
            allowedMethods: CORSRule.allowedMethodNames, allowedHeaders: ["*"],
            exposeHeaders: ["ETag", "x-amz-request-id"], maxAgeSeconds: 3000),
        CORSRule(
            id: nil, allowedOrigins: ["*"], allowedMethods: ["GET"], allowedHeaders: [],
            exposeHeaders: [], maxAgeSeconds: nil),
    ]

    /// The clock of the Object Lock entries: 2026-09-21.
    static let lockNow = Date(timeIntervalSince1970: 1_790_000_000)

    /// A date whose month is long in the languages that spell it out
    /// (28 September 2027, 23:59 in the time zone the test runs in).
    static let lockDate: Date =
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2027, month: 9, day: 28, hour: 23, minute: 59)) ?? lockNow

    static let lockTarget = ObjectLockTarget(bucket: "macscp-seed", key: "photos/2026/holiday.jpg")

    /// The bucket list a create-bucket sheet is handed. It is never read by
    /// the entries: each passes a model already in its state, and the listing
    /// is the argument the initialiser needs beside it.
    static let bucketListing = CreateBucketModel.Listing(
        names: ["macscp-seed", "macscp-second"], isKnown: true)

    /// The cache an Object Lock sheet is handed. It is never asked: the models
    /// handed in are already in their state.
    static var lockCache: ObjectLockStateCache {
        ObjectLockStateCache(settings: FakeBucketSettings())
    }

    /// A retention sheet in `mode`, over a file whose current retention is
    /// `current`, with the date far enough ahead to be a valid choice.
    static func lockModel(
        mode: RetentionMode, current: ObjectRetention? = nil
    ) -> ObjectLockModel {
        let model = ObjectLockModel(
            focus: .retention, bucketLock: .present,
            current: ObjectLockModel.Current(retention: current, legalHold: false),
            now: { lockNow })
        model.mode = mode
        model.retainUntil = lockDate
        return model
    }

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

            // Four states, because each carries sentences the others do not:
            // the never-versioned bucket the one-way-door warning and the
            // enable button, the enabled one the suspension warning about
            // cost (the longest text the sheet has) and the suspend button,
            // the suspended one its own state sentence and no warning, and a
            // refused read the red sentence alone. Every one is handed a
            // model already in its state, so no measurement waits on a read;
            // the capability is never called.
            BoundedViewEntry("a never-versioned bucket, with the one-way warning") {
                BucketVersioningSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketVersioningModel(current: .never))
            },
            BoundedViewEntry("an enabled bucket, with the suspension warning") {
                BucketVersioningSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketVersioningModel(current: .enabled))
            },
            BoundedViewEntry("a suspended bucket, offered enabling again") {
                BucketVersioningSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketVersioningModel(current: .suspended))
            },
            BoundedViewEntry("a bucket whose versioning could not be read") {
                BucketVersioningSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketVersioningModel(
                        loadFailure: BucketVersioningModel.deniedLine.text))
            },

            // Five states, because the sheet has two panes and the lines that
            // matter sit in different ones. The form with two rules, one of
            // them carrying every field, is the tallest realistic form and
            // the widest row (the five method boxes). The text pane is the
            // same configuration as the document. A configuration the fields
            // cannot show puts the longest notice on screen (the reason the
            // fields are off) beside the red sentence that blocks the save. A
            // rule with no method is the form with its red sentence. A refused
            // read is the sentence alone. Every model is handed in already in
            // its state, so no measurement waits on a read; the capability is
            // never called.
            BoundedViewEntry("CORS rules as fields, one rule with every field filled in") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketCORSModel(rules: Self.corsRules))
            },
            BoundedViewEntry("CORS rules as text") {
                let model = BucketCORSModel(rules: Self.corsRules)
                model.pane = .text
                return BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(), model: model)
            },
            BoundedViewEntry("a CORS configuration the fields cannot show") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketCORSModel(
                        loaded: BucketCORS(
                            rules: Self.corsRules,
                            rawBody: Data(
                                ("<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
                                    + "<AllowedMethod>GET</AllowedMethod><Unknown>x</Unknown>"
                                    + "</CORSRule></CORSConfiguration>").utf8))))
            },
            BoundedViewEntry("a CORS rule with no method, as fields") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketCORSModel(rules: [
                        CORSRule(
                            id: nil, allowedOrigins: ["https://app.example.com"],
                            allowedMethods: [], allowedHeaders: [], exposeHeaders: [],
                            maxAgeSeconds: nil)
                    ]))
            },
            // The form-off sentences, one entry each, because each is a different
            // string on screen and two of them quote the document (the element
            // names and the method). Those two are given text twenty times as
            // long as the sheet shows of it, see `corsOverlong`: what is measured
            // is what the clip lets through, and an entry that fed the clip text
            // it did not need to cut would stay green if the clip were taken out.
            BoundedViewEntry("CORS text with three overlong element names left out") {
                let extra = (1...3).map { "<\(Self.corsOverlong("E\($0)"))>x</\(Self.corsOverlong("E\($0)"))>" }
                    .joined()
                return BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: Self.corsModel(
                        text: "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
                            + "<AllowedMethod>GET</AllowedMethod>" + extra
                            + "</CORSRule></CORSConfiguration>"))
            },
            BoundedViewEntry("CORS text with an overlong method name") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: Self.corsModel(
                        text: "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
                            + "<AllowedMethod>" + Self.corsOverlong("") + "</AllowedMethod>"
                            + "</CORSRule></CORSConfiguration>"))
            },
            BoundedViewEntry("CORS text with a method outside the five") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: Self.corsModel(
                        text: "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
                            + "<AllowedMethod>FETCH</AllowedMethod>"
                            + "</CORSRule></CORSConfiguration>"))
            },
            BoundedViewEntry("CORS text with a value over several lines") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: Self.corsModel(
                        text: "<CORSConfiguration><CORSRule><AllowedOrigin>https://a.example\n"
                            + "https://b.example</AllowedOrigin><AllowedMethod>GET</AllowedMethod>"
                            + "</CORSRule></CORSConfiguration>"))
            },
            BoundedViewEntry("CORS text with a carriage return in a value") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: Self.corsModel(
                        text: "<CORSConfiguration><CORSRule><AllowedOrigin>a&#13;b</AllowedOrigin>"
                            + "<AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"))
            },
            BoundedViewEntry("CORS text that is not a readable configuration yet") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: Self.corsModel(text: "<CORSConfiguration><CORSRule>"))
            },
            BoundedViewEntry("a bucket whose CORS rules could not be read") {
                BucketCORSSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(),
                    model: BucketCORSModel(loadFailure: BucketCORSModel.deniedLine.text))
            },

            // Object Lock (Task 10). The states are chosen for the longest text
            // on screen, because the sheets are bounded in width and their
            // sentences wrap: COMPLIANCE is where the warning and the
            // acknowledgement sit together under the date, in a language whose
            // month is long; the bucket default's acknowledgement is the
            // longest sentence of all. A long file name is the title's limit,
            // and a bucket with no lock, a refused read and a legal hold are
            // the sentences that stand alone. Every model is handed in already
            // in its state, so no measurement waits on a read; the capability
            // is never called.
            BoundedViewEntry("a retention over a file with none, GOVERNANCE") {
                ObjectLockSheet(
                    focus: .retention, target: Self.lockTarget, settings: FakeBucketSettings(),
                    cache: Self.lockCache, model: Self.lockModel(mode: .governance))
            },
            BoundedViewEntry("a retention, COMPLIANCE chosen, with its warning and acknowledgement") {
                ObjectLockSheet(
                    focus: .retention, target: Self.lockTarget, settings: FakeBucketSettings(),
                    cache: Self.lockCache, model: Self.lockModel(mode: .compliance))
            },
            BoundedViewEntry("a retention, COMPLIANCE chosen, over a file that already has one") {
                ObjectLockSheet(
                    focus: .retention, target: Self.lockTarget, settings: FakeBucketSettings(),
                    cache: Self.lockCache,
                    model: Self.lockModel(
                        mode: .compliance,
                        current: ObjectRetention(mode: .compliance, retainUntil: Self.lockDate)))
            },
            BoundedViewEntry("a retention over a file whose name is very long") {
                ObjectLockSheet(
                    focus: .retention,
                    target: ObjectLockTarget(
                        bucket: "macscp-seed",
                        key: "photos/" + String(repeating: "W", count: 400) + ".jpg"),
                    settings: FakeBucketSettings(), cache: Self.lockCache,
                    model: Self.lockModel(mode: .governance))
            },
            BoundedViewEntry("a legal hold, offered to be placed") {
                let model = ObjectLockModel(
                    focus: .legalHold, bucketHasLock: true, now: { Self.lockNow })
                model.legalHold = true
                return ObjectLockSheet(
                    focus: .legalHold, target: Self.lockTarget, settings: FakeBucketSettings(),
                    cache: Self.lockCache, model: model)
            },
            BoundedViewEntry("a file in a bucket with no Object Lock") {
                ObjectLockSheet(
                    focus: .retention, target: Self.lockTarget, settings: FakeBucketSettings(),
                    cache: Self.lockCache,
                    model: ObjectLockModel(bucketHasLock: false, now: { Self.lockNow }))
            },
            BoundedViewEntry("an Object Lock read the store refused") {
                ObjectLockSheet(
                    focus: .retention, target: Self.lockTarget, settings: FakeBucketSettings(),
                    cache: Self.lockCache,
                    model: ObjectLockModel(
                        loadFailure: ObjectLockLines.denied.text, now: { Self.lockNow }))
            },
            BoundedViewEntry("a bucket default over a bucket with none, GOVERNANCE") {
                BucketObjectLockSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(), cache: Self.lockCache,
                    model: BucketObjectLockModel(
                        bucketHasLock: true, current: nil, now: { Self.lockNow }))
            },
            BoundedViewEntry("a bucket default, COMPLIANCE chosen, over a COMPLIANCE default") {
                let model = BucketObjectLockModel(
                    bucketHasLock: true, current: (days: 365, mode: .compliance),
                    now: { Self.lockNow })
                model.days = 3650
                return BucketObjectLockSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(), cache: Self.lockCache,
                    model: model)
            },
            BoundedViewEntry("a bucket default over a bucket with no Object Lock") {
                BucketObjectLockSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(), cache: Self.lockCache,
                    model: BucketObjectLockModel(
                        bucketHasLock: false, current: nil, now: { Self.lockNow }))
            },
            BoundedViewEntry("a bucket default whose lock could not be read") {
                BucketObjectLockSheet(
                    bucket: "macscp-seed", settings: FakeBucketSettings(), cache: Self.lockCache,
                    model: BucketObjectLockModel(
                        loadFailure: ObjectLockLines.denied.text, now: { Self.lockNow }))
            },

            // Seven states, because the sheet's tall and wide content sits in
            // different ones. Object Lock ticked is the tallest form: its
            // notes (the lock's own, in red, and the one saying versioning is
            // held on) and a valid name. A taken name, a character that is not
            // allowed (the one problem sentence with an argument) and a list
            // that was never read are the three red sentences under the name
            // field, one each because each is a different string on screen.
            // The two failures after a protected create are the longest
            // sentences the sheet has, and a made bucket is the plain
            // confirmation. Every model is handed in already in its state, so
            // no measurement waits on a request; the capability is never
            // called.
            BoundedViewEntry("a valid name with Object Lock chosen, over its notes") {
                let model = CreateBucketModel(existingNames: ["macscp-seed", "macscp-second"])
                model.name = "macscp-archive-2026"
                model.objectLock = true
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
            },
            BoundedViewEntry("a name already in the list") {
                let model = CreateBucketModel(existingNames: ["macscp-seed", "macscp-second"])
                model.name = "macscp-seed"
                model.versioning = true
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
            },
            BoundedViewEntry("a name with a character that is not allowed") {
                let model = CreateBucketModel(existingNames: ["macscp-seed"])
                model.name = "macscp_archive"
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
            },
            BoundedViewEntry("a list of buckets that was never read") {
                let model = CreateBucketModel(existingNames: [], listingIsKnown: false)
                model.name = "macscp-archive-2026"
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
            },
            BoundedViewEntry("a bucket made without the versioning that was asked for") {
                let model = CreateBucketModel(
                    existingNames: ["macscp-seed"],
                    outcome: .failed(
                        sentence: CreateBucketModel.createdIncompletelyLine(
                            bucket: "macscp-archive-2026"),
                        bucketMayExist: true),
                    name: "macscp-archive-2026")
                model.objectLock = true
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
            },
            BoundedViewEntry("a create that may have left a bucket behind") {
                let model = CreateBucketModel(
                    existingNames: ["macscp-seed"],
                    outcome: .failed(
                        sentence: CreateBucketModel.mayExistLine.text, bucketMayExist: true),
                    name: "macscp-archive-2026")
                model.objectLock = true
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
            },
            BoundedViewEntry("a bucket that was made") {
                let model = CreateBucketModel(
                    existingNames: ["macscp-seed"], outcome: .created, name: "macscp-archive-2026")
                return CreateBucketSheet(
                    settings: FakeBucketSettings(), listing: Self.bucketListing, model: model)
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
