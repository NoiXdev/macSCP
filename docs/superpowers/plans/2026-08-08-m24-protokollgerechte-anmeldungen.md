# M24 — Protokollgerechte Anmeldungen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zwei Datenverlust- bzw. Fehlkonfigurationspfade schließen, die
entstehen, weil eine SSH-geformte Schicht protokollfremde Sitzungen durchlässt:
`LoginMergePlanner` (löscht S3-/WebDAV-Secrets) und `JumpSessionEligibility`
(bietet einen Bucket als Bastion an).

**Architecture:** Der Merge-Planner leitet seinen Gruppierungsschlüssel aus dem
`credentialSchema` des Backends ab statt aus SSH-Feldern; eine neue
`SecretRole`-Deklaration trennt „das Secret **ist** die Anmeldung" von „das
Secret **entsperrt** eine Anmeldung". Die Jump-Lücke wird am Resolver
geschlossen, nicht nur im Picker — ein Picker-Filter schützt nur neue Daten.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-08-m24-protokollgerechte-anmeldungen-design.md`

## Global Constraints

- **Code und Kommentare: nur Englisch.** Bezeichner, Doc-Kommentare,
  Inline-Kommentare, Testnamen, `reason:`-Strings. Kein Deutsch in Quelldateien.
- **Commit-Messages: Englisch, Conventional Commits** (CI erzwingt das).
  Footer auf jedem Commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit/Push nur auf ausdrückliche Anfrage.** Kein `scripts/release`.
- **Ein Secret-Wert darf nie geloggt, gedruckt oder in einen Fehler eingebettet
  werden.** Secrets leben ausschließlich im Keychain (`SecretStore`); JSON-Stores
  enthalten nie welche.
- **Nie Schlüsselmaterial committen.**
- **App-UI ist lokalisiert**, vier Kataloge mit identischen Schlüsselmengen:
  `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`.
  `LocalizableStringsTests` erzwingt die Parität. **CLI-Ausgabe ist nicht
  lokalisiert.**
- **Die GUI-App nicht starten.**
- Tests: `swift test`. Gegatet: `MACSCP_ITEST=1` (Docker-Rig) und
  `MACSCP_KEYCHAIN=1` (echter Keychain).
- Sitzungen in Tests **immer** über die Fixtures aus
  `Tests/macSCPCoreTests/SessionFixtures.swift` bauen (`sshSession`,
  `s3Session`, `webdavSession`) — nie `StoredSession` direkt.

---

## File Structure

| Datei | Verantwortung | Task |
|---|---|---|
| `Sources/macSCPCore/Capabilities/FieldVocabulary.swift` | `SecretRole` deklarieren | 1 |
| `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift` | `ConnectionField.secretRole` tragen | 1 |
| `Sources/macSCPCore/{SSH,S3,WebDAV}/*FieldSchema.swift` | Rolle je Secret-Feld deklarieren | 1 |
| `Sources/macSCPCore/Sessions/LoginMergePlanner.swift` | Schlüssel aus dem Schema; Kandidatenform | 2 |
| `Sources/MacSCPApp/LoginSetsSheet.swift` | drei Lesestellen auf `displayLabel` | 2, 3 |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | `applyMerge` generisch + Riegel; `suggestedSetName`; `delete`-Guard | 3, 5 |
| `Sources/macSCPCore/Sessions/JumpSessionEligibility.swift` | `kind`-Filter | 4 |
| `Sources/macSCPCore/Sessions/LoginResolver.swift` | harter Riegel + neuer Fehlerfall | 4 |
| `Sources/MacSCPApp/{ContentView,ConnectionFormView}.swift` | drei `catch`-Arme | 4 |
| `Sources/MacSCPApp/Resources/*.lproj/Localizable.strings` | ein neuer Schlüssel × 4 | 4 |

**Zu Testdateien:** Neue Tests gehören in die bestehende Suite des Typs, den sie
prüfen (`LoginMergePlannerTests`, `JumpSessionEligibilityTests`,
`LoginResolverTests`, `SessionListViewModelTests`, `BackendDescriptorTests`).
Keine neue Testdatei anlegen.

---

## Warum die Tests hier als Tabelle stehen und nicht als Code

M23 hat zehn Defekte gefunden, die **im Plan** steckten und nicht in der
Umsetzung; das Muster war stabil genug, um es zu benennen: *vom Planautor
geschriebener, nie ausgeführter Testcode ist der unzuverlässigste Teil eines
Plans.* Produktionscode steht deshalb unten wörtlich, Tests dagegen als Tabelle
aus (Name, Aufbau, Erwartung) plus einem Zeiger auf die Datei, deren Form zu
kopieren ist. Wer den Test schreibt, führt ihn auch aus.

---

## Task 1: `SecretRole` deklarieren

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/FieldVocabulary.swift` (neues Enum ans Ende, neben `FieldIdentity`)
- Modify: `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift:4-83` (`ConnectionField`)
- Modify: `Sources/macSCPCore/SSH/SSHFieldSchema.swift:156-168` (`password`, `passphrase`)
- Modify: `Sources/macSCPCore/S3/S3FieldSchema.swift:86-90` (`secretAccessKey`)
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift:72-74` (`password`)
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`

**Interfaces:**
- Produces: `SecretRole` mit den Fällen `.credential` und `.passphrase`;
  `ConnectionField.secretRole: SecretRole?` (Default `nil`), gesetzt über den
  neuen Init-Parameter `secretRole: SecretRole? = nil` **als letzter
  Parameter**, damit kein bestehender Aufruf umgestellt werden muss.

- [ ] **Step 1: `SecretRole` anlegen**

Ans Ende von `FieldVocabulary.swift`:

```swift
/// What a secret field's value MEANS for the identity of a login (M24) — the
/// answer to "do these two sessions log in as the same principal?", which
/// `LoginMergePlanner` asks before offering to fold them into one login set.
///
/// Two cases, because there are two real behaviours. A password and an S3
/// secret access key ARE the credential: two logins with different ones are
/// different logins, and merging them would bind both to a set that can only
/// carry one — destroying the other's Keychain entry. An SSH passphrase is
/// not: it unlocks a key file that another field (`keyPath`) already names, so
/// two sessions on the same key file are the same login whether or not either
/// happens to have the passphrase stored.
///
/// NOT derivable from `isRequired`, which was the first thing tried. That
/// gives the right answer for SSH and S3 and the WRONG one for WebDAV, whose
/// password is optional since M23 so that anonymous shares work — a WebDAV
/// password would then leave the identity key, and two sessions with the same
/// user name and DIFFERENT passwords would collide.
public enum SecretRole: Sendable, Equatable {
    /// The secret is the credential itself.
    case credential
    /// The secret unlocks a credential named by another field.
    case passphrase
}
```

- [ ] **Step 2: `ConnectionField` trägt die Rolle**

In `ConnectionFieldSchema.swift`, nach der `identity`-Property:

```swift
    /// For a `.secret` field: whether its value takes part in a login's
    /// identity (M24). Meaningless — and never set — on any other kind.
    ///
    /// Optional in the type, mandatory in practice, exactly like
    /// `invalidMessageKey`: `everySecretFieldDeclaresItsRole` fails the build
    /// for a secret field without one. The readers treat a missing role as
    /// `.credential`, which is the SAFE direction — the secret then enters the
    /// identity key, and two logins that differ in it are kept apart rather
    /// than merged.
    public let secretRole: SecretRole?
```

Init-Parameter **als letzter** ergänzen und zuweisen:

```swift
    public init(id: String, labelKey: String, labelDefault: String,
                kind: Kind, visibleWhen: FieldCondition? = nil,
                isRequired: Bool = false, format: FieldFormat? = nil,
                invalidMessageKey: String? = nil, identity: FieldIdentity? = nil,
                secretRole: SecretRole? = nil) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
        self.kind = kind; self.visibleWhen = visibleWhen; self.isRequired = isRequired
        self.format = format; self.invalidMessageKey = invalidMessageKey
        self.identity = identity; self.secretRole = secretRole
    }
```

- [ ] **Step 3: Den Wächter schreiben (rot)**

In `Tests/macSCPCoreTests/BackendDescriptorTests.swift`, direkt nach
`everyBackendDeclaresANonSecretIdentity` (Zeile 109–123) — dessen Form kopieren:
Schleife über `ConnectionKind.allCases`, `#expect` mit
`Comment(rawValue:)`-Begründung.

| Test | Aufbau | Erwartung |
|---|---|---|
| `everySecretFieldDeclaresItsRole` | für jeden `kind` beide Schemas (`connectionSchema.fields + credentialSchema.fields`) durchgehen | jedes Feld mit `isSecret == true` hat `secretRole != nil`; die Begründung nennt `kind` und `field.id` und sagt, dass ein fehlender Wert als `.credential` gelesen wird |
| `noNonSecretFieldDeclaresASecretRole` | dieselbe Schleife | jedes Feld mit `isSecret == false` hat `secretRole == nil` — verhindert eine Rolle an einem Feld, das nie als Secret gelesen wird |

- [ ] **Step 4: Rot bestätigen**

Run: `swift test --filter BackendDescriptor`
Expected: `everySecretFieldDeclaresItsRole` schlägt fehl (vier Felder ohne Rolle).

- [ ] **Step 5: Die vier Rollen deklarieren**

Jeweils als letztes Argument des betroffenen `ConnectionField(...)`:

- `SSHField.password` → `secretRole: .credential`
- `SSHField.passphrase` → `secretRole: .passphrase`
- `S3Field.secretAccessKey` → `secretRole: .credential`
- `WebDAVField.password` → `secretRole: .credential`

An `SSHField.passphrase` den vorhandenen Kommentar („The passphrase stays
OPTIONAL…") um einen Satz ergänzen: die Rolle sagt, dass die Passphrase die
Anmeldung nicht identifiziert — die Schlüsseldatei tut das über `keyPath`.

- [ ] **Step 6: Grün bestätigen**

Run: `swift test --filter BackendDescriptor`
Expected: PASS. Danach `swift build` (inkl. App-Target) ohne neue Warnungen.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/BackendDescriptorTests.swift
git commit -m "feat(core): declare what a secret field means for login identity"
```

---

## Task 2: Merge-Schlüssel aus dem Schema

**Files:**
- Modify: `Sources/macSCPCore/Sessions/LoginMergePlanner.swift` (ganze Datei)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift:515-535` (Banner) und `:541-553` (Bestätigungstext)
- Test: `Tests/macSCPCoreTests/LoginMergePlannerTests.swift`

**Interfaces:**
- Consumes: `ConnectionField.secretRole` aus Task 1.
- Produces: `LoginMergeCandidate(kind: ConnectionKind, values: FieldValues,
  displayLabel: String, sessionIDs: [UUID])`. `LoginMergePlanner.candidates(
  sessions:ignoredGroups:secrets:)` behält seine Signatur.

**Warum App und Core in EINEM Task:** die Kandidatenform ist `public` und wird
von `LoginSetsSheet` gelesen. Getrennt committet wäre `swift build` zwischen
den beiden Tasks rot — die Hausregel ist ein sauberer Build inklusive
App-Target an jedem Task-Ende.

- [ ] **Step 1: Die bestehenden SSH-Tests übersetzen (rot)**

Nur die drei weggefallenen Properties umlesen, **nichts an Eingaben, an
`sessionIDs` oder an der Kandidatenzahl ändern**:

| vorher | nachher |
|---|---|
| `candidate.username == "deploy"` | `candidate.displayLabel == "deploy"` |
| `candidate.authKind == .privateKey` | `candidate.values[SSHField.authKind] == "privateKey"` |
| `candidate.keyPath == "/k1"` | `candidate.values[SSHField.keyPath] == "/k1"` |

Muss darüber hinaus etwas angefasst werden, ist das ein **Befund** und gehört
in den Task-Bericht, nicht stillschweigend weggeschrieben (Spec, Kriterium 4).

- [ ] **Step 2: Die neuen Tests schreiben (rot)**

Anfügen an `LoginMergePlannerTests`. Aufbau der bestehenden Tests kopieren:
`InMemorySecretStore`, Sitzungen über die Fixtures, `#expect` auf
`candidates.count` und `sessionIDs`.

| Test | Aufbau | Erwartung |
|---|---|---|
| `twoS3SessionsSharingACredentialPairAreOneCandidate` | zwei `s3Session`, identische `StoredS3Config` bis auf `bucket`, **gleicher** Secret unter beiden Sitzungs-IDs | ein Kandidat, `kind == .s3`, `sessionIDs == [a.id, b.id]`, `displayLabel == "AKIA"`, `values[S3Field.accessKeyID] == "AKIA"` |
| `twoS3SessionsWithDifferentSecretsAreNotACandidate` | wie oben, aber **verschiedene** Secrets | `candidates.isEmpty` |
| `twoS3SessionsWithDifferentAccessKeyIDsAreNotACandidate` | gleicher Secret, verschiedene `accessKeyID` | `candidates.isEmpty` |
| `twoWebDAVSessionsWithDifferentPasswordsAreNotACandidate` | zwei `webdavSession`, gleicher `username`, verschiedene Secrets | `candidates.isEmpty` — **der Test, den die `isRequired`-Ableitung nicht bestanden hätte** |
| `twoWebDAVSessionsSharingAPasswordAreOneCandidate` | gleicher `username`, gleicher Secret | ein Kandidat, `kind == .webdav`, `displayLabel` == der Benutzername |

`webdavSession` hat **keinen** `username:`-Parameter — der Benutzername kommt
über `config: StoredWebDAVConfig(baseURL:username:useNextcloudPath:)`. Dasselbe
gilt für S3: `s3Session(config: StoredS3Config(...))`.
| `anS3AndAnSSHSessionNeverShareACandidate` | eine `sshSession` und eine `s3Session`, **derselbe** Secret unter beiden IDs | `candidates.isEmpty` — der `kind` steht im Schlüssel |
| `privateKeySessionsGroupWithoutReadingTheKeychain` | zwei `sshSession` mit `authKind: .privateKey`, gleichem `keyPath`, und ein `SecretStore`, dessen `password(for:)` den Test scheitern lässt | ein Kandidat; der Store wurde nie gelesen. **Form kopieren von** dem lesefeindlichen Store, den `agentSetResolvesWithoutKeychainRead` in `LoginResolverTests` benutzt (am Ende von `LoginMergePlannerTests.swift` steht bereits ein solcher Test-Double) |
| `anonymousWebDAVSessionsAreNeverACandidate` | zwei `webdavSession` mit leerem `username` und **ohne** Keychain-Eintrag | `candidates.isEmpty` |

- [ ] **Step 3: Rot bestätigen**

Run: `swift test --filter LoginMergePlanner`
Expected: Kompilierfehler (die neuen Properties existieren nicht) — das ist der
rote Zustand für diesen Task.

- [ ] **Step 4: Kandidat und Planner neu schreiben**

`LoginMergePlanner.swift` vollständig ersetzen:

```swift
import Foundation

/// A group of manual sessions that log in as the same principal (M10b spec §4,
/// generalized to every protocol in M24) — the "merge into one set?"
/// suggestion the UI banners.
public struct LoginMergeCandidate: Equatable, Sendable {
    /// Every session in the group has this kind, and the set a merge creates
    /// gets it. Part of the grouping key, so a group is never mixed.
    public var kind: ConnectionKind
    /// The credential values the group shares, in the backend's own field
    /// vocabulary — the visible non-secret credential fields, and NOTHING
    /// else. Never the secret: this value is handed to the UI and to
    /// `BackendDescriptor.loginSet(id:name:from:)`, and a secret has no
    /// business in either.
    public var values: FieldValues
    /// What to call this login on screen — the first visible non-secret
    /// credential field's value. The user name for SSH and WebDAV, the access
    /// key ID for S3.
    public var displayLabel: String
    public var sessionIDs: [UUID]

    public init(
        kind: ConnectionKind, values: FieldValues, displayLabel: String, sessionIDs: [UUID]
    ) {
        self.kind = kind
        self.values = values
        self.displayLabel = displayLabel
        self.sessionIDs = sessionIDs
    }
}

/// Grouping key: two sessions merge only if every part here matches.
///
/// `fields` holds the visible NON-SECRET credential fields by namespaced key.
/// Which fields those are is the backend's answer, not this file's — SSH shows
/// `keyPath` only under private-key auth, so the same code produces the
/// pre-M24 SSH key without naming SSH.
private struct LoginGroupKey: Hashable {
    var kind: ConnectionKind
    var fields: [String: String]
    var secret: String?
}

/// Pure equality detection over MANUAL sessions (loginSetID == nil).
/// Secret values are compared in memory only and never leave this function.
public enum LoginMergePlanner {
    public static func candidates(
        sessions: [StoredSession], ignoredGroups: [Set<UUID>], secrets: any SecretStore
    ) -> [LoginMergeCandidate] {
        // `order` tracks first-seen order of each key so ties fall back to
        // input order deterministically; `groups` accumulates session ids in
        // the order sessions were encountered.
        var order: [LoginGroupKey] = []
        var groups: [LoginGroupKey: [UUID]] = [:]
        var labels: [LoginGroupKey: String] = [:]
        var credentials: [LoginGroupKey: FieldValues] = [:]

        for session in sessions where session.loginSetID == nil {
            let descriptor = BackendDescriptor.descriptor(for: session.kind)
            // A session whose kind claims a block it does not carry is broken
            // stored data. It has no credentials to compare, and reading
            // through `StoredSession`'s SSH fallbacks would group it on
            // ""/.password — the placeholder M23 removed, in a new place.
            guard descriptor.hasStoredConfiguration(session) else { continue }

            let namespace = descriptor.fieldNamespace
            let storedValues = descriptor.sessionValues(session)
            let visible = descriptor.credentialSchema.visibleFields(
                in: storedValues, namespace: namespace)

            var fields: [String: String] = [:]
            var values = FieldValues()
            var label: String?
            for field in visible where !field.isSecret {
                let key = "\(namespace).\(field.id)"
                // Compared VERBATIM, like every part of this key: this asks
                // whether two logins are the same, and a user name differing
                // in case or padding is a different user name. (Distinct from
                // `FieldIdentity`, which answers "same CONNECTION?" for import
                // dedup and which `authKind` does not even carry.)
                let raw = storedValues.raw[key] ?? ""
                fields[key] = raw
                values.setRaw(key, to: raw)
                if label == nil { label = raw }
            }

            var secret: String?
            if let secretField = visible.first(where: \.isSecret) {
                // `.passphrase` unlocks a key file `keyPath` already put in
                // the key, so it neither enters the key nor justifies a
                // Keychain read. A missing role reads as `.credential`: the
                // safe direction, keeping logins apart rather than merging
                // them. And a secret-less session under `.credential` has
                // nothing to compare, so it cannot take part at all -- which
                // is the pre-M24 SSH rule, now applied to every backend.
                if secretField.secretRole != .passphrase {
                    guard let stored = (try? secrets.password(for: session.id)) ?? nil else {
                        continue
                    }
                    secret = stored
                }
            }

            let key = LoginGroupKey(kind: session.kind, fields: fields, secret: secret)
            if groups[key] == nil {
                order.append(key)
                labels[key] = label ?? ""
                credentials[key] = values
            }
            groups[key, default: []].append(session.id)
        }

        let candidates: [LoginMergeCandidate] = order.compactMap { key in
            guard let sessionIDs = groups[key], sessionIDs.count >= 2 else { return nil }
            let idSet = Set(sessionIDs)
            // A candidate that's already fully covered by a previously
            // ignored group (same ids, or a superset) stays suppressed until
            // a new member makes it no longer a subset.
            if ignoredGroups.contains(where: { idSet.isSubset(of: $0) }) { return nil }
            return LoginMergeCandidate(
                kind: key.kind, values: credentials[key] ?? FieldValues(),
                displayLabel: labels[key] ?? "", sessionIDs: sessionIDs)
        }

        return candidates.sorted { a, b in
            let labelOrder = a.displayLabel.localizedCaseInsensitiveCompare(b.displayLabel)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            // Two protocols can produce the same label; without this the order
            // between them would depend on input order alone.
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.sessionIDs.count < b.sessionIDs.count
        }
    }
}
```

- [ ] **Step 5: Die App-Lesestellen nachziehen**

In `LoginSetsSheet.swift`: `candidate.username` → `candidate.displayLabel` im
Banner (`mergeBanner`) und `mergeCandidate.username` → `mergeCandidate.displayLabel`
in `mergeConfirmMessage` und `applyMerge()`. Der Aufruf
`suggestedSetName(forUsername:)` bleibt in diesem Task unverändert und bekommt
`displayLabel` übergeben; umbenannt wird er in Task 3.

Am Bannertext nichts ändern: „%lld connections use the same login “%@”." gilt
für jedes Protokoll wörtlich weiter.

- [ ] **Step 6: Grün bestätigen**

Run: `swift test --filter LoginMergePlanner`
Expected: PASS.
Run: `swift build`
Expected: sauber inklusive App-Target.

- [ ] **Step 7: Den Charakterisierungstest zur Zusage umschreiben**

`nonSSHSessionsSharingASecretAreStillOfferedAsAMergeCandidate` in
`LoginMergePlannerTests.swift` ist jetzt falsch. **Nicht löschen** — umschreiben
zu `twoS3SessionsSharingACredentialPairMergeIntoAnS3Set` (oder in Step 2 bereits
so angelegt und hier nur den alten entfernen, wenn er inhaltlich vollständig
darin aufgeht). Der Doc-Kommentar sagt künftig, was gilt, und nennt M24 als die
Stelle, an der es sich geändert hat.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/Sessions/LoginMergePlanner.swift Sources/MacSCPApp/LoginSetsSheet.swift Tests/macSCPCoreTests/LoginMergePlannerTests.swift
git commit -m "fix(core): derive the merge key from the credential schema"
```

---

## Task 3: `applyMerge` baut ein Set des richtigen Protokolls

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:597-644` (`applyMerge`) und `:651-659` (`suggestedSetName`)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (Aufrufe von `suggestedSetName`)
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `LoginMergeCandidate` aus Task 2.
- Produces: `suggestedSetName(forLabel:) -> String` (umbenannt von
  `forUsername:`); `applyMerge(_:name:) -> LoginSet?` unverändert in der
  Signatur.

- [ ] **Step 1: Die Tests schreiben (rot)**

Anfügen an `SessionListViewModelTests`; Aufbau der vorhandenen Merge-Tests
(um Zeile 1880) kopieren.

| Test | Aufbau | Erwartung |
|---|---|---|
| `mergingTwoS3SessionsCreatesAnS3SetCarryingTheAccessKeyID` | zwei `s3Session` mit gleichem `accessKeyID` und gleichem Secret, gespeichert; `mergeCandidates().first!` → `applyMerge(_:name: "acct")` | das zurückgegebene Set hat `kind == .s3` und trägt den `accessKeyID`; beide Sitzungen zeigen mit `loginSetID` darauf |
| `mergingCarriesTheSecretOntoTheSetBeforeDeletingTheSessionSlots` | wie oben | unter `set.id` liegt genau der geteilte Secret; unter beiden Sitzungs-IDs liegt keiner mehr |
| `applyMergeRefusesACandidateWhoseSessionsAreOfMixedKind` | einen `LoginMergeCandidate` **von Hand** bauen: `kind: .s3`, aber `sessionIDs` = eine S3- **und** eine SSH-Sitzung | Rückgabe `nil`; **kein** Set angelegt (`loginSets` unverändert), **kein** Secret gelöscht, beide Sitzungen unverändert. Der Riegel ist über den Planner nicht erreichbar — deshalb wird der Kandidat direkt konstruiert |

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: die drei neuen Tests scheitern (`applyMerge` baut ein `.ssh`-Set).

- [ ] **Step 3: `applyMerge` umbauen**

Den Rumpf bis einschließlich der Set-Erzeugung ersetzen; **alles ab dem
Secret-Transport bleibt wörtlich, wie es ist** (Quelle, Rollback, Löschen der
Sitzungs-Slots — dieser Teil war nie das Problem):

```swift
    public func applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet? {
        let groupSessions = candidate.sessionIDs.compactMap { id in
            sessions.first { $0.id == id }
        }
        guard let first = groupSessions.first else { return nil }
        // Defense in depth (M24). `LoginMergePlanner` puts the kind in its
        // grouping key, so a mixed group cannot come from there -- but this
        // function DELETES Keychain entries, and a candidate reaches it as a
        // plain value that anything could have built. Refusing here costs
        // nothing and turns "the planner guarantees it" from a comment into a
        // fact. Refusing means changing nothing at all: no set, no rewiring,
        // no deletion, so the banner simply stays.
        guard groupSessions.allSatisfy({ $0.kind == candidate.kind }) else { return nil }

        let descriptor = BackendDescriptor.descriptor(for: candidate.kind)
        let set = descriptor.loginSet(id: UUID(), name: name, from: candidate.values)
        do {
            try loginSetStore.upsert(set)
        } catch {
```

- [ ] **Step 4: `suggestedSetName` umbenennen**

`forUsername username: String` → `forLabel label: String`, Rumpf unverändert
(nur die lokale Variable umbenennen). Doc-Kommentar: der Name kommt aus dem
`displayLabel` des Kandidaten und ist bei S3 eine Access Key ID, kein
Benutzername. Beide Aufrufstellen in `LoginSetsSheet.swift` nachziehen.

- [ ] **Step 5: Grün bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: PASS.
Run: `swift build`
Expected: sauber inklusive App-Target.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Sources/MacSCPApp/LoginSetsSheet.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): merge into a login set of the candidate's own protocol"
```

---

## Task 4: Der Jump-Host-Riegel

**Files:**
- Modify: `Sources/macSCPCore/Sessions/JumpSessionEligibility.swift:9-15`
- Modify: `Sources/macSCPCore/Sessions/LoginResolver.swift:5-18` (Fehlerfall) und `:183-213` (`resolveJump`)
- Modify: `Sources/MacSCPApp/ContentView.swift:2166` und `:2614` (je ein `catch`-Arm)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift:231` (ein `catch`-Arm)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/JumpSessionEligibilityTests.swift`, `Tests/macSCPCoreTests/LoginResolverTests.swift`

**Interfaces:**
- Produces: `LoginResolveError.jumpSessionNotSSH`.

- [ ] **Step 1: Die Tests schreiben (rot)**

| Test | Datei | Aufbau | Erwartung |
|---|---|---|---|
| `onlySSHSessionsAreOfferedAsJumpHosts` | `JumpSessionEligibilityTests` | eine `sshSession` und eine `s3Session` | `eligible == [ssh]`. **Das ist der umgeschriebene** `nonSSHSessionsAreStillOfferedAsJumpHosts` — nicht löschen, umschreiben, Doc-Kommentar auf die neue Zusage drehen |
| `resolveJumpRefusesANonSSHReferencedSession` | `LoginResolverTests` | `JumpSpec` mit `sessionID` = die ID einer `s3Session`, diese in `sessions` | wirft `LoginResolveError.jumpSessionNotSSH` |
| `resolveJumpStillRefusesAMissingSessionFirst` | `LoginResolverTests` | `sessionID` zeigt auf eine **nicht** in `sessions` enthaltene ID | wirft `.missingJumpSession`, nicht `.jumpSessionNotSSH` — pinnt die Reihenfolge der Guards |
| `resolveJumpAcceptsAnSSHReferencedSession` | `LoginResolverTests` | bestehender Positivfall | unverändert grün (Regressionsklammer) |

Aufbau der `JumpSpec`-Konstruktion aus den vorhandenen `resolveJump`-Tests in
`LoginResolverTests` kopieren.

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter "JumpSessionEligibility|LoginResolver"`
Expected: die ersten beiden neuen Tests scheitern.

- [ ] **Step 3: Den Fehlerfall anlegen**

In `LoginResolver.swift`, in `LoginResolveError` nach `jumpChainNotSupported`:

```swift
    /// A jump's `sessionID` points at a session that is not an SSH
    /// connection. Only SSH tunnels: an object-storage or WebDAV session has
    /// no host to dial through, and reading one's host/port yields
    /// `StoredSession`'s SSH fallbacks ("" and 22) — a bastion nobody can
    /// reach, offered without complaint.
    ///
    /// Distinct from `kindMismatch`, which is about a session and its LOGIN
    /// SET disagreeing. Naming that one here would report the wrong cause.
    case jumpSessionNotSSH
```

- [ ] **Step 4: Den Picker filtern**

```swift
        sessions
            .filter { $0.kind == .ssh && $0.id != editingSessionID && $0.jump == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
```

Den Doc-Kommentar des Typs um den `kind`-Grund ergänzen (nur SSH tunnelt) und
darauf hinweisen, dass der Filter allein nicht reicht — der Riegel im Resolver
deckt bereits gespeicherte Referenzen ab.

- [ ] **Step 5: Den Riegel setzen**

In `resolveJump(spec:sets:secrets:sessions:referencingSessionID:)`, **nach**
dem `missingJumpSession`-Guard und **vor** dem Ketten-Guard:

```swift
        // The kind check comes before the chain check because it is the more
        // fundamental objection: a bucket is not a bastion whether or not it
        // also happens to carry a jump. `JumpSessionEligibility` keeps new
        // configurations from getting here; this covers the ones already on
        // disk, which no picker filter can reach.
        guard referenced.kind == .ssh else {
            throw LoginResolveError.jumpSessionNotSSH
        }
```

- [ ] **Step 6: Die drei `catch`-Stellen und die L10n**

Neuer Schlüssel `form.jump.session.notSSH`, englischer Default:
`"Only SSH connections can be used as a jump host."` Der Schlüssel muss in
**allen vier** Katalogen stehen (DE/FR/PL übersetzt).

In `ContentView.swift` an beiden Stellen einen Arm nach
`catch LoginResolveError.jumpChainNotSupported` einfügen, der Form der
Nachbararme folgend (`form.showFailure(message:field: .jumpSession)`).

In `ConnectionFormView.swift` einen Arm vor dem generischen `catch` einfügen —
**ohne ihn fiele der neue Fehler in den Fallback** „The connection used as jump
host no longer exists.", der hier die Unwahrheit sagen würde.

- [ ] **Step 7: Grün bestätigen**

Run: `swift test --filter "JumpSessionEligibility|LoginResolver"`
Expected: PASS.
Run: `swift test --filter Localizable`
Expected: PASS (Parität über alle vier Kataloge).
Run: `swift build`
Expected: sauber inklusive App-Target.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore Sources/MacSCPApp Tests/macSCPCoreTests
git commit -m "fix(core): refuse a non-SSH session as a jump host"
```

---

## Task 5: `delete` schreibt keinen Platzhalter-Host

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:230-278`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: nichts aus früheren Tasks. `JumpRestoreResult` bleibt unverändert.

- [ ] **Step 1: Die Tests schreiben (rot)**

| Test | Aufbau | Erwartung |
|---|---|---|
| `deletingANonSSHBastionRestoresNothing` | eine `s3Session` als Bastion, eine `sshSession` mit `jump.sessionID` darauf; beide gespeichert; `delete(bucket)` | `result.restored == 0`; der `JumpSpec` der verweisenden Sitzung ist **unverändert** (`sessionID` steht noch, `host` ist **nicht** `""`); die S3-Sitzung ist gelöscht |
| `deletingAnSSHBastionStillRestores` | bestehender Positivfall | unverändert grün — die Regressionsklammer für den Guard |

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: `deletingANonSSHBastionRestoresNothing` scheitert (`host` ist `""`).

- [ ] **Step 3: Den Guard setzen**

In `delete(_:)`, direkt nach `let affected = sessionsUsingAsJump(session.id)`:

```swift
        // Restoration copies the deleted session's host, port and login into
        // every jump that referenced it. Only an SSH session HAS those: for
        // any other kind `session.host`/`session.port` are `StoredSession`'s
        // SSH fallbacks, and copying them writes a bastion nobody can dial
        // into someone else's configuration, looking configured.
        //
        // Leaving the reference dangling instead is the honest outcome: the
        // next connect reports `.missingJumpSession` -- "the connection used
        // as jump host no longer exists" -- which is true and actionable.
        // Such a reference can only exist in data written before M24; the
        // picker no longer offers one and `LoginResolver.resolveJump` now
        // refuses one.
        let affected = session.kind == .ssh ? sessionsUsingAsJump(session.id) : []
```

(Die bestehende Zeile ersetzen, nicht eine zweite daneben setzen.)

- [ ] **Step 4: Grün bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): do not restore a jump from a non-SSH bastion"
```

---

## Task 6: Meilenstein-Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-08-m24-abschluss.md`
- Modify: ggf. `Sources/macSCPCore/Sessions/StoredSession.swift` (siehe Step 4)

- [ ] **Step 1: Die volle Suite**

```bash
swift build
swift test
```
Expected: sauber, keine neuen Warnungen; Testzahl **über** dem Stand vor M24
(1571) — kein Netto-Verlust an Testfunktionen. Zahl notieren.

- [ ] **Step 2: Die gegateten Suiten**

Das Rig aus dem **Haupt-Checkout** starten, nie aus einem Worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
```

Dann:
```bash
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```
Expected: beide grün. Bleibt ein Lauf bei 0 % CPU stehen, ist das der seit M20
bekannte Hänger — abbrechen und neu starten, im Bericht vermerken, **nicht**
als M24-Befund zählen.

- [ ] **Step 3: Die Kataloge**

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```
Expected: für jede Datei `OK`.

- [ ] **Step 4: Die vier Accessoren prüfen (Ergebnis offen)**

```bash
grep -rn "\.host\b\|\.port\b\|\.username\b\|\.authKind\b" Sources/ --include=*.swift | grep -v "SSHFieldSchema\|StoredSSHConfig\|ssh\?\."
```

Jeden verbleibenden Leser von `StoredSession.host`/`port`/`username`/`authKind`
danach beurteilen, ob er SSH-geschützt ist. **Sind alle geschützt, die vier
Accessoren löschen** und die Suite erneut fahren. Sind sie es nicht, die
ungeschützten Leser im Abschlussbericht **namentlich** auflisten und die
Accessoren stehen lassen. Beides ist ein zulässiges Ergebnis — die Spec sagt
ausdrücklich, dass hier nichts zugesagt wurde.

- [ ] **Step 5: Den Abschlussbericht schreiben**

`docs/superpowers/specs/2026-08-08-m24-abschluss.md`, Form von
`2026-08-07-m23-abschluss.md` kopieren. Muss enthalten:

- Verifikation zum Abschluss (Testzahlen, gegatete Läufe, Kataloge)
- Die acht Erfolgskriterien aus der Spec mit Ergebnis — jedes mit dem Beleg,
  nicht mit einer Behauptung
- Das Ergebnis von Step 4
- Die drei Release-Notes-Punkte aus der Spec, ergänzt um alles, was während der
  Umsetzung dazukam
- Jeden Befund aus Task 2, Step 1 (unzulässige Testanpassungen)
- Was offen bleibt: der Testsuite-Hänger, verwaiste Jump-Keychain-Slots, die
  acht toten Form-Shims

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-08-08-m24-abschluss.md
git commit -m "docs(m24): record the milestone close"
```

- [ ] **Step 7: Push NICHT ausführen**

Der Push erfolgt ausschließlich auf ausdrückliche Anordnung des Maintainers.
Im Bericht vermerken, wie viele Commits unversendet auf `develop` liegen.

---

## Selbstreview des Plans

**Spec-Abdeckung.** Alle acht Erfolgskriterien haben einen Task: 1 → T3, 2 →
T2, 3 → T3, 4 → T2/Step 1, 5 → T2 (`privateKeySessionsGroupWithoutReadingTheKeychain`),
6 → T4, 7 → T5, 8 → T2/Step 7 und T4/Step 1. `SecretRole` → T1. Die
Nicht-Migration ist eine Unterlassung und braucht keinen Task; dass sie
beabsichtigt ist, steht im Kommentar aus T5/Step 3.

**Typkonsistenz.** `LoginMergeCandidate` wird in T2 mit
`(kind:values:displayLabel:sessionIDs:)` definiert und in T3
(`candidate.values`, `candidate.kind`) sowie in T2/Step 5
(`candidate.displayLabel`) genau so gelesen. `suggestedSetName(forLabel:)` wird
in T3 umbenannt und nur dort aufgerufen. `SecretRole` wird in T1 definiert und
in T2 als `secretField.secretRole != .passphrase` gelesen.

**Eine bewusste Abweichung von der Skill-Vorgabe:** Testcode steht als Tabelle
statt als Quelltext, mit Zeiger auf die zu kopierende Form. Begründung oben im
eigenen Abschnitt.
