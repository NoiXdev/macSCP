import AppKit
import Foundation
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The CORS sheet's decisions: what the two panes show, what blocks a save,
/// and what the sheet does when the form cannot show what the store holds.
///
/// No test in this project draws a SwiftUI view; these are the decisions the
/// view reads, the catalogue entries it looks its text up in, and scans of the
/// view's own source.
@Suite("Bucket CORS sheet")
struct BucketCORSSheetTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    private static func rule(
        id: String? = nil, origins: [String] = ["*"], methods: [String] = ["GET"],
        allowedHeaders: [String] = [], exposeHeaders: [String] = [], maxAge: Int? = nil
    ) -> CORSRule {
        CORSRule(
            id: id, allowedOrigins: origins, allowedMethods: methods,
            allowedHeaders: allowedHeaders, exposeHeaders: exposeHeaders, maxAgeSeconds: maxAge)
    }

    /// A document the form can show.
    private static let simpleDocument =
        "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"

    /// The same rule with an element `CORSRule` has no field for.
    private static let documentWithAnUnknownElement =
        "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>GET</AllowedMethod><Unknown>x</Unknown></CORSRule></CORSConfiguration>"

    // MARK: - The two panes show the same rules

    @MainActor @Test func theFormAndTheTextShowTheSameRules() throws {
        let model = BucketCORSModel(rules: [
            .init(
                id: "r", allowedOrigins: ["*"], allowedMethods: ["GET"], allowedHeaders: [],
                exposeHeaders: [], maxAgeSeconds: 60)
        ])
        #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == model.rules)
    }

    /// The same property over rules that exercise every field and the
    /// characters XML treats specially. Positive control: the text is not
    /// empty and holds one `CORSRule` per rule.
    @MainActor @Test func theTextCarriesEveryFieldOfEveryRuleAndEscapesWhatXMLReserves() throws {
        let rules = [
            Self.rule(
                id: "site & assets", origins: ["https://a.example", "https://b.example"],
                methods: ["GET", "PUT", "POST", "DELETE", "HEAD"], allowedHeaders: ["*"],
                exposeHeaders: ["ETag", "x-amz-<id>"], maxAge: 3000),
            Self.rule(origins: ["*"], methods: ["GET"]),
        ]
        let model = BucketCORSModel(rules: rules)
        let occurrences = model.text.components(separatedBy: "<CORSRule>").count - 1
        #expect(occurrences == rules.count)
        #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == rules)
    }

    @MainActor @Test func editingTheTextUpdatesTheRules() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.simpleDocument
        #expect(model.rules == [Self.rule()])
        #expect(model.formIsAvailable)
    }

    @MainActor @Test func editingTheFormUpdatesTheText() throws {
        let model = BucketCORSModel(rules: [Self.rule()])
        model.edit(ruleAt: 0) { $0.allowedMethods = ["GET", "PUT"] }
        #expect(model.rules[0].allowedMethods == ["GET", "PUT"])
        #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == model.rules)
    }

    @MainActor @Test func addingAndRemovingARuleKeepsTheTwoPanesTogether() throws {
        let model = BucketCORSModel(rules: [Self.rule()])
        model.addRule()
        #expect(model.rules.count == 2)
        #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == model.rules)
        model.removeRule(at: 0)
        #expect(model.rules.count == 1)
        #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == model.rules)
        // An index that is not a rule is dropped, not trapped on.
        model.removeRule(at: 5)
        model.edit(ruleAt: 5) { $0.allowedMethods = [] }
        #expect(model.rules.count == 1)
    }

    @Test func aMethodToggleKeepsTheCanonicalOrder() {
        #expect(
            BucketCORSModel.methods(["PUT"], setting: "GET", to: true) == ["GET", "PUT"])
        #expect(BucketCORSModel.methods(["GET", "PUT"], setting: "GET", to: false) == ["PUT"])
        #expect(BucketCORSModel.methods([], setting: "HEAD", to: true) == ["HEAD"])
    }

    @Test func theMaxAgeFieldReadsANumberOrNothing() {
        #expect(BucketCORSModel.maxAge(fromField: " 3000 ") == .some(3000))
        #expect(BucketCORSModel.maxAge(fromField: "  ") == .some(nil))
        #expect(BucketCORSModel.maxAge(fromField: "soon") == nil)
        #expect(BucketCORSModel.maxAge(fromField: "-1") == nil)
    }

    // MARK: - What blocks saving

    @MainActor @Test func anInvalidMethodBlocksSavingAndNamesItself() {
        let model = BucketCORSModel(rules: [])
        model.text = "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
            + "<AllowedMethod>FETCH</AllowedMethod></CORSRule></CORSConfiguration>"
        #expect(model.canSave == false)
        #expect(model.problem == .methodNotAllowed("FETCH"))
    }

    /// The positive beside it: the same document with a method S3 accepts is
    /// saveable, so the red above is about the method and not about the
    /// document or the model never being saveable at all.
    @MainActor @Test func theSameRuleWithAnAcceptedMethodCanBeSaved() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.simpleDocument
        #expect(model.problem == nil)
        #expect(model.canSave)
    }

    @MainActor @Test func aRuleWithNoOriginOrNoMethodBlocksSavingAndSaysWhich() {
        let model = BucketCORSModel(rules: [])
        model.text = "<CORSConfiguration><CORSRule><AllowedMethod>GET</AllowedMethod>"
            + "</CORSRule></CORSConfiguration>"
        #expect(model.problem == .noOrigin)
        #expect(model.problemRuleIndex == 0)
        #expect(!model.canSave)
        model.text = "<CORSConfiguration>" + Self.ruleXML(origin: "*", method: "GET")
            + "<CORSRule><AllowedOrigin>*</AllowedOrigin></CORSRule></CORSConfiguration>"
        #expect(model.problem == .noMethod)
        #expect(model.problemRuleIndex == 1)
        #expect(!model.canSave)
    }

    private static func ruleXML(origin: String, method: String) -> String {
        "<CORSRule><AllowedOrigin>\(origin)</AllowedOrigin>"
            + "<AllowedMethod>\(method)</AllowedMethod></CORSRule>"
    }

    /// Text that is not a CORS document yet is not a state to save, and it
    /// does not erase the rules last understood from it.
    @MainActor @Test func textThatCannotBeReadBlocksSavingAndDisablesTheForm() {
        let model = BucketCORSModel(rules: [Self.rule()])
        model.text = "<CORSConfiguration><CORSRule>"
        #expect(!model.isReadable)
        #expect(!model.canSave)
        #expect(!model.formIsAvailable)
        #expect(model.formUnavailableReasonKey == "s3.cors.formNeedsReadableText")
        #expect(model.rules == [Self.rule()])
        model.text = Self.simpleDocument
        #expect(model.isReadable)
        #expect(model.formIsAvailable)
        #expect(model.formUnavailableReasonKey == nil)
    }

    // MARK: - The honest edge (spec 6.3)

    @MainActor @Test func aConfigurationTheFormCannotShowDisablesTheForm() {
        // The honest edge (spec §6.3). Measured as near-unreachable — the store
        // refuses undocumented elements — so this is the fallback, not the norm.
        let model = BucketCORSModel(rules: [])
        model.text = "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
            + "<AllowedMethod>GET</AllowedMethod><Unknown>x</Unknown></CORSRule></CORSConfiguration>"
        #expect(model.formIsAvailable == false)
        #expect(model.formUnavailableReasonKey == "s3.cors.formCannotShowThis")
    }

    /// Saving the understood rules would drop the element the form cannot
    /// show, so the sheet does not offer it: removing the element in the text
    /// is what makes the document saveable.
    @MainActor @Test func aDocumentWithSomethingThePartsDropCannotBeSavedUntilItIsRemoved() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.documentWithAnUnknownElement
        #expect(model.problem == nil)
        #expect(!model.canSave)
        model.text = Self.simpleDocument
        #expect(model.canSave)
    }

    /// The census behind that: each way a document can say more than its
    /// rules do is caught, not only the one in the brief. The positive
    /// control is the plain document, which has none of them.
    /// One rule around `inner`, with the other field a rule needs.
    private static func wrapped(_ inner: String) -> String {
        "<CORSConfiguration><CORSRule>" + inner + "</CORSRule></CORSConfiguration>"
    }

    private static let origin = "<AllowedOrigin>*</AllowedOrigin>"
    private static let get = "<AllowedMethod>GET</AllowedMethod>"

    private static let documentsThatSayMoreThanTheirRules: [String] = [
        // A second element of a kind the rule holds once.
        wrapped("<ID>a</ID><ID>b</ID>" + origin + get),
        // An element nested inside a field.
        wrapped("<AllowedOrigin><b>x</b></AllowedOrigin>" + get),
        // An element beside the rules.
        "<CORSConfiguration><Extra/><CORSRule>" + origin + get + "</CORSRule></CORSConfiguration>",
        // An attribute on a field.
        wrapped("<AllowedOrigin kind=\"x\">*</AllowedOrigin>" + get),
        // A rule inside a rule.
        wrapped("<CORSRule>" + origin + get + "</CORSRule>"),
    ]

    @MainActor @Test(arguments: BucketCORSSheetTests.documentsThatSayMoreThanTheirRules)
    func everyWayAnElementCanBeLostIsNoticed(document: String) {
        let model = BucketCORSModel(rules: [])
        model.text = document
        #expect(model.isReadable)
        #expect(!model.formIsAvailable)
        #expect(!model.canSave)
    }

    @MainActor @Test func theNamespaceAndTheOrderOfFieldsAreNotSomethingLost() {
        let model = BucketCORSModel(rules: [])
        model.text =
            "<?xml version=\"1.0\"?><CORSConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
            + "  <CORSRule>\n    <MaxAgeSeconds>5</MaxAgeSeconds>\n"
            + "    <AllowedMethod>GET</AllowedMethod>\n    <AllowedOrigin>*</AllowedOrigin>\n"
            + "  </CORSRule>\n</CORSConfiguration>"
        #expect(model.formIsAvailable)
        #expect(model.rules == [Self.rule(maxAge: 5)])
    }

    /// The form shows five methods. A method outside them is stored by the rig
    /// (measured 2026-10-19) and the form has nowhere to put it.
    @MainActor @Test func aMethodTheFormHasNoBoxForDisablesTheForm() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.ruleDocument(method: "FETCH")
        #expect(!model.formIsAvailable)
        #expect(model.formUnavailableReasonKey == BucketCORSModel.formCannotShowMethodLine.key)
        model.text = Self.ruleDocument(method: "GET")
        #expect(model.formIsAvailable)
    }

    /// A value spread over several lines is one the form's one-line fields
    /// cannot hold. The positive controls are the values that look like
    /// trouble and are not: space at either end and nothing at all are shown
    /// as they are, so a field can be typed into one character at a time.
    @MainActor @Test func aValueOverSeveralLinesDisablesTheForm() {
        let model = BucketCORSModel(rules: [])
        for shown in [" https://a.example ", ""] {
            model.text = Self.originDocument(shown)
            #expect(model.isReadable)
            #expect(model.formIsAvailable, "\(shown.debugDescription)")
        }
        model.text = Self.originDocument("a\nb")
        #expect(model.isReadable)
        #expect(!model.formIsAvailable)
        #expect(model.formUnavailableReasonKey == BucketCORSModel.formCannotShowValueLine.key)
    }

    private static func originDocument(_ origin: String) -> String {
        "<CORSConfiguration><CORSRule><AllowedOrigin>\(origin)</AllowedOrigin>"
            + "<AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"
    }

    private static func ruleDocument(method: String) -> String {
        "<CORSConfiguration>" + ruleXML(origin: "*", method: method) + "</CORSConfiguration>"
    }

    /// The fields refuse to edit what they cannot show, and the control does
    /// not switch to them. The positive control: both work while the form is
    /// available, which the tests above rely on.
    @MainActor @Test func theFieldsAreNotEditedAndNotSwitchedToWhileTheyAreOff() {
        let model = BucketCORSModel(rules: [Self.rule()])
        model.selectPane(.text)
        model.selectPane(.form)
        #expect(model.pane == .form)
        model.selectPane(.text)
        model.text = Self.documentWithAnUnknownElement
        let before = model.text
        model.edit(ruleAt: 0) { $0.allowedMethods = ["PUT"] }
        model.replaceRule(at: 0, with: Self.rule(id: "x"))
        model.addRule()
        model.removeRule(at: 0)
        model.selectPane(.form)
        #expect(model.text == before)
        #expect(model.pane == .text)
    }

    /// A shown pane that is the form while the form is unavailable would be a
    /// control over a configuration it cannot show.
    @MainActor @Test func theFormIsNeverTheVisiblePaneWhileItIsUnavailable() {
        let model = BucketCORSModel(rules: [Self.rule()])
        model.pane = .form
        #expect(model.visiblePane == .form)
        model.text = Self.documentWithAnUnknownElement
        #expect(model.pane == .form)
        #expect(model.visiblePane == .text)
        model.pane = .text
        #expect(model.visiblePane == .text)
    }

    // MARK: - What a load puts on screen

    @MainActor @Test func aLoadedConfigurationTheFormCanShowIsShownAsItsRules() throws {
        let rules = [Self.rule(id: "r", methods: ["GET", "PUT"], maxAge: 60)]
        let body = try S3SettingsXML.corsBody(rules)
        let model = BucketCORSModel(loaded: BucketCORS(rules: rules, rawBody: body))
        #expect(model.rules == rules)
        #expect(model.formIsAvailable)
        #expect(!model.canSave)  // nothing has been changed
        #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == rules)
    }

    /// `BucketCORS.rules` is what the parse understood and `rawBody` is what
    /// the store sent; they differ exactly when the parse dropped something
    /// (the doc comment on `S3BucketSettings.cors(ofBucket:)`). The text pane
    /// shows the raw body, so what the store holds is visible, and the form
    /// is off. The rules alone would have said everything was fine.
    @MainActor @Test func aLoadedConfigurationWithMoreThanItsRulesShowsTheRawBodyAndNoForm() {
        let rules = [Self.rule()]
        let raw = Data(Self.documentWithAnUnknownElement.utf8)
        let model = BucketCORSModel(loaded: BucketCORS(rules: rules, rawBody: raw))
        #expect(model.text == Self.documentWithAnUnknownElement)
        #expect(!model.formIsAvailable)
        #expect(model.formUnavailableReasonKey == "s3.cors.formCannotShowThis")
        #expect(model.visiblePane == .text)
        #expect(!model.canSave)
    }

    /// The cleanup of such a document changes the store without changing the
    /// rules, so "the rules are what they were" must not read as "nothing to
    /// save".
    @MainActor @Test func removingWhatTheRulesCouldNotHoldIsAChangeToSave() {
        let rules = [Self.rule()]
        let raw = Data(Self.documentWithAnUnknownElement.utf8)
        let model = BucketCORSModel(loaded: BucketCORS(rules: rules, rawBody: raw))
        model.text = Self.simpleDocument
        #expect(model.rules == rules)
        #expect(model.canSave)
    }

    @MainActor @Test func noConfigurationAtAllIsAnEmptyListNothingToSave() {
        let model = BucketCORSModel(loaded: nil)
        #expect(model.rules.isEmpty)
        #expect(model.isReadable)
        #expect(model.formIsAvailable)
        #expect(!model.canSave)
        #expect(model.hasNoConfiguration)
        model.addRule()
        #expect(!model.hasNoConfiguration)
    }

    // MARK: - Reading and writing

    @MainActor @Test func aReadFillsTheModelFromTheBucketItWasAskedAbout() async throws {
        let rules = [Self.rule(origins: ["https://a.example"], methods: ["GET", "HEAD"])]
        let settings = FakeBucketSettings(
            cors: BucketCORS(rules: rules, rawBody: try S3SettingsXML.corsBody(rules)))
        let model = BucketCORSModel()
        #expect(model.load == .reading)
        await model.read(bucket: "macscp-seed", from: settings)
        #expect(model.load == .ready)
        #expect(model.rules == rules)
        #expect(settings.corsReads == ["macscp-seed"])
    }

    @MainActor @Test func aRefusedReadSaysSoAndOffersNothingToSave() async {
        let settings = FakeBucketSettings(
            corsReadError: RemoteFSError.finding(.operationNotSupported))
        let model = BucketCORSModel()
        await model.read(bucket: "b", from: settings)
        #expect(model.load == .failed(RemoteFSFinding.operationNotSupported.message))
        #expect(!model.canSave)
    }

    @MainActor @Test func savingWritesTheRulesOnceToTheNamedBucketAndShowsTheStoresAnswer() async {
        let settings = FakeBucketSettings()
        let model = BucketCORSModel(loaded: nil)
        model.text = Self.simpleDocument
        #expect(model.canSave)
        await model.save(bucket: "macscp-second", via: settings)
        #expect(
            settings.corsWrites
                == [FakeBucketSettings.CORSWrite(rules: [Self.rule()], bucket: "macscp-second")])
        #expect(settings.corsReads == ["macscp-second"])  // read back, not assumed
        #expect(model.saveFailure == nil)
        #expect(!model.isSaving)
        #expect(!model.canSave)  // what is shown is now what is stored
        #expect(model.rules == [Self.rule()])
    }

    /// Removing every rule is a legitimate save: it clears the configuration
    /// (`setCORS([])`), and what comes back is "no configuration".
    @MainActor @Test func savingWithNoRulesClearsTheConfiguration() async throws {
        let rules = [Self.rule()]
        let settings = FakeBucketSettings(
            cors: BucketCORS(rules: rules, rawBody: try S3SettingsXML.corsBody(rules)))
        let model = BucketCORSModel(loaded: try await settings.cors(ofBucket: "b"))
        model.removeRule(at: 0)
        #expect(model.clearsTheConfiguration)
        #expect(model.canSave)
        await model.save(bucket: "b", via: settings)
        #expect(settings.corsWrites == [FakeBucketSettings.CORSWrite(rules: [], bucket: "b")])
        #expect(model.hasNoConfiguration)
        #expect(!model.canSave)
    }

    /// Nothing is sent from a state that cannot be saved. The positive
    /// control is the write above.
    @MainActor @Test func aStateThatCannotBeSavedSendsNothing() async {
        let settings = FakeBucketSettings()
        let model = BucketCORSModel(loaded: nil)
        model.text = Self.ruleDocument(method: "FETCH")
        await model.save(bucket: "b", via: settings)
        model.text = Self.documentWithAnUnknownElement
        await model.save(bucket: "b", via: settings)
        model.text = "<CORSConfiguration>"
        await model.save(bucket: "b", via: settings)
        #expect(settings.corsWrites.isEmpty)
    }

    @MainActor @Test func aRefusedWriteKeepsWhatWasTypedAndSaysWhy() async {
        let settings = FakeBucketSettings(
            corsWriteError: RemoteFSError.finding(.operationNotSupported))
        let model = BucketCORSModel(loaded: nil)
        model.text = Self.simpleDocument
        await model.save(bucket: "b", via: settings)
        #expect(settings.corsWrites.count == 1)
        #expect(model.saveFailure == RemoteFSFinding.operationNotSupported.message)
        #expect(model.text == Self.simpleDocument)
        #expect(model.canSave)  // the user can try again
        #expect(!model.isSaving)
    }

    /// A rule refused before sending is reported as what it is (the
    /// finding's own sentence, "nothing was sent"), not as an answer from the
    /// store that could not be used.
    @MainActor @Test func aRuleRefusedBeforeSendingIsNotReportedAsAnUnusableAnswer() async {
        let settings = FakeBucketSettings(corsWriteError: RemoteFSError.finding(.corsRuleInvalid))
        let model = BucketCORSModel(loaded: nil)
        model.text = Self.simpleDocument
        await model.save(bucket: "b", via: settings)
        #expect(model.saveFailure == RemoteFSFinding.corsRuleInvalid.message)
        // The sentence a store answer that could not be used is shown as.
        #expect(model.saveFailure != BucketCORSModel.saveFailedLine.text)
    }

    /// A raw `reason` can carry the endpoint the user typed, and that field
    /// takes `scheme://KEY:SECRET@host` as ordinary input. The value is a
    /// named constant and the `Bool` is computed before the expectation, so a
    /// failure cannot print it.
    @MainActor @Test func aFailureNeverQuotesTheReasonItWasGiven() async {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let settings = FakeBucketSettings(
            corsReadError: RemoteFSError.protocolError(reason: planted),
            corsWriteError: RemoteFSError.protocolError(reason: planted))
        let reading = BucketCORSModel()
        await reading.read(bucket: "b", from: settings)
        let writing = BucketCORSModel(loaded: nil)
        writing.text = Self.simpleDocument
        await writing.save(bucket: "b", via: settings)
        var shown = ""
        if case .failed(let sentence) = reading.load { shown += sentence }
        shown += writing.saveFailure ?? ""
        let quoted = shown.contains("SECRETEXAMPLE") || shown.contains("store.invalid")
        #expect(!shown.isEmpty)
        #expect(!quoted)
    }

    @MainActor @Test func aMissingPermissionHasItsOwnSentence() {
        let denied = BucketCORSModel.message(
            for: RemoteFSError.permissionDenied(path: "/b"), applying: true)
        let generic = BucketCORSModel.message(
            for: CocoaError(.fileReadUnknown), applying: true)
        #expect(!denied.isEmpty)
        #expect(!generic.isEmpty)
        #expect(denied != generic)
    }

    // MARK: - The pane the user chose is theirs (fix round 1, I1)

    /// A configuration the sheet reads from the store, through `read`, so the
    /// opening pane is chosen the way it is in the app.
    @MainActor private static func readModel(
        _ settings: FakeBucketSettings
    ) async -> BucketCORSModel {
        let model = BucketCORSModel()
        await model.read(bucket: "b", from: settings)
        return model
    }

    private static func storedSettings(
        writeError: (any Error)? = nil
    ) throws -> FakeBucketSettings {
        let rules = [rule()]
        return FakeBucketSettings(
            cors: BucketCORS(rules: rules, rawBody: try S3SettingsXML.corsBody(rules)),
            corsWriteError: writeError)
    }

    /// Switching to the text pane, editing and saving leaves the user in the
    /// text pane. The state the save leaves behind is the store's answer, which
    /// the fields can show, so nothing but the opening-pane rule would move
    /// the user. The opposite case, a user in the fields, is the positive
    /// control: it stays too.
    @MainActor @Test func aSuccessfulSaveLeavesTheChosenPaneAlone() async throws {
        for chosen in [BucketCORSModel.Pane.text, .form] {
            let settings = try Self.storedSettings()
            let model = await Self.readModel(settings)
            #expect(model.pane == .form)  // opened on the fields
            model.selectPane(chosen)
            model.text = Self.originDocument("https://a.example")
            #expect(model.canSave)
            await model.save(bucket: "b", via: settings)
            #expect(settings.corsWrites.count == 1)
            #expect(model.saveFailure == nil)
            #expect(model.pane == chosen)
            #expect(model.visiblePane == chosen)
        }
    }

    /// The other path, a refused save, keeps the pane too, so the two paths
    /// agree about something the user chose.
    @MainActor @Test func aRefusedSaveLeavesTheChosenPaneAlone() async throws {
        let settings = try Self.storedSettings(
            writeError: RemoteFSError.finding(.operationNotSupported))
        let model = await Self.readModel(settings)
        model.selectPane(.text)
        model.text = Self.originDocument("https://a.example")
        await model.save(bucket: "b", via: settings)
        #expect(settings.corsWrites.count == 1)
        #expect(model.saveFailure != nil)
        #expect(model.pane == .text)
    }

    /// A read still chooses the opening pane: the fields when they can show
    /// the configuration, the text when they cannot. Without this the two
    /// tests above would pass for a model that never chose at all.
    @MainActor @Test func aReadOpensOnThePaneThatCanShowTheConfiguration() async {
        let lossy = FakeBucketSettings(
            cors: BucketCORS(
                rules: [Self.rule()], rawBody: Data(Self.documentWithAnUnknownElement.utf8)))
        let model = await Self.readModel(lossy)
        #expect(model.pane == .text)
        let plain = await Self.readModel(FakeBucketSettings())
        #expect(plain.pane == .form)
    }

    // MARK: - A value the rules write back differently (fix round 1, M1)

    /// `a&#13;b` holds a carriage return. The rules keep `a\rb`, `corsBody`
    /// writes it literally, and the next parse reads `a\nb`: the element
    /// census cannot see that, because every element is still consumed.
    /// Saving it would store a value the user did not write.
    @MainActor @Test func aValueThatChangesOnTheWayBackIsNotLossless() throws {
        let reading = BucketCORSModel.read(Self.originDocument("a&#13;b"))
        #expect(reading.isReadable)
        // The census sees nothing wrong: no element is left out.
        #expect(reading.leftOut.isEmpty)
        // And the rules do not survive the round trip, which is the point.
        let canonical = try S3SettingsXML.corsBody(reading.rules)
        let again = try S3SettingsXML.parseCORS(canonical)
        #expect(again != reading.rules)
        #expect(!reading.isLossless)
        let model = BucketCORSModel(rules: [])
        model.text = Self.originDocument("a&#13;b")
        #expect(!model.canSave)
        #expect(model.blockerLine?.key == BucketCORSModel.valueChangesLine.key)
    }

    /// The positive beside it: an ordinary value with the characters XML
    /// escapes survives, so the check is not "no value is ever lossless".
    @MainActor @Test func aValueThatSurvivesTheRoundTripIsLossless() {
        let reading = BucketCORSModel.read(Self.originDocument("a&amp;b&#42;"))
        #expect(reading.isLossless)
        #expect(reading.rules == [Self.rule(origins: ["a&b*"])])
    }

    // MARK: - A clear is never silent (fix round 1, M11)

    /// A stored document that parses to no rules at all but says more than its
    /// rules would clear the configuration when the extra is removed and the
    /// empty list saved. That is the destructive direction, and it carries the
    /// sentence like any other clear. Neither "no configuration" nor a plain
    /// empty list is true of it.
    @MainActor @Test func aLossyDocumentWithNoRulesStillWarnsThatSavingClears() {
        let raw = Data("<CORSConfiguration><Unknown>x</Unknown></CORSConfiguration>".utf8)
        let model = BucketCORSModel(loaded: BucketCORS(rules: [], rawBody: raw))
        #expect(model.rules.isEmpty)
        #expect(!model.hasNoConfiguration)
        #expect(model.clearsTheConfiguration)
        model.text = "<CORSConfiguration></CORSConfiguration>"
        #expect(model.canSave)
        #expect(model.clearsTheConfiguration)
        #expect(model.lines.contains { $0.key == BucketCORSModel.clearsAllLine.key })
    }

    // MARK: - The form-off sentences name the offender (fix round 1)

    @MainActor @Test func theLossySentenceNamesTheElementsLeftOut() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.documentWithAnUnknownElement
        #expect(model.leftOutNames == ["Unknown"])
        let sentence = L10n.$localeOverride.withValue("en") {
            model.formUnavailableSentence ?? ""
        }
        let names = sentence.contains("Unknown")
        #expect(names)
    }

    @MainActor @Test func anAttributeIsNamedWithItsElement() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.wrapped("<AllowedOrigin kind=\"x\">*</AllowedOrigin>" + Self.get)
        #expect(model.leftOutNames == ["AllowedOrigin@kind"])
    }

    /// The list is short and each name is clipped: the names come from a
    /// document, and the sheet's height was measured with a sentence of a
    /// fixed length.
    @Test func aListOfNamesIsShortAndEachNameIsClipped() {
        let many = (1...6).map { "Extra\($0)" }
        let listed = BucketCORSModel.listed(many)
        #expect(listed.contains("Extra1"))
        #expect(listed.contains("Extra3"))
        let showsFourth = listed.contains("Extra4")
        #expect(!showsFourth)
        let long = String(repeating: "x", count: 200)
        let clipped = BucketCORSModel.listed([long])
        #expect(clipped.count < 60)
        #expect(clipped.hasPrefix("xxxx"))
        #expect(BucketCORSModel.listed([]) == "")
    }

    @MainActor @Test func theMethodSentenceNamesTheMethod() {
        let model = BucketCORSModel(rules: [])
        model.text = Self.ruleDocument(method: "FETCH")
        let sentence = L10n.$localeOverride.withValue("en") {
            model.formUnavailableSentence ?? ""
        }
        let names = sentence.contains("FETCH")
        #expect(names)
    }

    @MainActor @Test func theValueSentenceNamesTheRule() {
        let model = BucketCORSModel(rules: [])
        model.text = "<CORSConfiguration>" + Self.ruleXML(origin: "*", method: "GET")
            + "<CORSRule><AllowedOrigin>a\nb</AllowedOrigin>"
            + "<AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"
        #expect(model.formUnavailableReasonKey == BucketCORSModel.formCannotShowValueLine.key)
        let sentence = L10n.$localeOverride.withValue("en") {
            model.formUnavailableSentence ?? ""
        }
        #expect(sentence.contains("rule 2"))
    }

    /// One cause is said once. A method outside the five and an element a rule
    /// has no place for each have a sentence that already says the save is not
    /// possible, so no second red sentence repeats it; the positive controls
    /// are the causes only the second sentence says.
    @MainActor @Test func aCauseIsNotSaidTwice() {
        let method = BucketCORSModel(rules: [])
        method.text = Self.ruleDocument(method: "FETCH")
        #expect(method.formUnavailableLine != nil)
        #expect(method.blockerLine == nil)
        #expect(!method.canSave)
        let lossy = BucketCORSModel(rules: [])
        lossy.text = Self.documentWithAnUnknownElement
        #expect(lossy.formUnavailableLine != nil)
        #expect(lossy.blockerLine == nil)
        #expect(!lossy.canSave)
        let unreadable = BucketCORSModel(rules: [])
        unreadable.text = "<CORSConfiguration>"
        #expect(unreadable.formUnavailableLine != nil)
        #expect(unreadable.blockerLine != nil)
        let noOrigin = BucketCORSModel(rules: [Self.rule(origins: [])])
        #expect(noOrigin.formUnavailableLine == nil)
        #expect(noOrigin.blockerLine != nil)
    }

    // MARK: - A control with nothing to choose is greyed (fix round 1, M7)

    @MainActor @Test func theFormCanBeChosenExactlyWhenItIsAvailable() {
        let on = BucketCORSModel(rules: [Self.rule()])
        #expect(on.canSelect(.form))
        #expect(on.canSelect(.text))
        let off = BucketCORSModel(rules: [Self.rule()])
        off.text = Self.documentWithAnUnknownElement
        #expect(!off.canSelect(.form))
        #expect(off.canSelect(.text))
        // `selectPane` agrees with `canSelect`, so the control and the model
        // cannot answer differently.
        off.selectPane(.text)
        off.selectPane(.form)
        #expect(off.pane == .text)
    }

    /// Whether the hosted pane control accepts a click, found by the label of
    /// its form segment. Plain `Text` is not a view, but a segmented control is
    /// (BoundedViewStateOnScreenTests says so).
    @MainActor private static func paneControlIsEnabled(for model: BucketCORSModel) -> Bool? {
        L10n.$localeOverride.withValue("en") {
            let host = NSHostingView(
                rootView: BucketCORSSheet(
                    bucket: "b", settings: FakeBucketSettings(), model: model))
            host.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            var result: Bool?
            @MainActor func walk(_ view: NSView) {
                if let control = view as? NSSegmentedControl {
                    for index in 0..<control.segmentCount
                    where control.label(forSegment: index) == BucketCORSModel.paneFormLine.text {
                        result = control.isEnabled
                    }
                }
                for child in view.subviews { walk(child) }
            }
            walk(host)
            return result
        }
    }

    /// The control is greyed exactly when it has nothing to offer, read off the
    /// hosted view and not off the model. The positive is the first line: with
    /// the fields available the same walk finds the control enabled.
    @MainActor @Test func thePaneControlIsGreyedWhileTheFormIsOff() {
        let on = BucketCORSModel(rules: [Self.rule()])
        #expect(on.hasAnotherPaneToChoose)
        #expect(Self.paneControlIsEnabled(for: on) == true)
        let off = BucketCORSModel(rules: [Self.rule()])
        off.text = Self.documentWithAnUnknownElement
        #expect(!off.hasAnotherPaneToChoose)
        #expect(Self.paneControlIsEnabled(for: off) == false)
        // From the text pane with the form available there is still somewhere
        // to go.
        let inText = BucketCORSModel(rules: [Self.rule()])
        inText.selectPane(.text)
        #expect(inText.hasAnotherPaneToChoose)
        #expect(Self.paneControlIsEnabled(for: inText) == true)
    }

    // MARK: - The catalogue

    @MainActor @Test func everyLineResolvesInAllFourLocales() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        let lines = Self.everyLine()
        for line in lines {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) {
                    L10n.string(line.key, sentinel)
                }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
            }
        }
        #expect(lines.count > 0)
    }

    @MainActor @Test func theEnglishCatalogueSaysTheDefault() {
        let lines = Self.everyLine()
        for line in lines {
            let english = L10n.$localeOverride.withValue("en") {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(english == line.english, "\(line.key)")
        }
        #expect(lines.count > 0)
    }

    /// The two reasons the form can be off are the keys the model answers
    /// with, and each has its own sentence: one reason is "the text is not
    /// readable yet", the other "the text holds something the form cannot
    /// show", and a reader needs to be told which.
    @MainActor @Test func eachReasonTheFormIsOffHasItsOwnSentenceInEveryLanguage() throws {
        let unreadable = BucketCORSModel(rules: [])
        unreadable.text = "<CORSConfiguration>"
        let unshowable = BucketCORSModel(rules: [])
        unshowable.text = Self.documentWithAnUnknownElement
        let keys = [unreadable.formUnavailableReasonKey, unshowable.formUnavailableReasonKey]
        let first = try #require(keys[0])
        let second = try #require(keys[1])
        #expect(first != second)
        let covered = Set(Self.everyLine().map(\.key))
        #expect(covered.contains(first))
        #expect(covered.contains(second))
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) {
                (L10n.string(first, "x"), L10n.string(second, "x"))
            }
            #expect(texts.0 != texts.1, "\(locale)")
        }
    }

    /// The sheet's source is read for the keys it uses, so a key used in the
    /// view and absent from `everyLine()` is a red here. The comment-free view
    /// keeps the string literals; the positive half is that the scan found
    /// some.
    @MainActor @Test func everyKeyTheSheetUsesIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/BucketCORSSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(source.matches(of: #/"(s3\.cors\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let uncovered = used.subtracting(Set(Self.everyLine().map(\.key))).sorted()
        #expect(uncovered.isEmpty, "\(uncovered)")
    }

    /// The text pane holds XML, and a text view left at the system default
    /// turns the straight quotes of an attribute into curly ones. The editor
    /// switches the substitutions off; the positive half is that the editor
    /// is in the file at all.
    @Test func theTextEditorSwitchesOffTheSubstitutionsThatBreakMarkup() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/BucketCORSSheet.swift")
        let source = try SourceCorpus.code(of: url)
        #expect(source.contains("NSTextView"))
        for property in [
            "isAutomaticQuoteSubstitutionEnabled", "isAutomaticDashSubstitutionEnabled",
            "isAutomaticTextReplacementEnabled", "isAutomaticSpellingCorrectionEnabled",
        ] {
            let switchedOff = source.contains("\(property) = false")
            #expect(switchedOff, "\(property)")
        }
    }

    /// Every line the sheet can show, for every state it can be in.
    @MainActor private static func everyLine() -> [CatalogueLine] {
        var lines = BucketCORSModel.fixedLines
        lines += BucketCORSModel(rules: [Self.rule()]).lines
        let unreadable = BucketCORSModel(rules: [])
        unreadable.text = "<CORSConfiguration>"
        lines += unreadable.lines
        let unshowable = BucketCORSModel(rules: [])
        unshowable.text = Self.documentWithAnUnknownElement
        lines += unshowable.lines
        let noOrigin = BucketCORSModel(rules: [Self.rule(origins: [])])
        lines += noOrigin.lines
        let noMethod = BucketCORSModel(rules: [Self.rule(methods: [])])
        lines += noMethod.lines
        let badMethod = BucketCORSModel(rules: [Self.rule(methods: ["FETCH"])])
        lines += badMethod.lines
        lines += BucketCORSModel(loaded: nil).lines
        let multiLine = BucketCORSModel(rules: [])
        multiLine.text = Self.originDocument("a\nb")
        lines += multiLine.lines
        let carriageReturn = BucketCORSModel(rules: [])
        carriageReturn.text = Self.originDocument("a&#13;b")
        lines += carriageReturn.lines
        let cleared = BucketCORSModel(rules: [Self.rule()])
        cleared.removeRule(at: 0)
        lines += cleared.lines
        return lines
    }
}
