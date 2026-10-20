import AppKit
import SwiftUI
import macSCPCore

/// What the CORS sheet knows and decides, apart from how it is drawn.
///
/// **The text is the source of truth, and the rules are what it says.** Two
/// panes show one configuration: fields for the common case and the document
/// itself. An edit in either rewrites the other, and the rules are always the
/// parse of the text (`S3SettingsXML.parseCORS`), so the two cannot disagree.
///
/// **The parse is lossy by construction** (`S3BucketSettings.cors(ofBucket:)`):
/// an element a rule has no field for is skipped. Saving the parsed rules would
/// drop it, and the form would never have shown it, so the model asks the
/// question the parse cannot answer for itself: does the text say anything the
/// rules do not? (`isLossless`.) If it does, the form switches itself off
/// and names what it cannot show, and nothing can be saved until the text
/// stops saying it. The spec (section 6.3) calls this the honest edge:
/// measured as near-unreachable, because the store refuses elements outside
/// the documented schema, and built because the alternative is a form that
/// silently rewrites a configuration it did not understand.
///
/// **Validation is macSCP's own.** The store accepts a method `FETCH`
/// (measured 2026-10-19), so `CORSRule.validate()` runs here on every rule and
/// a rule that fails is named and blocks the save before anything is sent.
///
/// The model talks to the capability (`S3BucketSettings`) through `read` and
/// `save`, both of which take the bucket as an argument: a connection started
/// at the account's bucket list has no single bucket of its own.
@MainActor
@Observable
final class BucketCORSModel {
    /// Where the sheet is: reading the bucket, showing its configuration, or
    /// showing why the read failed.
    enum Load: Equatable {
        case reading
        case ready
        case failed(String)
    }

    /// The two panes.
    enum Pane: Hashable {
        case form
        case text
    }

    private(set) var load: Load
    /// The pane the user chose. What is on screen is `visiblePane`.
    var pane: Pane = .form
    private var source: String
    /// The rules as the text says them: the last readable parse. While the
    /// text is not readable this is what it said when it last was.
    private(set) var rules: [CORSRule]
    /// The text parses as a CORS configuration.
    private(set) var isReadable = true
    /// The text says nothing the rules leave out (no element a rule has no
    /// field for, no field twice, no attribute): saving the rules loses
    /// nothing the text holds.
    private(set) var isLossless = true
    /// The fields can show the rules: the text is readable, lossless, and
    /// every value fits a one-line field and every method has a box.
    private(set) var formIsAvailable = true
    /// The first rule that fails `CORSRule.validate()`, or `nil`.
    private(set) var problem: CORSValidation?
    /// Which rule it is, counting from zero.
    private(set) var problemRuleIndex: Int?
    /// A write is in flight.
    private(set) var isSaving = false
    /// Why the last save was refused, as a sentence; `nil` after a save that
    /// succeeded, after an edit, or before any.
    private(set) var saveFailure: String?

    /// The rules the store holds, as last read or written. Compared with
    /// `rules` to tell whether there is anything to save.
    private var baselineRules: [CORSRule]
    /// The document the store sent said nothing its rules left out. When it
    /// did, tidying the document is a change even if the rules stay as they
    /// were.
    private var baselineWasLossless = true

    /// A sheet that has not read the bucket yet.
    init() {
        load = .reading
        source = Self.document(for: []) ?? ""
        rules = []
        baselineRules = []
        reanalyze()
    }

    /// A sheet showing `rules` as the stored configuration.
    init(rules: [CORSRule]) {
        load = .ready
        source = Self.document(for: rules) ?? ""
        self.rules = rules
        baselineRules = rules
        reanalyze()
        pane = formIsAvailable ? .form : .text
    }

    /// A sheet showing what `cors(ofBucket:)` answered: `nil` is a bucket with
    /// no configuration at all.
    init(loaded: BucketCORS?) {
        load = .ready
        source = ""
        rules = []
        baselineRules = []
        adopt(loaded)
    }

    /// A sheet whose read already failed with `loadFailure`.
    init(loadFailure: String) {
        load = .failed(loadFailure)
        source = Self.document(for: []) ?? ""
        rules = []
        baselineRules = []
        reanalyze()
    }

    // MARK: - The text

    /// The document as the user sees and edits it. Setting it re-reads it.
    var text: String {
        get { source }
        set {
            guard newValue != source else { return }
            source = newValue
            saveFailure = nil
            reanalyze()
        }
    }

    /// What the text says, as far as this model can tell.
    struct Reading: Sendable {
        let rules: [CORSRule]
        let isReadable: Bool
        let isLossless: Bool
    }

    /// Reads `text`: the rules it parses to, and whether those rules are all it
    /// says. The second is decided by counting: the element names (and
    /// attribute names) of the document against those of the document the
    /// rules write back out. A document that holds anything the rules do not
    /// has a different count, in whatever order its fields come.
    nonisolated static func read(_ text: String) -> Reading {
        let data = Data(text.utf8)
        guard let rules = try? S3SettingsXML.parseCORS(data) else {
            return Reading(rules: [], isReadable: false, isLossless: false)
        }
        guard let canonical = try? S3SettingsXML.corsBody(rules),
            let theirs = ElementCensus.of(data), let ours = ElementCensus.of(canonical)
        else { return Reading(rules: rules, isReadable: true, isLossless: false) }
        return Reading(rules: rules, isReadable: true, isLossless: theirs == ours)
    }

    /// The document the form's rules are shown as: the body the store would be
    /// sent, laid out one field to a line. Values are escaped by the same
    /// writer that builds the request, so what the text pane shows is what is
    /// sent, and no second serializer exists to disagree with it.
    ///
    /// `nil` when a value cannot be written as XML at all.
    nonisolated static func document(for rules: [CORSRule]) -> String? {
        guard let data = try? S3SettingsXML.corsBody(rules) else { return nil }
        var xml = String(decoding: data, as: UTF8.self)
        // Every `<` in a value is escaped, so these are tags and nothing else.
        xml = xml.replacingOccurrences(of: "?><CORSConfiguration", with: "?>\n<CORSConfiguration")
        xml = xml.replacingOccurrences(of: "<CORSRule>", with: "\n  <CORSRule>")
        for field in ["ID", "AllowedOrigin", "AllowedMethod", "AllowedHeader", "ExposeHeader", "MaxAgeSeconds"] {
            xml = xml.replacingOccurrences(of: "<\(field)>", with: "\n    <\(field)>")
        }
        xml = xml.replacingOccurrences(of: "</CORSRule>", with: "\n  </CORSRule>")
        xml = xml.replacingOccurrences(of: "</CORSConfiguration>", with: "\n</CORSConfiguration>")
        return xml
    }

    /// Whether the fields can show `rules`: every method has a box, and no
    /// value runs over more than one line.
    nonisolated static func formCanShow(_ rules: [CORSRule]) -> Bool {
        func oneLine(_ value: String) -> Bool { value.rangeOfCharacter(from: .newlines) == nil }
        for rule in rules {
            guard rule.id.map(oneLine) ?? true else { return false }
            let values = rule.allowedOrigins + rule.allowedHeaders + rule.exposeHeaders
            guard values.allSatisfy(oneLine) else { return false }
            guard rule.allowedMethods.allSatisfy(CORSRule.allowedMethodNames.contains) else {
                return false
            }
        }
        return true
    }

    private func reanalyze() {
        let reading = Self.read(source)
        isReadable = reading.isReadable
        isLossless = reading.isLossless
        if reading.isReadable { rules = reading.rules }
        formIsAvailable = reading.isReadable && reading.isLossless && Self.formCanShow(rules)
        problem = nil
        problemRuleIndex = nil
        if reading.isReadable {
            for (index, rule) in rules.enumerated() {
                let verdict = rule.validate()
                if verdict != .ok {
                    problem = verdict
                    problemRuleIndex = index
                    break
                }
            }
        }
    }

    /// Takes a configuration read from the store as the stored state, and
    /// shows it: as fields when the fields can show it, as the document the
    /// store sent when they cannot.
    private func adopt(_ loaded: BucketCORS?) {
        let loadedRules = loaded?.rules ?? []
        baselineRules = loadedRules
        let raw = loaded.map { String(decoding: $0.rawBody, as: UTF8.self) }
        let reading = raw.map(Self.read)
        baselineWasLossless = reading.map { $0.isReadable && $0.isLossless } ?? true
        if baselineWasLossless, Self.formCanShow(loadedRules),
            let tidy = Self.document(for: loadedRules)
        {
            source = tidy
        } else {
            source = raw ?? ""
        }
        rules = loadedRules
        load = .ready
        saveFailure = nil
        reanalyze()
        pane = formIsAvailable ? .form : .text
    }

    // MARK: - What is on screen

    /// The pane shown: the one chosen, unless that is the form and the form
    /// cannot show the configuration.
    var visiblePane: Pane { pane == .form && !formIsAvailable ? .text : pane }

    /// Switches pane. The form is not switched to while it is unavailable.
    func selectPane(_ target: Pane) {
        if target == .form && !formIsAvailable { return }
        pane = target
    }

    /// The catalogue key of the reason the form is off, or `nil` while it is
    /// on.
    var formUnavailableReasonKey: String? { formUnavailableLine?.key }

    var formUnavailableLine: CatalogueLine? {
        if formIsAvailable { return nil }
        return isReadable ? Self.formCannotShowThisLine : Self.formNeedsReadableTextLine
    }

    // MARK: - Editing through the fields

    /// Changes rule `index` through `change` and rewrites the text. Dropped
    /// when the fields are off or there is no such rule.
    func edit(ruleAt index: Int, _ change: (inout CORSRule) -> Void) {
        guard formIsAvailable, rules.indices.contains(index) else { return }
        var rule = rules[index]
        change(&rule)
        replaceRule(at: index, with: rule)
    }

    /// Replaces rule `index` with `rule` and rewrites the text.
    func replaceRule(at index: Int, with rule: CORSRule) {
        guard formIsAvailable, rules.indices.contains(index) else { return }
        var next = rules
        next[index] = rule
        commit(next)
    }

    /// Appends a rule that allows `GET` and names no origin yet.
    func addRule() {
        guard formIsAvailable else { return }
        commit(
            rules + [
                CORSRule(
                    id: nil, allowedOrigins: [""], allowedMethods: ["GET"], allowedHeaders: [],
                    exposeHeaders: [], maxAgeSeconds: nil)
            ])
    }

    func removeRule(at index: Int) {
        guard formIsAvailable, rules.indices.contains(index) else { return }
        var next = rules
        next.remove(at: index)
        commit(next)
    }

    private func commit(_ next: [CORSRule]) {
        guard let written = Self.document(for: next) else { return }
        source = written
        saveFailure = nil
        reanalyze()
    }

    /// `methods` with `method` switched on or off, in the canonical order, so a
    /// checkbox does not reorder the other four.
    nonisolated static func methods(_ methods: [String], setting method: String, to on: Bool) -> [String] {
        var wanted = Set(methods)
        if on { wanted.insert(method) } else { wanted.remove(method) }
        return CORSRule.allowedMethodNames.filter(wanted.contains)
    }

    /// What the cache field says: a number of seconds, nothing (`.some(nil)`),
    /// or something that is neither (`nil`, which the field ignores).
    nonisolated static func maxAge(fromField field: String) -> Int?? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let seconds = Int(trimmed), seconds >= 0 else { return nil }
        return .some(seconds)
    }

    // MARK: - Saving

    /// There is something to save and nothing stands in the way.
    var canSave: Bool {
        load == .ready && isReadable && isLossless && problem == nil && isDirty && !isSaving
    }

    private var isDirty: Bool { rules != baselineRules || !baselineWasLossless }

    /// The bucket has no CORS configuration and the sheet is not adding one.
    var hasNoConfiguration: Bool {
        load == .ready && baselineRules.isEmpty && rules.isEmpty
    }

    /// Saving as it stands would remove the bucket's configuration: every rule
    /// has been taken away.
    var clearsTheConfiguration: Bool {
        load == .ready && isReadable && rules.isEmpty && !baselineRules.isEmpty
    }

    /// Reads `bucket`'s CORS configuration and shows it, or shows why it could
    /// not.
    func read(bucket: String, from settings: any S3BucketSettings) async {
        load = .reading
        do {
            adopt(try await settings.cors(ofBucket: bucket))
        } catch {
            load = .failed(Self.message(for: error, applying: false))
        }
    }

    /// Saves the rules to `bucket`, if the sheet is in a state that can be
    /// saved; anything else is dropped before a request exists.
    ///
    /// After a write the sheet shows what the store says now, read back, and
    /// not what was sent. If the read-back fails after the write succeeded the
    /// rules sent are taken as stored: the store accepted them.
    func save(bucket: String, via settings: any S3BucketSettings) async {
        guard canSave else { return }
        isSaving = true
        saveFailure = nil
        defer { isSaving = false }
        let sent = rules
        do {
            try await settings.setCORS(sent, ofBucket: bucket)
        } catch {
            saveFailure = Self.message(for: error, applying: true)
            return
        }
        do {
            adopt(try await settings.cors(ofBucket: bucket))
        } catch {
            baselineRules = sent
            baselineWasLossless = true
        }
    }

    /// The sentence for a failure.
    ///
    /// A finding carries no foreign text and says its own sentence, which is
    /// also how a rule refused before sending is told apart from an answer
    /// the store sent that could not be used. A missing permission has one of
    /// its own. Anything else is a fixed sentence: the error is NEVER quoted,
    /// because a `reason` can carry the endpoint the user typed, and that
    /// field takes `scheme://KEY:SECRET@host` as ordinary input.
    static func message(for error: any Error, applying: Bool) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            deniedLine.text
        default:
            (applying ? saveFailedLine : readFailedLine).text
        }
    }

    // MARK: - What the sheet says

    /// Why saving is not possible, as a sentence, or `nil`.
    var blockerLine: CatalogueLine? {
        if !isReadable { return Self.unreadableLine }
        if !isLossless { return Self.dropsSomethingLine }
        switch problem {
        case .noOrigin: return Self.noOriginLine
        case .noMethod: return Self.noMethodLine
        case .methodNotAllowed: return Self.methodLine
        case .ok, nil: return nil
        }
    }

    /// `blockerLine`, with the rule's number or the method's name in it.
    var blockerSentence: String? {
        guard let line = blockerLine else { return nil }
        if !isReadable || !isLossless { return line.text }
        switch problem {
        case .noOrigin?, .noMethod?:
            return String(format: line.text, (problemRuleIndex ?? 0) + 1)
        case .methodNotAllowed(let method)?:
            return String(format: line.text, method)
        default:
            return line.text
        }
    }

    static func ruleTitle(_ number: Int) -> String {
        String(format: ruleTitleLine.text, number)
    }

    /// The lines this model shows in its current state, other than the fixed
    /// ones.
    var lines: [CatalogueLine] {
        [
            formUnavailableLine, blockerLine,
            hasNoConfiguration ? Self.noneLine : nil,
            clearsTheConfiguration ? Self.clearsAllLine : nil,
        ].compactMap { $0 }
    }

    static let titleLine = CatalogueLine(
        key: "s3.cors.title %@", english: "CORS rules for “%@”")
    static let introLine = CatalogueLine(
        key: "s3.cors.intro",
        english: "CORS rules decide which websites may use this bucket's files from a browser.")
    static let readingLine = CatalogueLine(
        key: "s3.cors.reading", english: "Checking the bucket's CORS rules…")
    static let noneLine = CatalogueLine(
        key: "s3.cors.none",
        english: "This bucket has no CORS rules yet. Add one to let a website use its files.")
    static let clearsAllLine = CatalogueLine(
        key: "s3.cors.clearsAll",
        english: "Saving without any rules removes this bucket's CORS configuration.")
    static let paneLabelLine = CatalogueLine(key: "s3.cors.pane.label", english: "Show rules as")
    static let paneFormLine = CatalogueLine(key: "s3.cors.pane.form", english: "Fields")
    static let paneTextLine = CatalogueLine(key: "s3.cors.pane.text", english: "Text")
    static let textLabelLine = CatalogueLine(
        key: "s3.cors.text.label", english: "CORS configuration as text")
    static let formCannotShowThisLine = CatalogueLine(
        key: "s3.cors.formCannotShowThis",
        english:
            "The text holds something the fields cannot show: an element that is not part of a rule, a method other than GET, PUT, POST, DELETE or HEAD, or a value spread over several lines. Edit it as text.")
    static let formNeedsReadableTextLine = CatalogueLine(
        key: "s3.cors.formNeedsReadableText",
        english: "The fields are off until the text is a readable CORS configuration again.")
    static let unreadableLine = CatalogueLine(
        key: "s3.cors.problem.unreadable",
        english: "The text is not a readable CORS configuration yet, so it cannot be saved.")
    static let dropsSomethingLine = CatalogueLine(
        key: "s3.cors.problem.dropsSomething",
        english: "The text holds something a rule has no place for, and saving would drop it. Remove it to save.")
    static let noOriginLine = CatalogueLine(
        key: "s3.cors.problem.noOrigin %lld", english: "Rule %lld needs at least one allowed origin.")
    static let noMethodLine = CatalogueLine(
        key: "s3.cors.problem.noMethod %lld", english: "Rule %lld needs at least one allowed method.")
    static let methodLine = CatalogueLine(
        key: "s3.cors.problem.method %@",
        english: "“%@” is not a method that can be allowed. Use GET, PUT, POST, DELETE or HEAD.")
    static let ruleTitleLine = CatalogueLine(key: "s3.cors.rule.title %lld", english: "Rule %lld")
    static let idFieldLine = CatalogueLine(key: "s3.cors.field.id", english: "Name (optional)")
    static let originsFieldLine = CatalogueLine(
        key: "s3.cors.field.origins", english: "Allowed origins (* allows any website)")
    static let methodsFieldLine = CatalogueLine(
        key: "s3.cors.field.methods", english: "Allowed methods")
    static let allowedHeadersFieldLine = CatalogueLine(
        key: "s3.cors.field.allowedHeaders", english: "Allowed headers")
    static let exposeHeadersFieldLine = CatalogueLine(
        key: "s3.cors.field.exposeHeaders", english: "Exposed headers")
    static let maxAgeFieldLine = CatalogueLine(
        key: "s3.cors.field.maxAge", english: "Cache the answer for (seconds)")
    static let addRuleLine = CatalogueLine(key: "s3.cors.action.addRule", english: "Add Rule")
    static let removeRuleLine = CatalogueLine(
        key: "s3.cors.action.removeRule", english: "Remove Rule")
    static let addEntryLine = CatalogueLine(key: "s3.cors.action.addEntry", english: "Add")
    static let removeEntryLine = CatalogueLine(
        key: "s3.cors.action.removeEntry", english: "Remove")
    static let saveLine = CatalogueLine(key: "s3.cors.action.save", english: "Save")
    static let readFailedLine = CatalogueLine(
        key: "s3.cors.error.read", english: "The CORS rules of this bucket could not be read.")
    static let saveFailedLine = CatalogueLine(
        key: "s3.cors.error.apply", english: "The CORS rules of this bucket could not be saved.")
    static let deniedLine = CatalogueLine(
        key: "s3.cors.error.denied",
        english: "Your access key is not allowed to read or change the CORS rules of this bucket.")

    /// The lines that do not depend on the model's state.
    static let fixedLines: [CatalogueLine] = [
        titleLine, introLine, readingLine, paneLabelLine, paneFormLine, paneTextLine,
        textLabelLine, ruleTitleLine, idFieldLine, originsFieldLine, methodsFieldLine,
        allowedHeadersFieldLine, exposeHeadersFieldLine, maxAgeFieldLine, addRuleLine,
        removeRuleLine, addEntryLine, removeEntryLine, saveLine, readFailedLine, saveFailedLine,
        deniedLine,
    ]
}

/// The element and attribute names of an XML document, counted.
///
/// Two documents with the same census have the same elements, the same
/// nesting-insensitive multiset of names and the same attributes, whatever
/// the order of their fields. Namespace declarations are left out: the
/// document the store sends and the one this module writes both carry one,
/// and it says nothing about a rule.
private struct ElementCensus: Equatable {
    private let counts: [String: Int]

    static func of(_ data: Data) -> ElementCensus? {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return ElementCensus(counts: collector.counts)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        private(set) var counts: [String: Int] = [:]

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            counts[elementName, default: 0] += 1
            for name in attributeDict.keys where name != "xmlns" && !name.hasPrefix("xmlns:") {
                counts["\(elementName)@\(name)", default: 0] += 1
            }
        }
    }
}

/// The sheet behind the toolbar menu's "CORS Rules…" row: a bucket's CORS
/// rules as fields or as the document itself, with the one save.
///
/// The bucket and the capability are captured when the sheet opens
/// (`ContentView.BucketCORSSheetItem`), so it keeps talking to the file
/// system it was opened against.
struct BucketCORSSheet: BoundedView {
    /// The size `BucketCORSSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .size(width: 620, height: 620)

    /// The height of the pane under the control, in both panes. Fixed, and not
    /// left to grow, for two reasons: a sheet that grew with its rules would
    /// have no height to bound (the fields scroll, and so does the text), and
    /// `BoundedViewLayoutGuardTests` measures a bounded view as if nothing
    /// scrolled, so a pane that asked for its content's height would be
    /// measured at the height of every rule it holds.
    static let paneHeight: CGFloat = 320

    let bucket: String
    let settings: any S3BucketSettings

    @Environment(\.dismiss) private var dismiss
    @State private var model: BucketCORSModel

    /// `model` defaults to a sheet that has not read the bucket yet. The
    /// layout registry passes one already in a state, so a measurement does
    /// not wait for a read.
    init(
        bucket: String, settings: any S3BucketSettings,
        model: BucketCORSModel = BucketCORSModel()
    ) {
        self.bucket = bucket
        self.settings = settings
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: BucketCORSModel.titleLine.text, bucket))
                .font(.headline)

            content

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                if case .ready = model.load {
                    Button(BucketCORSModel.saveLine.text) {
                        Task { await model.save(bucket: bucket, via: settings) }
                    }
                    .buttonStyle(.polishedProminent)
                    .disabled(!model.canSave)
                }
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .task {
            if case .reading = model.load {
                await model.read(bucket: bucket, from: settings)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.load {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(BucketCORSModel.readingLine.text)
                    .foregroundStyle(.secondary)
            }
        case .failed(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            editor
        }
    }

    @ViewBuilder private var editor: some View {
        Text(BucketCORSModel.introLine.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        SegmentedChoice(
            BucketCORSModel.paneLabelLine.text,
            selection: Binding(
                get: { model.visiblePane }, set: { model.selectPane($0) }),
            options: [
                (BucketCORSModel.Pane.form, BucketCORSModel.paneFormLine.text),
                (BucketCORSModel.Pane.text, BucketCORSModel.paneTextLine.text),
            ])

        Group {
            switch model.visiblePane {
            case .form:
                CORSFormPane(model: model)
            case .text:
                CORSTextEditor(
                    text: Binding(get: { model.text }, set: { model.text = $0 }),
                    accessibilityLabel: BucketCORSModel.textLabelLine.text)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.paneHeight)
        .disabled(model.isSaving)

        VStack(alignment: .leading, spacing: 4) {
            if let reason = model.formUnavailableLine {
                notice(reason.text, color: .secondary)
            }
            if model.hasNoConfiguration {
                notice(BucketCORSModel.noneLine.text, color: .secondary)
            }
            if model.clearsTheConfiguration {
                notice(BucketCORSModel.clearsAllLine.text, color: .secondary)
            }
            if let blocker = model.blockerSentence {
                notice(blocker, color: .red)
            }
            if let failure = model.saveFailure {
                notice(failure, color: .red)
            }
        }
    }

    private func notice(_ sentence: String, color: Color) -> some View {
        Text(sentence)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The fields pane: one card per rule, and the button that adds another.
private struct CORSFormPane: View {
    let model: BucketCORSModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.rules.indices, id: \.self) { index in
                    CORSRuleCard(model: model, index: index)
                }
                Button(BucketCORSModel.addRuleLine.text) { model.addRule() }
                    .buttonStyle(.polished)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
    }
}

private struct CORSRuleCard: View {
    let model: BucketCORSModel
    let index: Int

    private var rule: CORSRule? { model.rules.indices.contains(index) ? model.rules[index] : nil }

    var body: some View {
        if let rule {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(BucketCORSModel.ruleTitle(index + 1))
                        .font(.subheadline.bold())
                    Spacer()
                    Button(BucketCORSModel.removeRuleLine.text) { model.removeRule(at: index) }
                        .buttonStyle(.polished)
                }

                labelled(BucketCORSModel.idFieldLine.text) {
                    TextField(
                        BucketCORSModel.idFieldLine.text,
                        text: Binding(
                            get: { rule.id ?? "" },
                            set: { newValue in
                                model.replaceRule(
                                    at: index,
                                    with: CORSRule(
                                        id: newValue.isEmpty ? nil : newValue,
                                        allowedOrigins: rule.allowedOrigins,
                                        allowedMethods: rule.allowedMethods,
                                        allowedHeaders: rule.allowedHeaders,
                                        exposeHeaders: rule.exposeHeaders,
                                        maxAgeSeconds: rule.maxAgeSeconds))
                            })
                    )
                    .textFieldStyle(.roundedBorder)
                }

                entries(BucketCORSModel.originsFieldLine.text, rule.allowedOrigins) { new in
                    model.edit(ruleAt: index) { $0.allowedOrigins = new }
                }

                labelled(BucketCORSModel.methodsFieldLine.text) {
                    HStack(spacing: 12) {
                        ForEach(CORSRule.allowedMethodNames, id: \.self) { method in
                            CheckboxRow(
                                method,
                                isOn: Binding(
                                    get: { rule.allowedMethods.contains(method) },
                                    set: { on in
                                        model.edit(ruleAt: index) {
                                            $0.allowedMethods = BucketCORSModel.methods(
                                                $0.allowedMethods, setting: method, to: on)
                                        }
                                    }))
                        }
                    }
                }

                entries(BucketCORSModel.allowedHeadersFieldLine.text, rule.allowedHeaders) { new in
                    model.edit(ruleAt: index) { $0.allowedHeaders = new }
                }
                entries(BucketCORSModel.exposeHeadersFieldLine.text, rule.exposeHeaders) { new in
                    model.edit(ruleAt: index) { $0.exposeHeaders = new }
                }

                labelled(BucketCORSModel.maxAgeFieldLine.text) {
                    TextField(
                        BucketCORSModel.maxAgeFieldLine.text,
                        text: Binding(
                            get: { rule.maxAgeSeconds.map(String.init) ?? "" },
                            set: { newValue in
                                if let parsed = BucketCORSModel.maxAge(fromField: newValue) {
                                    model.edit(ruleAt: index) { $0.maxAgeSeconds = parsed }
                                }
                            })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        }
    }

    private func labelled<Content: View>(
        _ label: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    /// A list of values, one field each, with a button to add another and one
    /// beside each field to take it away. A field holds exactly what was
    /// typed, so a value can be typed one character at a time.
    private func entries(
        _ label: String, _ values: [String], set: @escaping ([String]) -> Void
    ) -> some View {
        labelled(label) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.indices, id: \.self) { position in
                    HStack {
                        TextField(
                            label,
                            text: Binding(
                                get: { values.indices.contains(position) ? values[position] : "" },
                                set: { newValue in
                                    var next = values
                                    if next.indices.contains(position) {
                                        next[position] = newValue
                                        set(next)
                                    }
                                })
                        )
                        .textFieldStyle(.roundedBorder)
                        Button(BucketCORSModel.removeEntryLine.text) {
                            var next = values
                            if next.indices.contains(position) {
                                next.remove(at: position)
                                set(next)
                            }
                        }
                        .buttonStyle(.polished)
                    }
                }
                Button(BucketCORSModel.addEntryLine.text) { set(values + [""]) }
                    .buttonStyle(.polished)
            }
        }
    }
}

/// The text pane: a plain `NSTextView`, because the document is markup and a
/// text view left at the system default rewrites it as it is typed.
///
/// Smart quotes would turn the straight quotes of an attribute into curly
/// ones, smart dashes and text replacement change what was typed, and
/// spelling correction underlines every tag. All are switched off in
/// `makeNSView`; `BucketCORSSheetTests` reads this file for each of them. No
/// test in this project draws an `NSViewRepresentable`, so the rest (the
/// caret staying where it is while the binding changes) belongs in the
/// maintainer's visual check.
private struct CORSTextEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.string = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Compared before it is assigned: assigning the same string would move
        // the caret and the binding would loop.
        if textView.string != text { textView.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string { text.wrappedValue = textView.string }
        }
    }
}
