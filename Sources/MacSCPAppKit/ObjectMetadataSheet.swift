import SwiftUI
import macSCPCore

/// Every sentence the metadata sheet has of its own, as data, so the tests can
/// hold each one to all four languages.
///
/// Three lines are not here because another sheet already says them and this
/// one reuses the sentence and its key: the generic failures
/// (`ObjectLockLines.denied`, `ObjectLockLines.applyFailed`), "Saved." and the
/// two refusals of the date-naming acknowledgement
/// (`BucketObjectLockModel.notAcknowledgedLine` and `.staleLine`), which say
/// nothing that depends on which sheet shows them.
///
/// **No sentence names how the store works**, with one exception that is the
/// person's own input: `customNamePrefixedLine` quotes the prefix a custom
/// name must be typed without, because that is the one case in which the
/// person has to be told what not to type.
enum ObjectMetadataLines {
    static let title = CatalogueLine(
        key: "s3.metadata.title %@", english: "Metadata of “%@”")
    static let reading = CatalogueLine(
        key: "s3.metadata.reading", english: "Reading the file's metadata…")
    static let readFailed = CatalogueLine(
        key: "s3.metadata.error.read", english: "The file's metadata could not be read.")
    static let contentTypeLabel = CatalogueLine(
        key: "s3.metadata.field.contentType", english: "Content-Type")
    static let cacheControlLabel = CatalogueLine(
        key: "s3.metadata.field.cacheControl", english: "Cache-Control")
    static let contentDispositionLabel = CatalogueLine(
        key: "s3.metadata.field.contentDisposition", english: "Content-Disposition")
    static let customHeading = CatalogueLine(
        key: "s3.metadata.custom.heading", english: "Custom metadata")
    static let customNone = CatalogueLine(
        key: "s3.metadata.custom.none", english: "This file has no custom metadata.")
    static let customNameLabel = CatalogueLine(
        key: "s3.metadata.custom.name", english: "Name")
    static let customValueLabel = CatalogueLine(
        key: "s3.metadata.custom.value", english: "Value")
    static let addPair = CatalogueLine(
        key: "s3.metadata.custom.add", english: "Add Pair")
    static let removePair = CatalogueLine(
        key: "s3.metadata.custom.remove", english: "Remove Pair")
    /// Said above the fields, because saving sends ALL of them: an empty field
    /// is not "left alone", it is removed.
    static let replaceNote = CatalogueLine(
        key: "s3.metadata.replaceNote",
        english: "Saving replaces all of this file's metadata with what is shown here. An empty field is removed.")
    /// Said before the write on a bucket that keeps versions (spec section
    /// 4.5: a metadata change is a copy of the file onto itself, and the
    /// listing of versions grew by one).
    static let versionAdded = CatalogueLine(
        key: "s3.metadata.versionNote.added",
        english: "This bucket keeps versions, so saving adds a new version of this file. The earlier versions stay as they are.")
    /// The wording rule of `ObjectVersionsLines`: what could not be read is
    /// said to be unconfirmed, never as a failure and never as an answer.
    static let versionUnknown = CatalogueLine(
        key: "s3.metadata.versionNote.unknown",
        english: "macSCP could not confirm whether this bucket keeps versions. If it does, saving adds a new version of this file.")
    static let complianceWarning = CatalogueLine(
        key: "s3.metadata.complianceWarning",
        english: "This bucket's default retention is Compliance, and the new version this change adds receives it. Nobody can erase that version's stored data or shorten its retention before the date below — not you, not the account owner, not an administrator. This cannot be undone.")
    static let complianceAcknowledgement = CatalogueLine(
        key: "s3.metadata.complianceAcknowledgement %@",
        english: "I understand that nobody, including me, can erase the stored data of the new version this change adds, and that this cannot be undone. The new version stays locked until %@.")
    /// A write the storage ACCEPTED whose read-back did not show it.
    ///
    /// **Not said as a failure**, which is the rule `versionUnknown` above
    /// states for a read and which holds for this write too: Core throws only
    /// after the copy has returned, so the storage answered and the object has
    /// changed. `ObjectLockLines.applyFailed` — "The change could not be
    /// saved." — is false of it, and that is the sentence this arm said until
    /// 2026-11-04.
    static let saveUnconfirmed = CatalogueLine(
        key: "s3.metadata.saveUnconfirmed",
        english: "The storage accepted the change, and macSCP could not confirm it: the file does not report the values that were sent. Check the file's metadata again to see what it holds now.")
    static let saveAction = CatalogueLine(key: "s3.metadata.action.save", english: "Save")
    static let unchangedLine = CatalogueLine(
        key: "s3.metadata.blocked.unchanged",
        english: "Nothing has changed, so there is nothing to save.")
    static let customNameMissingLine = CatalogueLine(
        key: "s3.metadata.blocked.customNameMissing",
        english: "Give every custom pair a name.")
    static let customNameInvalidLine = CatalogueLine(
        key: "s3.metadata.blocked.customNameInvalid",
        english: "A custom name may use only letters, digits and these characters: ! # $ % & ' * + - . ^ _ ` | ~")
    static let customNamePrefixedLine = CatalogueLine(
        key: "s3.metadata.blocked.customNamePrefixed",
        english: "macSCP adds the prefix a custom name needs on its own. Type the name without “x-amz-meta-”.")
    static let customNameDuplicatedLine = CatalogueLine(
        key: "s3.metadata.blocked.customNameDuplicated",
        english: "Two custom pairs have the same name. Names do not distinguish upper and lower case.")

    /// Every line above, in one place.
    static let all: [CatalogueLine] = [
        title, reading, readFailed, contentTypeLabel, cacheControlLabel, contentDispositionLabel,
        customHeading, customNone, customNameLabel, customValueLabel, addPair, removePair,
        replaceNote, versionAdded, versionUnknown, complianceWarning, complianceAcknowledgement,
        saveUnconfirmed, saveAction, unchangedLine, customNameMissingLine, customNameInvalidLine,
        customNamePrefixedLine, customNameDuplicatedLine,
    ]

    /// The lines the sheet draws that belong to other sheets' families.
    @MainActor static var borrowed: [CatalogueLine] {
        [
            ObjectLockLines.denied, ObjectLockLines.applyFailed, ObjectLockLines.readFailed,
            ObjectLockLines.saved, BucketObjectLockModel.notAcknowledgedLine,
            BucketObjectLockModel.staleLine,
        ]
    }

    /// The sentence for a failure to read the file's metadata. A finding
    /// carries no foreign text and says its own sentence; a missing permission
    /// has one of its own; anything else is a fixed sentence. **The error is
    /// never quoted**, for the reason `ObjectLockLines.message(for:during:)`
    /// gives: a `reason` can carry the endpoint the user typed.
    static func readMessage(for error: any Error) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            return finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            return ObjectLockLines.denied.text
        default:
            return readFailed.text
        }
    }

    /// The sentence for a write that did not end in a confirmed change.
    ///
    /// **One of them is not a failure.** Core throws for a change the storage
    /// accepted whose read-back afterwards did not show it
    /// (`UnconfirmedMetadataWrite.describes`), and the object has
    /// changed by then; `saveUnconfirmed` says that, rather than the generic
    /// "could not be saved" the rest of this arm keeps. Everything else is
    /// `ObjectLockLines.message(for:during:)`'s answer for a write that is
    /// none of the three Object Lock writes, which is the permission sentence
    /// or the fixed one, and never the error's own text.
    static func saveMessage(for error: any Error) -> String {
        if UnconfirmedMetadataWrite.describes(error) { return saveUnconfirmed.text }
        return ObjectLockLines.message(for: error, during: .applyingDefault)
    }
}

/// Every sentence the read-only access-list section has of its own, as data,
/// so the tests can hold each one to all four languages.
///
/// **The section only reads.** The store accepts an access-list write and
/// keeps nothing (spec section 4.6), so there is no control here and no
/// sentence offering one; `readOnlyNote` says why the list cannot be changed
/// from this sheet without saying how the store works.
///
/// No sentence uses the acronym, and none is keyed exactly as the sub-resource
/// it reads (`NoACLWriteGuardTests` watches for that literal).
enum ObjectACLLines {
    static let heading = CatalogueLine(key: "s3.acl.heading", english: "Access list")
    static let readOnlyNote = CatalogueLine(
        key: "s3.acl.readOnlyNote", english: "macSCP shows this list but does not change it.")
    static let reading = CatalogueLine(
        key: "s3.acl.reading", english: "Reading the access list…")
    static let readFailed = CatalogueLine(
        key: "s3.acl.error.read", english: "The access list could not be read.")
    /// Core answered `nil`: the storage has no access lists for files at all.
    /// **Not the same thing as `noEntries`**, and the two must never share a
    /// sentence.
    static let notOffered = CatalogueLine(
        key: "s3.acl.notOffered",
        english: "This storage does not offer access lists for files.")
    /// Core answered a policy, and it holds no entries.
    static let noEntries = CatalogueLine(
        key: "s3.acl.none", english: "The access list has no entries.")
    /// The section's own sentence for a missing permission. The sheet's shared
    /// one (`ObjectLockLines.denied`) says the key may not "read or change"
    /// the file, and this section's own note says macSCP changes nothing here.
    static let denied = CatalogueLine(
        key: "s3.acl.error.denied",
        english: "Your access key is not allowed to read this list.")
    static let owner = CatalogueLine(key: "s3.acl.owner", english: "Owner")
    static let ownerUnnamed = CatalogueLine(
        key: "s3.acl.owner.unnamed", english: "The storage did not name an owner.")
    /// An entry whose holder the store did not name: the shape the rig returns
    /// (spec section 4.6.1). Said, never drawn as an empty cell.
    static let holderUnnamed = CatalogueLine(
        key: "s3.acl.holder.unnamed",
        english: "The storage did not name who holds this permission.")
    /// **"Identifier", not "ID".** `ACLGrant.granteeID` holds a canonical user
    /// id or, for a group, its URL, and Core cannot say which; a label that
    /// said "ID" would be false of a group. The group shape is inferred, not
    /// measured, which is a reason to keep the label true of both.
    static let identifier = CatalogueLine(
        key: "s3.acl.identifier %@", english: "Identifier: %@")

    /// Every line above, in one place.
    static let all: [CatalogueLine] = [
        heading, readOnlyNote, reading, readFailed, denied, notOffered, noEntries, owner,
        ownerUnnamed, holderUnnamed, identifier,
    ]

    /// The sentence for a failure to read the list. Never quotes the error,
    /// for the reason `ObjectMetadataLines.readMessage(for:)` gives.
    static func readMessage(for error: any Error) -> String {
        switch error {
        case RemoteFSError.finding(let finding):
            return finding.message
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            return denied.text
        default:
            return readFailed.text
        }
    }
}

/// What the access-list section shows, as data, apart from how it is drawn.
///
/// Four answers, because Core gives four: not read yet, the storage offers
/// none (`nil`), a policy (which may hold zero entries), and a failed read.
/// **`nil` and zero entries are different cases on purpose**: one says the
/// storage cannot do this, the other says it can and the list is empty.
enum ObjectACLDisplay: Equatable {
    case reading
    case notOffered
    case failed(String)
    /// `owner` and each row's `holder` are lines of text, top to bottom.
    case policy(owner: [String], rows: [Row])

    struct Row: Equatable {
        let holder: [String]
        /// As the store spells it (`FULL_CONTROL`, `READ`, ...): Core does not
        /// map it to a closed set, because a store may report one this
        /// project has not seen.
        let permission: String
    }

    static func of(_ reading: ObjectMetadataModel.AccessListReading) -> ObjectACLDisplay {
        switch reading {
        case .reading:
            .reading
        case .notOffered:
            .notOffered
        case .failed(let sentence):
            .failed(sentence)
        case .policy(let policy):
            .policy(
                owner: holderLines(
                    name: policy.ownerDisplayName, identifier: policy.ownerID,
                    whenUnnamed: ObjectACLLines.ownerUnnamed),
                rows: rows(of: policy.grants))
        }
    }

    /// One row per entry, in the order the store gave them.
    static func rows(of entries: [ACLGrant]) -> [Row] {
        entries.map {
            Row(
                holder: holderLines(
                    name: $0.granteeDisplayName, identifier: $0.granteeID,
                    whenUnnamed: ObjectACLLines.holderUnnamed),
                permission: $0.permission)
        }
    }

    /// The name first, the identifier beneath it, and a sentence where the
    /// store gave neither. **Never empty**: an unnamed holder is said.
    ///
    /// The identifier is labelled as one (`ObjectACLLines.identifier`) and
    /// not as an id, because it may be a group's URL.
    static func holderLines(
        name: String?, identifier: String?, whenUnnamed: CatalogueLine
    ) -> [String] {
        let name = nonBlank(name)
        let identifier = nonBlank(identifier)
        var lines: [String] = []
        if let name { lines.append(name) }
        if let identifier {
            lines.append(String(format: ObjectACLLines.identifier.text, identifier))
        }
        return lines.isEmpty ? [whenUnnamed.text] : lines
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

/// What the metadata sheet knows and decides, apart from how it is drawn.
///
/// **Saving sends every field the sheet holds, not only the one that changed.**
/// A metadata change is a `REPLACE` copy of the file onto itself (spec section
/// 4.5), and a `REPLACE` replaces everything: a field that is not sent is not
/// kept, it is dropped, and the store may put a default of its own in its
/// place. So the draft starts as everything that was read, and the request is
/// built from the whole draft (`draftMetadata`). Core cannot compare a content
/// type it never sent against what the store reads back, which is the other
/// half of the same fact.
///
/// **A save that changes nothing writes nothing** (`SaveRefusal.nothingChanged`),
/// whatever the previous paragraph says about what a write sends: that
/// paragraph is about WHAT is sent when something did change.
///
/// **The bucket's Object Lock default is read before the write, every time.**
/// A metadata change adds a version (spec section 4.5), a new version on a
/// bucket with a default inherits it, and where that default is COMPLIANCE the
/// version is one nobody can erase until the date (spec section 11.2: the
/// maintainer's decision to keep the date-naming acknowledgement for it). The
/// sheet reads the default when it opens, to show the acknowledgement, and
/// `save()` reads it AGAIN immediately before the write, because the default
/// can change while the sheet is open and an acknowledgement is for the
/// default it was given for. A default that differs from the one the tick was
/// given for takes the tick back.
///
/// The acknowledgement is `BucketObjectLockModel`'s, in the same shape: valid
/// for the day it named, compared on a DAY and not an instant, spent by the
/// write, and refused through a list of reasons rather than a flag.
@MainActor
@Observable
final class ObjectMetadataModel {
    /// Where the sheet is: reading the file, showing it, or showing why the
    /// read failed.
    enum Phase: Equatable {
        case reading
        case ready
        case failed(String)
    }

    /// Whether the bucket has Object Lock at all, as far as the sheet knows.
    enum BucketLock: Equatable {
        case reading
        case absent
        case present
        case failed(String)
    }

    /// What the bucket's versioning says for the note above the buttons.
    enum VersioningReading: Equatable {
        case reading
        case known(BucketVersioning)
        case unreadable
    }

    /// What the file's access list says, as far as the sheet knows. Read-only:
    /// nothing in the model writes it back.
    enum AccessListReading: Equatable {
        case reading
        /// Core answered `nil`: the storage offers no access lists for files.
        case notOffered
        /// A policy, which may hold no entries.
        case policy(ObjectACL)
        case failed(String)
    }

    /// The bucket's default retention, as `S3BucketSettings.objectLockDefault`
    /// reports it.
    struct LockDefault: Equatable {
        let days: Int
        let mode: RetentionMode
    }

    /// Why `save()` wrote nothing and has an answer for the person.
    /// `CaseIterable` so that a test can range over every refusal and not over
    /// the ones its author remembered (`ObjectACLSectionTests`).
    enum SaveRefusal: Equatable, CaseIterable {
        case complianceNotAcknowledged
        case acknowledgementStale
        case nothingChanged
    }

    /// How a `save()` ended, with a case for every way it can, so that a caller
    /// (or a test) cannot read a save that wrote nothing as one that wrote.
    /// **Only `.written` means the store was changed.**
    enum SaveOutcome: Equatable {
        /// The store took the draft and the read-back agreed (Core throws
        /// rather than report a write it could not confirm).
        case written
        /// Refused before anything was sent, for a reason the person is told:
        /// the sheet redraws and says it.
        case refused(SaveRefusal)
        /// Not allowed in the state the sheet is in (nothing read yet, one
        /// already in flight, a custom pair that cannot be sent): nothing was
        /// asked of the store, and `explanation` carries the reason where
        /// there is one. The Save button is off in each of these states.
        case blocked
        /// Tried and did not end in a CONFIRMED write: the lock could not be
        /// read before the write, the store refused it, or the store accepted
        /// it and the read-back did not show it. `applyFailure` carries the
        /// sentence, which for the last of the three says the change was
        /// accepted and could not be confirmed and not that it failed
        /// (`ObjectMetadataLines.saveMessage(for:)`). A write that reached the
        /// store is also recorded in the trail.
        case failed
    }

    /// A custom pair that cannot be sent, and which way.
    enum DraftProblem: Equatable {
        case customNameMissing
        case customNameInvalid
        case customNamePrefixed
        case customNameDuplicated
    }

    /// Everything that can keep Save off. See `BucketObjectLockModel.SaveBlocker`
    /// for the shape: a list of reasons, consulted without a `default`.
    enum SaveBlocker: CaseIterable, Equatable {
        case metadataUnread
        case lockUnread
        case lockReadFailed
        case draftInvalid
        case acknowledgementStale
        case complianceNotAcknowledged
        case unchanged
        case applying
    }

    /// One custom pair as it is being edited.
    struct CustomRow: Identifiable, Equatable {
        let id: UUID
        var name: String
        var value: String

        init(id: UUID = UUID(), name: String, value: String) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    let target: ObjectLockTarget
    private let provider: any ObjectMetadataProvider
    private let settings: any S3BucketSettings
    private let locks: ObjectLockStateCache
    private let versioning: BucketVersioningCache
    private let recorder: AuditRecorder?
    private let now: () -> Date

    private(set) var phase: Phase
    private(set) var bucketLock: BucketLock
    private(set) var bucketDefault: LockDefault?
    private(set) var versioningReading: VersioningReading
    private(set) var accessList: AccessListReading
    private(set) var isApplying = false
    private(set) var applyFailure: String?
    private(set) var isSaved = false
    /// How many saves were refused. Read by the stale blocker so that a click
    /// on a stale tick redraws the sheet: the clock is not observable, so
    /// nothing else this reads changes when midnight passes
    /// (`BucketObjectLockModel.refusedSaves`).
    private(set) var refusedSaves = 0

    /// What the store holds now, normalised the way a draft is
    /// (`normalised(_:)`), so that a comparison with the draft is a
    /// comparison of values and not of spellings.
    private var baseline: ObjectMetadata?

    var contentType = "" { didSet { fieldChanged(oldValue, contentType) } }
    var cacheControl = "" { didSet { fieldChanged(oldValue, cacheControl) } }
    var contentDisposition = "" { didSet { fieldChanged(oldValue, contentDisposition) } }
    var custom: [CustomRow] = [] {
        didSet {
            guard custom != oldValue else { return }
            isSaved = false
        }
    }

    /// The tick on the COMPLIANCE sentence; valid only for the default it was
    /// given for and for the DAY it named (`acknowledgedDay`).
    var acknowledged = false {
        didSet {
            // A second write of the same value (a binding writing back) is not
            // a new tick, and must not stamp a new day onto an old one
            // (`BucketObjectLockModel.acknowledged`).
            guard acknowledged != oldValue else { return }
            acknowledgedDay = acknowledged ? acknowledgementDate : nil
        }
    }

    /// The day the sentence named when the tick was given; see
    /// `BucketObjectLockModel.acknowledgedDay` for why a day and not an
    /// instant.
    private var acknowledgedDay: Date?

    /// A sheet that has not read anything yet.
    ///
    /// The state parameters exist so that the layout registry and the tests
    /// can hand over a sheet already in a state; `loaded`, when given, is
    /// adopted as if it had just been read. **`recorder` has no default**, and
    /// is optional in its type: `nil` is a real answer (a tab whose stored
    /// session was deleted under it has none) but it has to be given at the
    /// call site, not inherited from a default nobody read. It sits second, next
    /// to the target, so that the one line the audit-wiring guard reads after
    /// the call (`BucketSettingsAuditTests.everySheetIsBuiltWithItsItemsRecorder`)
    /// holds it.
    init(
        target: ObjectLockTarget, recorder: AuditRecorder?,
        provider: any ObjectMetadataProvider, settings: any S3BucketSettings,
        locks: ObjectLockStateCache, versioning: BucketVersioningCache,
        now: @escaping () -> Date = { Date() },
        phase: Phase = .reading, loaded: ObjectMetadata? = nil,
        bucketLock: BucketLock = .reading, bucketDefault: LockDefault? = nil,
        versioningReading: VersioningReading = .reading,
        accessList: AccessListReading = .reading
    ) {
        self.target = target
        self.provider = provider
        self.settings = settings
        self.locks = locks
        self.versioning = versioning
        self.recorder = recorder
        self.now = now
        self.phase = phase
        self.bucketLock = bucketLock
        self.bucketDefault = bucketDefault
        self.versioningReading = versioningReading
        self.accessList = accessList
        if let loaded { adopt(loaded) }
    }

    private func fieldChanged(_ old: String, _ new: String) {
        guard old != new else { return }
        isSaved = false
    }

    // MARK: - The draft

    /// A draft field as it is sent: trimmed, and absent when empty. An empty
    /// field is "none", which a `REPLACE` copy turns into a field the object
    /// no longer has.
    private static func normalisedField(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `metadata` as the draft would send it unchanged: fields trimmed and
    /// absent when empty, custom names in the lower case the store keeps them
    /// in (Core lower-cases on the way out and on the way in).
    private static func normalised(_ metadata: ObjectMetadata) -> ObjectMetadata {
        ObjectMetadata(
            contentType: normalisedField(metadata.contentType ?? ""),
            cacheControl: normalisedField(metadata.cacheControl ?? ""),
            contentDisposition: normalisedField(metadata.contentDisposition ?? ""),
            custom: Dictionary(
                metadata.custom.map {
                    ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        $0.value.trimmingCharacters(in: .whitespacesAndNewlines))
                },
                uniquingKeysWith: { _, last in last }),
            entityTag: metadata.entityTag)
    }

    /// Takes `metadata` as what the store holds and makes it the draft.
    private func adopt(_ metadata: ObjectMetadata) {
        baseline = Self.normalised(metadata)
        contentType = metadata.contentType ?? ""
        cacheControl = metadata.cacheControl ?? ""
        contentDisposition = metadata.contentDisposition ?? ""
        custom = metadata.custom.sorted { $0.key < $1.key }.map {
            CustomRow(name: $0.key, value: $0.value)
        }
        isSaved = false
    }

    /// A pair with neither a name nor a value is an unfilled row, not a pair.
    private var filledRows: [CustomRow] {
        custom.filter {
            !($0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The prefix a custom pair travels under. The same string Core adds
    /// (`S3FileSystem.customMetadataHeaderPrefix`, which is not public), held
    /// here only to refuse a name that already carries it.
    private static let transportPrefix = "x-amz-meta-"

    /// The first reason the custom pairs cannot be sent, or `nil`. Core
    /// refuses the same names (`S3FileSystem.setMetadata`), but as a fixed
    /// "could not be saved"; the sheet says which pair and why before that.
    var draftProblem: DraftProblem? {
        var seen = Set<String>()
        for row in filledRows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return .customNameMissing }
            if name.lowercased().hasPrefix(Self.transportPrefix) { return .customNamePrefixed }
            guard name.unicodeScalars.allSatisfy({ Self.tokenCharacters.contains($0) }) else {
                return .customNameInvalid
            }
            if !seen.insert(name.lowercased()).inserted { return .customNameDuplicated }
        }
        return nil
    }

    /// The whole draft, as the request will carry it. **Every field**, changed
    /// or not (see the type's comment). Meaningful while `draftProblem` is
    /// `nil`: a pair with no name has nowhere to go and is left out, and one
    /// with a name Core would refuse is carried as typed, and `save()` does
    /// not send in either state.
    var draftMetadata: ObjectMetadata {
        ObjectMetadata(
            contentType: Self.normalisedField(contentType),
            cacheControl: Self.normalisedField(cacheControl),
            contentDisposition: Self.normalisedField(contentDisposition),
            custom: Dictionary(
                filledRows.compactMap { row -> (String, String)? in
                    let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !name.isEmpty else { return nil }
                    return (name, row.value.trimmingCharacters(in: .whitespacesAndNewlines))
                },
                uniquingKeysWith: { _, last in last }),
            entityTag: baseline?.entityTag)
    }

    /// Whether the draft differs from what the store holds. False before
    /// anything was read: there is nothing to differ from.
    var hasChanges: Bool {
        guard let baseline else { return false }
        return draftMetadata != baseline
    }

    func addCustomRow() {
        custom.append(CustomRow(name: "", value: ""))
    }

    func removeCustomRow(_ id: UUID) {
        custom.removeAll { $0.id == id }
    }

    // MARK: - The acknowledgement

    /// Whether the bucket's default retention is COMPLIANCE, which is what
    /// puts the ceremony in front of the write.
    var defaultIsCompliance: Bool {
        bucketLock == .present && bucketDefault?.mode == .compliance
    }

    /// The day the new version stays locked until if it were saved right now:
    /// a day, with no time of day (`BucketObjectLockModel.acknowledgementDate`).
    var acknowledgementDate: Date {
        let calendar = Calendar.current
        let days = bucketDefault?.days ?? 0
        let later = calendar.date(byAdding: .day, value: days, to: now()) ?? now()
        return calendar.startOfDay(for: later)
    }
    var acknowledgementDateText: String { ObjectLockDates.dayText(acknowledgementDate) }
    var acknowledgementSentence: String {
        String(
            format: ObjectMetadataLines.complianceAcknowledgement.text, acknowledgementDateText)
    }

    /// Ticked, for a day that is not the day the sentence names now. Reading
    /// `refusedSaves` is what lets a click on a stale tick redraw the sheet.
    private var acknowledgementIsStale: Bool {
        _ = refusedSaves
        return defaultIsCompliance && acknowledged && acknowledgedDay != acknowledgementDate
    }

    // MARK: - Whether it can be saved

    func isActive(_ blocker: SaveBlocker) -> Bool {
        switch blocker {
        case .metadataUnread:
            phase != .ready
        case .lockUnread:
            bucketLock == .reading
        case .lockReadFailed:
            if case .failed = bucketLock { true } else { false }
        case .draftInvalid:
            draftProblem != nil
        case .acknowledgementStale:
            acknowledgementIsStale
        case .complianceNotAcknowledged:
            defaultIsCompliance && !acknowledged
        case .unchanged:
            phase == .ready && !hasChanges
        case .applying:
            isApplying
        }
    }

    var activeBlockers: [SaveBlocker] {
        SaveBlocker.allCases.filter { isActive($0) }
    }

    var canSave: Bool { activeBlockers.isEmpty }

    static func explanation(for blocker: SaveBlocker, problem: DraftProblem?) -> CatalogueLine? {
        switch blocker {
        case .draftInvalid:
            switch problem {
            case .customNameMissing: ObjectMetadataLines.customNameMissingLine
            case .customNameInvalid: ObjectMetadataLines.customNameInvalidLine
            case .customNamePrefixed: ObjectMetadataLines.customNamePrefixedLine
            case .customNameDuplicated: ObjectMetadataLines.customNameDuplicatedLine
            case nil: nil
            }
        case .acknowledgementStale: BucketObjectLockModel.staleLine
        case .complianceNotAcknowledged: BucketObjectLockModel.notAcknowledgedLine
        case .unchanged: ObjectMetadataLines.unchangedLine
        case .metadataUnread, .lockUnread, .lockReadFailed, .applying: nil
        }
    }

    /// The sentence that says why Save is off, when there is one.
    var explanation: CatalogueLine? {
        let problem = draftProblem
        return activeBlockers.lazy.compactMap { Self.explanation(for: $0, problem: problem) }.first
    }

    /// The note about versions above the buttons, or `nil` where there is
    /// nothing true to say: a bucket that has never kept versions, or whose
    /// versioning is suspended, adds none by this write.
    var versionNote: CatalogueLine? {
        switch versioningReading {
        case .reading: nil
        case .known(.enabled): ObjectMetadataLines.versionAdded
        case .known(.suspended), .known(.never): nil
        case .unreadable: ObjectMetadataLines.versionUnknown
        }
    }

    // MARK: - Talking to the store

    /// Reads the file's metadata, whether the bucket keeps versions, and
    /// whether it has Object Lock and, if so, its default. The metadata is
    /// the sheet's; the other two are what the note and the acknowledgement
    /// are drawn from, and a failure to read either is shown, not guessed
    /// around.
    func load() async {
        phase = .reading
        bucketLock = .reading
        bucketDefault = nil
        versioningReading = .reading
        accessList = .reading
        applyFailure = nil
        isSaved = false
        // A read starts the decision over, failed or not, as the bucket
        // default's sheet does: a tick from before must not stand after it.
        acknowledged = false
        do {
            adopt(try await provider.metadata(ofKey: target.key, inBucket: target.bucket))
            // Ready BEFORE the other reads, on purpose: the fields are the
            // sheet's point and are editable as soon as they are read, and the
            // three reads after them each show their own "reading" state in
            // their own place (the versioning note is absent, the lock section
            // is empty, the access list says it is being read). So a person
            // sees the access list's reading line every time the sheet opens,
            // and `ObjectACLSectionTests` / the registry hold that state.
            phase = .ready
        } catch {
            phase = .failed(ObjectMetadataLines.readMessage(for: error))
            return
        }
        do {
            versioningReading = .known(try await versioning.versioning(target.bucket))
        } catch {
            versioningReading = .unreadable
        }
        do {
            if try await locks.hasObjectLock(target.bucket) {
                bucketLock = .present
                bucketDefault = try await Self.lockDefault(of: target.bucket, via: settings)
            } else {
                bucketLock = .absent
            }
        } catch {
            bucketLock = .failed(ObjectLockLines.message(for: error, during: .reading))
        }
        // Last of the three: the list is the one of them that decides nothing
        // about saving, and the other two decide the acknowledgement, so they
        // are not made to wait for it.
        await readAccessList()
    }

    /// Reads who holds which permission on the file. **A failure here is the
    /// section's, not the sheet's**: the metadata was read and stays editable,
    /// and the section says its own sentence. `nil` from Core is kept apart
    /// from a policy with no entries (`AccessListReading`).
    private func readAccessList() async {
        do {
            if let policy = try await provider.acl(ofKey: target.key, inBucket: target.bucket) {
                accessList = .policy(policy)
            } else {
                accessList = .notOffered
            }
        } catch {
            accessList = .failed(ObjectACLLines.readMessage(for: error))
        }
    }

    private static func lockDefault(
        of bucket: String, via settings: any S3BucketSettings
    ) async throws -> LockDefault? {
        try await settings.objectLockDefault(ofBucket: bucket).map {
            LockDefault(days: $0.days, mode: $0.mode)
        }
    }

    /// Replaces the file's metadata with the draft, if and only if nothing
    /// stands in the way, and answers how it ended (`SaveOutcome`).
    ///
    /// The order is the point:
    ///
    /// 1. **A draft equal to what the store holds writes nothing**, and asks
    ///    the store nothing either. (A draft with a pair that cannot be sent
    ///    is `.blocked` before that: `explanation` has the sentence.)
    /// 2. **The bucket's Object Lock default is read again**, immediately
    ///    before anything is written, whatever the sheet read when it opened.
    ///    A bucket without Object Lock is asked once whether it has one
    ///    (through the session's cache) and no default is read for it.
    /// 3. **Where that default is COMPLIANCE the acknowledgement must have
    ///    been given and must not be stale.** A refusal is counted so the
    ///    sheet redraws and says why; the tick is left standing, as the bucket
    ///    default's sheet leaves it, because the only sentence otherwise would
    ///    be an instruction to redo what the person has just done.
    /// 4. The write, then one line in the trail either way.
    func save() async -> SaveOutcome {
        guard phase == .ready, !isApplying else { return .blocked }
        // A pair that cannot be sent comes first: a nameless pair is left out
        // of the draft, so a draft with only that problem can compare equal to
        // what the store holds, and "nothing changed" would hide the sentence
        // that says what is wrong.
        guard draftProblem == nil else { return .blocked }
        guard hasChanges else { return .refused(.nothingChanged) }
        isApplying = true
        applyFailure = nil
        isSaved = false
        defer { isApplying = false }

        do {
            try await readLockBeforeTheWrite()
        } catch {
            // Nothing was sent, so nothing is recorded: the trail is for
            // writes and for the attempts that reached the store.
            applyFailure = ObjectLockLines.message(for: error, during: .reading)
            return .failed
        }
        if defaultIsCompliance {
            if !acknowledged {
                refusedSaves += 1
                return .refused(.complianceNotAcknowledged)
            }
            if acknowledgementIsStale {
                refusedSaves += 1
                return .refused(.acknowledgementStale)
            }
        }

        let written = draftMetadata
        let standardFieldCount =
            [written.contentType, written.cacheControl, written.contentDisposition]
            .compactMap { $0 }.count
        let complianceDays = defaultIsCompliance ? bucketDefault?.days : nil
        do {
            try await provider.setMetadata(written, ofKey: target.key, inBucket: target.bucket)
            recorder?.recordMetadataChanged(
                key: target.key, bucket: target.bucket, standardFieldCount: standardFieldCount,
                customPairCount: written.custom.count, complianceDefaultDays: complianceDays,
                failure: nil)
            baseline = written
            acknowledged = false
            isSaved = true
            // The write is done and confirmed whatever this read says. This
            // re-read is DEFENSIVE, not a measured need: a write is a REPLACE
            // copy of the file onto itself (spec section 4.5), and whether
            // that changes the file's access list is NOT measured on the rig
            // (the measurement is carried to Task 7). It runs here, after a
            // confirmed write and nowhere else, so the list on screen is not
            // one read before a write that may have changed it.
            // `ObjectACLSectionTests.theListIsReadAgainAfterAConfirmedWriteAndOnlyThen`
            // holds "only then" over every exit of `SaveOutcome` and of
            // `SaveRefusal`, derived from the declarations.
            await readAccessList()
            return .written
        } catch {
            // Three ways in, and only one of them is a change that did not
            // happen. `saveMessage(for:)` tells the storage's refusal (the
            // generic sentence, or the permission one) from a change the
            // storage ACCEPTED whose read-back did not show it, which is not a
            // failure and is not said as one.
            applyFailure = ObjectMetadataLines.saveMessage(for: error)
            // The acknowledgement is spent by a request that LEFT, not by one
            // that is known to have landed: this arm is also where a
            // connection lost after the request went out arrives, and there
            // macSCP does not know whether anything was written. On a
            // COMPLIANCE-default bucket the cost of guessing wrong is a
            // version nobody can erase, so the tick goes back to the person
            // and the next click asks for the ceremony again. A refusal
            // BEFORE the write leaves it standing (step 3 above): nothing was
            // sent.
            acknowledged = false
            recorder?.recordMetadataChanged(
                key: target.key, bucket: target.bucket, standardFieldCount: standardFieldCount,
                customPairCount: written.custom.count, complianceDefaultDays: complianceDays,
                failure: applyFailure)
            return .failed
        }
    }

    /// Reads whether the bucket has Object Lock and, if it does, its default,
    /// and takes the tick back when the default is not the one it was given
    /// for. Throws what Core throws.
    private func readLockBeforeTheWrite() async throws {
        let present = try await locks.hasObjectLock(target.bucket)
        let fresh: LockDefault? =
            present ? try await Self.lockDefault(of: target.bucket, via: settings) : nil
        if fresh != bucketDefault || (present ? BucketLock.present : .absent) != bucketLock {
            acknowledged = false
        }
        bucketLock = present ? .present : .absent
        bucketDefault = fresh
    }
}

/// The sheet behind the file menu's "Metadata…" row: the headers a person
/// edits (content type, cache control, content disposition) and the custom
/// pairs, replaced as a whole.
///
/// The target and the capabilities are captured when the sheet opens
/// (`ContentView.ObjectMetadataSheetItem`).
struct ObjectMetadataSheet: BoundedView {
    /// The size `ObjectMetadataSheet` bounds itself to, applied with
    /// `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .width(520)

    @Environment(\.dismiss) private var dismiss
    @State private var model: ObjectMetadataModel

    init(model: ObjectMetadataModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: ObjectMetadataLines.title.text, model.target.fileName))
                .font(.headline)
                .lineLimit(2)

            content

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polished)
                Button(ObjectMetadataLines.saveAction.text) {
                    // The outcome is not read here: every one of its cases
                    // is already on the model (`isSaved`, `applyFailure`,
                    // `explanation`, `refusedSaves`), which is what the sheet
                    // draws from.
                    Task { _ = await model.save() }
                }
                .buttonStyle(.polishedProminent)
                .disabled(!model.canSave)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .task {
            if model.phase == .reading {
                await model.load()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ObjectMetadataLines.reading.text).foregroundStyle(.secondary)
            }
        case .failed(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            // The form scrolls behind a height of its own. The sheet is bounded
            // in width and not in height, a bounded sheet clips instead of
            // growing, and the form's tallest state (a COMPLIANCE default, an
            // unconfirmed versioning, a pair that cannot be sent and a long
            // access list at once) is taller than a screen holds. The buttons
            // stay outside it, so Close and Save are always reachable. The
            // horizontal padding keeps a focused field's ring inside the
            // scroll view's clip.
            ScrollView(.vertical) {
                form
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.formHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The tallest the form grows before it scrolls: 490 pt, so that the whole
    /// sheet stays within the 620 pt `BucketCORSSheet.bound` grants, the tallest
    /// sheet in the app. The 130 pt left over covers the sheet's own chrome (the
    /// title, which may take two lines, the buttons and the padding), measured
    /// 2026-11-03 as 125 pt, the difference between the sheet's height and the
    /// form's 460 pt cap when the file name is long enough to wrap (German,
    /// 585 pt). `ObjectACLSectionTests.theTallestStateStaysWithinTheTallestBoundInTheApp`
    /// holds the sum.
    private static let formHeight: CGFloat = 490

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ObjectMetadataLines.replaceNote.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            field(ObjectMetadataLines.contentTypeLabel, text: $model.contentType)
            field(ObjectMetadataLines.cacheControlLabel, text: $model.cacheControl)
            field(ObjectMetadataLines.contentDispositionLabel, text: $model.contentDisposition)
            customPairs
            if let note = model.versionNote {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ObjectACLSection(display: ObjectACLDisplay.of(model.accessList))
            lockSection
            if let why = model.explanation {
                Text(why.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.applyFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isSaved {
                Text(ObjectLockLines.saved.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ label: CatalogueLine, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.text).font(.subheadline)
            TextField("", text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label.text)
        }
    }

    @ViewBuilder private var customPairs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ObjectMetadataLines.customHeading.text).font(.subheadline)
            if model.custom.isEmpty {
                Text(ObjectMetadataLines.customNone.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        pairRows
                    }
                }
                .frame(maxHeight: Self.pairListHeight)
                .scrollBounceBehavior(.basedOnSize)
            }
            Button(ObjectMetadataLines.addPair.text) { model.addCustomRow() }
                .buttonStyle(.polished)
        }
    }

    /// The tallest the list of pairs grows before it scrolls. The sheet is
    /// bounded in width, not in height, and a sheet taller than the screen is
    /// one whose buttons cannot be reached; a file can carry many pairs.
    private static let pairListHeight: CGFloat = 180

    @ViewBuilder private var pairRows: some View {
        ForEach($model.custom) { $row in
            HStack(spacing: 6) {
                TextField("", text: $row.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(ObjectMetadataLines.customNameLabel.text)
                TextField("", text: $row.value)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(ObjectMetadataLines.customValueLabel.text)
                Button {
                    model.removeCustomRow(row.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(ObjectMetadataLines.removePair.text)
                .accessibilityLabel(ObjectMetadataLines.removePair.text)
            }
        }
    }

    @ViewBuilder private var lockSection: some View {
        switch model.bucketLock {
        case .failed(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .reading, .absent, .present:
            if model.defaultIsCompliance {
                Text(ObjectMetadataLines.complianceWarning.text)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                CheckboxRow(model.acknowledgementSentence, isOn: $model.acknowledged, wraps: true)
            }
        }
    }
}

/// The read-only access-list section of the metadata sheet (spec section
/// 6.5): who holds which permission on the file, and who owns it.
///
/// **It holds no control and takes no binding.** It is handed what to show
/// and shows it; there is nothing here to click, type into or choose, because
/// the store would accept a change and keep nothing (spec section 4.6).
/// `ObjectACLSectionTests` holds that against the hosted view and against this
/// type's source.
///
/// The list scrolls behind a height of its own (`listHeight`): the sheet is
/// bounded in width and not in height, a bounded sheet clips instead of
/// growing, and a file can carry many entries.
struct ObjectACLSection: View {
    let display: ObjectACLDisplay

    /// The tallest the entries grow before they scroll: 130 pt, so that three
    /// entries show in full and part of a fourth, which is what tells a person
    /// there is more below. Held by
    /// `ObjectACLSectionTests.theListShowsThreeEntriesAndPartOfAFourth`, which
    /// measures the section alone with three, four and five entries and prints
    /// the figures (run it with `swift test --filter
    /// theListShowsThreeEntriesAndPartOfAFourth`). Measured 2026-11-03, English, 480 pt
    /// wide, the section with one to five entries: 90, 126, 162, 190 and 190 pt.
    /// So an entry steps the section by 36 pt (30 pt tall and the 6 pt spacing the
    /// stack declares), three take 102 pt of list, and 130 pt shows 22 pt of the
    /// fourth: the fourth adds 28 pt (190 minus 162) and the fifth nothing.
    static let listHeight: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ObjectACLLines.heading.text).font(.subheadline)
            Text(ObjectACLLines.readOnlyNote.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch display {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ObjectACLLines.reading.text).font(.caption).foregroundStyle(.secondary)
            }
        case .notOffered:
            note(ObjectACLLines.notOffered.text)
        case .failed(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .policy(let owner, let rows):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ObjectACLLines.owner.text).font(.caption).foregroundStyle(.secondary)
                holder(owner)
            }
            if rows.isEmpty {
                note(ObjectACLLines.noEntries.text)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                holder(row.holder)
                                Spacer(minLength: 8)
                                Text(row.permission)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.listHeight)
                .scrollBounceBehavior(.basedOnSize)
                // Focusable so that arrow keys scroll the list past its
                // visible entries: the rows are selectable text and take no
                // tab stop of their own, and a person without a pointer would
                // otherwise not reach the entries below the clip. UNVERIFIED
                // on screen (nothing can render a sheet in the test process);
                // it is on the closeout sight-check list.
                .focusable()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A holder's lines, the first in the body font and the rest beneath it.
    /// Selectable, so an identifier can be copied.
    private func holder(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .callout : .caption)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
