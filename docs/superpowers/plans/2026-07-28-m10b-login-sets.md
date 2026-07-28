# M10b — Login-Sets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wiederverwendbare, benannte Logins (Username + Passwort ODER Key), referenzierbar aus Verbindungen, mit Verwaltungs-Sheet (⌘⇧L), Dreiweg-Auswahl im Formular und Merge-Vorschlag für gleiche bestehende Logins; Set-Löschen stellt betroffene Verbindungen verlustfrei auf Manuell zurück.

**Architecture:** `LoginSet` (Core) mit eigenem `LoginSetStore` (`logins.json`, Record-basiert für Vorwärtskompatibilität), `StoredSession.loginSetID` (decode-kompatibel wie `groupID`), `LoginResolver` als reine Auflösungsfunktion, `LoginMergePlanner` als reine Gruppierungsfunktion; alle mutierenden Abläufe (CRUD, Lösch-Rückstellung, Merge-Anwendung, Export-Auflösung) leben in `SessionListViewModel`, das bereits SessionStore + SecretStore besitzt. Die App verdrahtet Sheet, Menü und Dreiweg-Formular.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI, macOS Keychain via bestehendem `SecretStore`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m10b-login-sets-design.md` — bindend. Mockup: `docs/design/assets/m10-mockups.html` Abschnitte 3+4. Branch: **develop**.
- Secrets NIE in JSON — Set-Passwort/Passphrase liegt im Keychain UNTER DER SET-UUID über den bestehenden `SecretStore` (`savePassword/password/deletePassword` sind UUID-adressiert; keine Protokoll-Änderung).
- Vorwärtskompatibilität `logins.json`: ein Record mit unbekanntem `authKind`-Raw (künftiges `agent`, M10d) wird von `all()` NIE geliefert (nie als Passwort-Set fehlinterpretiert), bleibt aber über upsert/delete ANDERER Einträge in der Datei erhalten.
- `StoredSession.loginSetID: UUID?` optional OHNE Custom-Decoder (exakt das `groupID`-Muster) — Legacy-JSON liest nil.
- Fehlendes referenziertes Set beim Connect = EHRLICHER Fehler, kein stiller Fallback.
- Merge-Ignorieren persistiert NUR Session-ID-Mengen — nie Passwörter, Hashes oder Ableitungen davon.
- Alle neuen UI-Texte EN/DE (`L10n.string`, beide Kataloge); Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 475 Tests / 37 Suiten); gated Suiten nur in T4; Tests SYNCHRON im Vordergrund; TDD rot→grün für Core.
- KEIN Release, kein Merge nach main — der Meilenstein endet mit Push auf develop.

## Schedule

T1 (Core: LoginSet + Store + loginSetID + Resolver) → T2 (Core: MergePlanner + SessionListViewModel-APIs + Export-Auflösung) → T3 (App: Sheets + Menü + Dreiweg + Connect-Wiring) → T4 Abschluss (Koordinator).

---

### Task 1: LoginSet + LoginSetStore + loginSetID + LoginResolver (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/LoginSetStore.swift`
- Create: `Sources/macSCPCore/Sessions/LoginResolver.swift`
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Test: `Tests/macSCPCoreTests/LoginSetStoreTests.swift` (neu), `Tests/macSCPCoreTests/LoginResolverTests.swift` (neu)

**Interfaces:**
- Consumes: `StoredSession.AuthKind` (bestehend), `SecretStore`-Protokoll (bestehend, UUID-adressiert), `InMemorySecretStore` (bestehender Test-Double in `Tests/macSCPCoreTests/InMemorySecretStore.swift`).
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `LoginSet` (`id: UUID`, `name: String`, `username: String`, `authKind: StoredSession.AuthKind`, `keyPath: String?`; Init mit Defaults `id: UUID = UUID()`, `authKind: .password`, `keyPath: nil`)
  - `LoginSetStore(directory: URL)`: `all() throws -> [LoginSet]` (name-sortiert, case-insensitiv), `upsert(_:) throws`, `delete(id:) throws`, `ignoredMergeGroups() throws -> [Set<UUID>]`, `addIgnoredMergeGroup(_: Set<UUID>) throws`
  - `StoredSession.loginSetID: UUID?` (public var, Init-Parameter mit Default nil)
  - `ResolvedLogin` (`username: String`, `authKind: StoredSession.AuthKind`, `keyPath: String?`, `secret: String?`)
  - `LoginResolver.resolve(session:sets:secrets:) throws -> ResolvedLogin?` und `LoginResolveError.missingSet`

- [ ] **Step 1: Failing Tests schreiben** (`LoginSetStoreTests.swift` + `LoginResolverTests.swift`; Fixture-Muster von `KnownHostsStoreTests` übernehmen — Temp-Verzeichnis pro Test):

```swift
    // LoginSetStoreTests:
    // upsertAndAllRoundtrip: zwei Sets upserten ("Web", "Admin") ->
    //   all() liefert beide, name-sortiert case-insensitiv ["Admin", "Web"];
    //   Feldwerte (username/authKind/keyPath) bleiben erhalten.
    // upsertReplacesById: Set upserten, Namen ändern, erneut upserten ->
    //   all().count == 1, neuer Name.
    // deleteRemovesOnlyMatch: zwei Sets, delete(id: erstes.id) ->
    //   nur das zweite bleibt; delete unbekannter id wirft nicht.
    // emptyDirectoryReadsEmpty: all() auf leerem Verzeichnis == [].
    // unknownAuthKindIsHiddenButPreserved: Raw-JSON mit drei Records
    //   direkt in logins.json schreiben (Format der Datei nachstellen),
    //   einer davon mit "authKind": "agent" -> all() liefert nur die zwei
    //   bekannten; danach ein NEUES Set upserten und eines der bekannten
    //   löschen -> Roh-JSON der Datei enthält den "agent"-Record IMMER NOCH
    //   (String-Contains-Check auf "agent" reicht).
    // ignoredMergeGroupsRoundtrip: addIgnoredMergeGroup([a, b]) ->
    //   ignoredMergeGroups() == [Set([a, b])]; zweite Gruppe anhängen ->
    //   beide vorhanden; leeres Verzeichnis -> [].
    //
    // LoginResolverTests:
    // manualSessionResolvesNil: session.loginSetID == nil ->
    //   resolve(...) == nil (Aufrufer nutzt Session-eigene Daten).
    // setSessionResolvesFromSet: Set (user "deploy", .privateKey,
    //   keyPath "/k"), Secret "pp" im InMemorySecretStore unter set.id;
    //   Session mit loginSetID = set.id -> ResolvedLogin(username: "deploy",
    //   authKind: .privateKey, keyPath: "/k", secret: "pp").
    // missingSecretResolvesNilSecret: kein Keychain-Eintrag -> secret == nil,
    //   übrige Felder aus dem Set.
    // missingSetThrows: loginSetID zeigt auf unbekannte UUID ->
    //   #expect(throws: LoginResolveError.missingSet).
    // legacySessionJSONDecodesNilLoginSetID: Raw-sessions.json OHNE
    //   loginSetID-Feld (Format nachstellen) über SessionStore laden ->
    //   loginSetID == nil. (Gehört logisch zu StoredSession; hier
    //   mit-testen statt einer dritten Datei.)
```

- [ ] **Step 2: Rot beweisen.** `swift test --filter LoginSetStoreTests` und `--filter LoginResolverTests` → FAIL (Typen existieren nicht).

- [ ] **Step 3: Implementierung.**

`StoredSession.swift` — exakt das `groupID`-Muster (kein Custom-Decoder):

```swift
    /// The login set this session's credentials come from, if any (M10b).
    /// Optional so legacy JSON without this field keeps decoding as `nil`
    /// (nil = the session carries its own credentials, "manual" mode).
    public var loginSetID: UUID?
    // Init: loginSetID: UUID? = nil als letzter Parameter, zuweisen.
```

`LoginSetStore.swift`:

```swift
import Foundation

/// A reusable, named login (M10b): username plus either a keychain-held
/// password or a private key path (with a keychain-held passphrase).
/// Contains NO secrets — those live in the SecretStore under `id`.
public struct LoginSet: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var username: String
    public var authKind: StoredSession.AuthKind
    /// Path to the private key (only set when authKind == .privateKey).
    public var keyPath: String?

    public init(
        id: UUID = UUID(), name: String, username: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil
    ) { … }
}

/// JSON persistence for login sets (`logins.json`), following the
/// SessionStore pattern: stateless, atomic writes.
///
/// Forward compatibility: entries are persisted as raw records whose
/// `authKind` is a plain string. A record with an UNKNOWN raw (e.g. a
/// future "agent" set written by a newer app version, M10d) is never
/// surfaced by `all()` — it must not be misread as a password set — but
/// it survives upsert/delete of other entries untouched.
public struct LoginSetStore: Sendable {
    private struct Record: Codable {
        var id: UUID
        var name: String
        var username: String
        var authKind: String
        var keyPath: String?
    }
    private struct StoreFile: Codable {
        var sets: [Record] = []
        var ignoredMergeGroups: [[UUID]] = []
    }

    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var fileURL: URL { directory.appendingPathComponent("logins.json") }

    private func load() throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return StoreFile()
        }
        return try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    /// All sets with a KNOWN auth kind, name-sorted case-insensitively.
    public func all() throws -> [LoginSet] {
        try load().sets.compactMap { record in
            guard let kind = StoredSession.AuthKind(rawValue: record.authKind) else { return nil }
            return LoginSet(id: record.id, name: record.name, username: record.username,
                            authKind: kind, keyPath: record.keyPath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func upsert(_ set: LoginSet) throws {
        var file = try load()
        let record = Record(id: set.id, name: set.name, username: set.username,
                            authKind: set.authKind.rawValue, keyPath: set.keyPath)
        if let index = file.sets.firstIndex(where: { $0.id == set.id }) {
            file.sets[index] = record
        } else {
            file.sets.append(record)
        }
        try persist(file)
    }

    public func delete(id: UUID) throws {
        var file = try load()
        file.sets.removeAll { $0.id == id }
        try persist(file)
    }

    /// Persisted "don't suggest merging these again" groups (M10b spec §4):
    /// plain session-ID sets — deliberately never passwords or anything
    /// derived from them.
    public func ignoredMergeGroups() throws -> [Set<UUID>] {
        try load().ignoredMergeGroups.map(Set.init)
    }

    public func addIgnoredMergeGroup(_ sessionIDs: Set<UUID>) throws {
        var file = try load()
        file.ignoredMergeGroups.append(Array(sessionIDs).sorted { $0.uuidString < $1.uuidString })
        try persist(file)
    }
}
```

`LoginResolver.swift`:

```swift
import Foundation

/// Thrown when a session references a login set that no longer exists —
/// the connect must fail honestly instead of silently guessing (spec §2).
public enum LoginResolveError: Error, Equatable {
    case missingSet
}

/// Credentials resolved from a login set: what the connect flow needs to
/// fill the connection form. `secret` is the set's keychain entry
/// (password, or key passphrase for .privateKey), nil when absent.
public struct ResolvedLogin: Equatable, Sendable {
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var secret: String?
    public init(username: String, authKind: StoredSession.AuthKind,
                keyPath: String?, secret: String?) { … }
}

public enum LoginResolver {
    /// Resolves a session's login: `nil` for manual sessions
    /// (loginSetID == nil — the caller uses the session's own data),
    /// the set's credentials otherwise. A dangling reference throws.
    public static func resolve(
        session: StoredSession, sets: [LoginSet], secrets: any SecretStore
    ) throws -> ResolvedLogin? {
        guard let setID = session.loginSetID else { return nil }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        let secret = (try? secrets.password(for: set.id)) ?? nil
        return ResolvedLogin(username: set.username, authKind: set.authKind,
                             keyPath: set.keyPath, secret: secret)
    }
}
```

- [ ] **Step 4: Grün + volle Suite.** `swift test` → 475 + neue (echte Zahl festhalten), 0 Failures.

- [ ] **Step 5: Commit.** `feat: add login sets with store, session reference and resolver`

---

### Task 2: LoginMergePlanner + SessionListViewModel-APIs + Export-Auflösung (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/LoginMergePlanner.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/LoginMergePlannerTests.swift` (neu), `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (erweitern)

**Interfaces:**
- Consumes (T1): `LoginSet`, `LoginSetStore` (Signaturen s. T1), `StoredSession.loginSetID`, `LoginResolver.resolve(session:sets:secrets:)`, `ResolvedLogin`, `LoginResolveError.missingSet`; bestehend: `SecretStore`, `SessionListViewModel` (store/secrets/reload/exportPayload), `InMemorySecretStore`.
- Produces (T3 verlässt sich exakt hierauf):
  - `LoginMergeCandidate` (`username: String`, `authKind: StoredSession.AuthKind`, `keyPath: String?`, `sessionIDs: [UUID]`)
  - `LoginMergePlanner.candidates(sessions:ignoredGroups:secrets:) -> [LoginMergeCandidate]`
  - `SessionListViewModel`: `loginSets: [LoginSet]` (published, in `reload()` mitgeladen), `saveLoginSet(_ set: LoginSet, secret: String?)`, `usageCount(of setID: UUID) -> Int`, `sessionsUsing(setID: UUID) -> [StoredSession]`, `deleteLoginSet(_ set: LoginSet) -> LoginSetDeleteResult`, `mergeCandidates() -> [LoginMergeCandidate]`, `applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet?`, `ignoreMerge(_ candidate: LoginMergeCandidate)`, `resolvedLogin(for session: StoredSession) throws -> ResolvedLogin?`, `suggestedSetName(forUsername username: String) -> String`, erweitertes `save(... loginSetID: UUID? = nil)`
  - `LoginSetDeleteResult` (`restored: Int`, `secretFailures: Int`, Equatable)

**Verhaltens-Anforderungen (Spec §3/§4/§5, bindend):**
1. Planner: NUR Sessions mit `loginSetID == nil` nehmen teil. privateKey-Gruppen: gleiche (username, keyPath). password-Gruppen: gleicher username UND identischer Keychain-Passwort-WERT (In-Memory-Vergleich; Session ohne gespeichertes Passwort nimmt nicht teil). Nur Gruppen ≥ 2. Kandidat unterdrückt, wenn seine Session-ID-Menge TEILMENGE einer ignorierten Gruppe ist (neues Mitglied ⇒ keine Teilmenge mehr ⇒ reaktiviert). Deterministische Reihenfolge (username-sortiert; sessionIDs in Session-Reihenfolge der Eingabe).
2. `deleteLoginSet`: pro betroffener Session username/authKind/keyPath aus dem Set zurückkopieren, Set-Secret in den Session-Keychain-Eintrag kopieren (nur wenn vorhanden), `loginSetID = nil`, upsert; Keychain-Fehler einer Session zählt (`secretFailures`) statt abzubrechen — die Session wird TROTZDEM zurückgestellt (Werte + nil-Referenz), nur das Secret fehlt. Danach Set + Set-Secret löschen, `reload()`.
3. `applyMerge`: Set anlegen (Name-Parameter; Kollisionsbehandlung liefert `suggestedSetName` VOR dem Aufruf, s. u.), Secret der ERSTEN Gruppen-Session unter die Set-ID kopieren (bei .password; bei .privateKey Passphrase ebenso), auf allen Gruppen-Sessions `loginSetID` setzen, Session-Secrets nach erfolgreicher Umstellung löschen (throw-frei via `try?` — ein Lösch-Fehler ist ein harmloser Rest, nie ein Abbruch), `reload()`. Store-Fehler beim Set-Anlegen ⇒ nil + `errorMessage`, nichts umgestellt.
4. `suggestedSetName(forUsername:)`: Basis = username; kollidiert der Name case-insensitiv mit einem bestehenden Set, „(2)", „(3)" … anhängen (Muster der Datei-Konflikt-Namen).
5. `save(... loginSetID:)`: non-nil ⇒ Session referenziert das Set und es wird KEIN Session-Secret geschrieben (das `password`-Argument wird ignoriert); nil ⇒ heutiges Verhalten unverändert.
6. `exportPayload`: für Sessions mit Set werden Username/authKind/keyPath und (bei `includePasswords`) das Passwort aus dem SET aufgelöst exportiert; fehlendes Set-Secret zählt in `missingPasswordCount`; ein fehlendes SET exportiert die Session mit ihren (leeren) Eigenwerten — Export bricht nie ab. Exportformat unverändert v1.
7. `reload()` lädt `loginSets` mit (Store-Fehler ⇒ leere Liste, bestehendes errorMessage-Muster).

- [ ] **Step 1: Failing Tests** (Planner-Datei neu; VM-Tests im bestehenden Muster mit Temp-SessionStore + InMemorySecretStore + LoginSetStore auf demselben Temp-Verzeichnis):

```swift
    // LoginMergePlannerTests:
    // groupsByUsernameAndKeyPath: 3 Key-Sessions (2x deploy//k1, 1x deploy//k2)
    //   -> genau ein Kandidat (deploy, .privateKey, /k1) mit 2 IDs.
    // groupsByUsernameAndPasswordValue: 3 Passwort-Sessions user "root",
    //   Secrets "a"/"a"/"b" -> ein Kandidat mit den beiden "a"-Sessions.
    // sessionWithoutStoredPasswordExcluded: Session ohne Keychain-Eintrag
    //   -> nimmt nicht teil (kein Kandidat aus ihr).
    // sessionWithSetExcluded: Session mit loginSetID != nil -> nimmt nicht teil.
    // singletonGroupsSuppressed: nur 1 Session pro Schlüssel -> [].
    // ignoredGroupSuppressesSubset: Kandidat {a,b}; ignoredGroups [{a,b}]
    //   -> []; ignoredGroups [{a,b,c}] (Obermenge) -> ebenfalls unterdrückt.
    // newMemberReactivates: ignoredGroups [{a,b}], Kandidat {a,b,c}
    //   -> Kandidat erscheint.
    //
    // SessionListViewModelTests (Ergänzungen):
    // saveWithLoginSetSkipsSessionSecret: save(..., loginSetID: set.id)
    //   -> Session hat loginSetID, secrets.password(for: session.id) == nil.
    // deleteLoginSetRestoresSessions: Set (user/key + Passphrase "pp"),
    //   2 Sessions referenzieren es -> deleteLoginSet: beide Sessions
    //   tragen username/authKind/keyPath des Sets, loginSetID == nil,
    //   Session-Secret == "pp", Set weg, Set-Secret weg,
    //   Ergebnis restored == 2, secretFailures == 0.
    // deleteLoginSetCountsSecretFailure: SecretStore-Double, dessen
    //   savePassword für eine bestimmte Session-ID wirft (kleines lokales
    //   Double im Test, InMemory-basiert) -> restored == 2,
    //   secretFailures == 1, BEIDE Sessions sind trotzdem zurückgestellt.
    // applyMergeCreatesSetAndRewires: 2 Passwort-Sessions "root"/"a" ->
    //   applyMerge(candidate, name: "root"): Set existiert (user root,
    //   .password), Set-Secret == "a", beide Sessions loginSetID == set.id,
    //   Session-Secrets gelöscht.
    // suggestedSetNameAvoidsCollision: Sets "root", "root (2)" existieren
    //   -> suggestedSetName(forUsername: "root") == "root (3)";
    //   ohne Kollision == "root".
    // ignoreMergePersists: ignoreMerge(candidate) -> mergeCandidates()
    //   liefert ihn nicht mehr (über LoginSetStore.ignoredMergeGroups).
    // exportResolvesLoginSet: Session mit Set (user "deploy", Passwort "s")
    //   -> exportPayload(all, includePasswords: true): ExportedSession
    //   trägt username "deploy", password "s"; fehlendes Set-Secret zählt
    //   in missingPasswordCount.
    // resolvedLoginMissingSetThrows: Session mit dangling loginSetID ->
    //   #expect(throws:) auf resolvedLogin(for:).
```

- [ ] **Step 2: Rot beweisen.** `swift test --filter LoginMergePlannerTests` und `--filter SessionListViewModelTests` → FAIL.

- [ ] **Step 3: Implementierung.**

`LoginMergePlanner.swift`:

```swift
import Foundation

/// A group of manual sessions sharing the same effective login (M10b spec
/// §4) — the "merge into one set?" suggestion the UI banners.
public struct LoginMergeCandidate: Equatable, Sendable {
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var sessionIDs: [UUID]
}

/// Pure equality detection over MANUAL sessions (loginSetID == nil).
/// Password values are compared in memory only and never leave this
/// function; sessions without a stored password do not participate.
public enum LoginMergePlanner {
    public static func candidates(
        sessions: [StoredSession], ignoredGroups: [Set<UUID>], secrets: any SecretStore
    ) -> [LoginMergeCandidate] {
        // Gruppieren in ein Dictionary mit einem Struct-Key
        //   GroupKey { username; kind; keyPath: String?; password: String? }
        // (Hashable, file-privat):
        //   .privateKey -> keyPath gesetzt, password nil
        //   .password   -> password = (try? secrets.password(for: id)),
        //                  bei nil TEILNAHME ÜBERSPRINGEN
        // Nur Gruppen mit count >= 2. Unterdrücken, wenn
        //   ignoredGroups.contains(where: { Set(ids).isSubset(of: $0) }).
        // Ergebnis username-sortiert (bei Gleichheit keyPath, dann Anzahl);
        // sessionIDs in Eingabe-Reihenfolge der Sessions.
    }
}
```

`SessionListViewModel`-Ergänzungen (bestehende Muster: `do/catch` + `reload()` + `errorMessage` via `CoreL10n`; drei neue CoreL10n-Keys nach Bestand anlegen, z. B. `core.login.saveFailed %@`, `core.login.deleteFailed %@`, `core.login.mergeFailed %@`, EN/DE in beiden Core-Katalogen):

```swift
    // Neue stored property + Init-Parameter (defaulted, kein Bruch der Aufrufer):
    public private(set) var loginSets: [LoginSet] = []
    private let loginSetStore: LoginSetStore
    // Init-Parameter (defaulted wie auditStore):
    //   loginSetStore: LoginSetStore =
    //     LoginSetStore(directory: SessionStore.defaultDirectory)
    // reload(): loginSets = (try? loginSetStore.all()) ?? [] ergänzen.

    public struct LoginSetDeleteResult: Equatable {
        public var restored: Int
        public var secretFailures: Int
        public init(restored: Int, secretFailures: Int) { … }
    }

    public func sessionsUsing(setID: UUID) -> [StoredSession] {
        sessions.filter { $0.loginSetID == setID }
    }
    public func usageCount(of setID: UUID) -> Int { sessionsUsing(setID: setID).count }

    /// Saves a set; a non-nil, non-empty secret overwrites the keychain
    /// entry under the SET id (nil/empty keeps it — the editor's
    /// "unchanged" prompt semantics, same as updateSession).
    public func saveLoginSet(_ set: LoginSet, secret: String?)

    /// Spec §3 "delete = restoration": every referencing session gets the
    /// set's username/authKind/keyPath copied back, the set's secret copied
    /// into ITS keychain slot, loginSetID nilled. A keychain failure for
    /// one session is counted, never aborts — the session is still
    /// restored, only its secret is missing. Afterwards the set and its
    /// secret are removed.
    public func deleteLoginSet(_ set: LoginSet) -> LoginSetDeleteResult

    public func mergeCandidates() -> [LoginMergeCandidate] {
        LoginMergePlanner.candidates(
            sessions: sessions,
            ignoredGroups: (try? loginSetStore.ignoredMergeGroups()) ?? [],
            secrets: secrets)
    }
    public func ignoreMerge(_ candidate: LoginMergeCandidate)   // addIgnoredMergeGroup(Set(ids))
    public func applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet?
    public func suggestedSetName(forUsername username: String) -> String
    public func resolvedLogin(for session: StoredSession) throws -> ResolvedLogin? {
        try LoginResolver.resolve(session: session, sets: loginSets, secrets: secrets)
    }
    // save(...): Parameter loginSetID: UUID? = nil ergänzen; in beiden
    // Zweigen zuweisen; Secret-Schreiben nur im nil-Fall.
    // exportPayload: pro Session zuerst try? resolvedLogin(for:) —
    // ResolvedLogin ersetzt username/authKind/keyPath und (bei
    // includePasswords) das Passwort; nil/throw => heutiger Weg.
```

- [ ] **Step 4: Grün + volle Suite.** `swift test` → Stand T1 + neue, 0 Failures.

- [ ] **Step 5: Commit.** `feat: add login merge planning and set lifecycle to the session view model`

---

### Task 3: Logins-Sheet + Editor + Menü + Dreiweg-Formular + Connect-Wiring (App)

**Files:**
- Create: `Sources/MacSCPApp/LoginSetsSheet.swift` (Liste + Merge-Banner + Editor-Sub-Sheet)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Sessions-Menü: „Logins…" ⌘⇧L), `Sources/MacSCPApp/ContentView.swift` (Sheet-State + TabCommands-Closure + Connect-Auflösung + Save-Pfad), `Sources/MacSCPApp/SessionSidebar.swift` (Hintergrund-Menü-Eintrag), `Sources/MacSCPApp/ConnectionFormView.swift` (Dreiweg-Auth-Block), `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (Formular-Felder), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T4). Die ConnectionViewModel-Felder sind reine stored properties — kein eigener Test nötig.

**Interfaces:**
- Consumes (T1/T2, exakt): `SessionListViewModel.loginSets/saveLoginSet/deleteLoginSet/usageCount/sessionsUsing/mergeCandidates/applyMerge/ignoreMerge/suggestedSetName/resolvedLogin/save(... loginSetID:)`, `LoginSet`, `LoginMergeCandidate`, `LoginSetDeleteResult`, `LoginResolveError.missingSet`; bestehend: `TabCommands`-Brücke (M8a/M10a-Muster `showKnownHosts`), `KnownHostsSheet` als Gestalt-Vorlage, `ConnectionViewModel`-Formularfelder, `connect(in:stored:)` in ContentView.

**Verhaltens-Anforderungen (Spec §2/§3/§5 + Mockup Abschnitt 3, bindend):**
1. `LoginSetsSheet(sessionList: SessionListViewModel)` (~720 pt, Gestalt wie `KnownHostsSheet`): Zeilen nach Mockup — KEY/PASS-Badge (Badge-Optik von `keyTypeBadge` übernehmen), Set-Name, `user · SSH-Key (~/pfad)` bzw. `user · Passwort`-Kurzform, rechts Nutzungszähler `L10n` „%lld connections"/„%lld Verbindungen" (Singular „1 connection" über zwei Keys `loginSets.usage.one`/`loginSets.usage.many %lld`). Fußzeile: „New…", „Edit…" (Einzelauswahl), „Delete…" (destruktiv), „Close". Merge-Banner OBEN, wenn `mergeCandidates()` nicht leer: Text nennt username + Anzahl („N connections use the same login ‚user'"), Buttons „Ignore" (ignoreMerge, Banner verschwindet) und „Merge…" — Bestätigungsdialog listet die Session-NAMEN (über sessionIDs aufgelöst) + Ziel-Set-Name (`suggestedSetName`), Bestätigen ruft `applyMerge`. Mehrere Kandidaten: den ersten anzeigen, Rest nach Aktion nachrücken lassen.
2. Editor-Sub-Sheet (Neu/Bearbeiten): Name, Benutzername, Segmente Passwort|SSH-Key (Muster des Verbindungsformulars: SecureField mit „leave empty to keep"-Prompt beim Bearbeiten, Key-Pfad + „Choose…" fileImporter + Passphrase-SecureField). „Save" disabled bis Name+Benutzername nicht-leer (getrimmt). Speichern → `saveLoginSet(set, secret: eingabe.isEmpty ? nil : eingabe)`.
3. Löschen: `confirmationDialog`, Botschaft nennt `usageCount` und dass betroffene Verbindungen ihre Daten direkt zurückbekommen (EN „%lld connections will keep these credentials stored directly again." / DE „%lld Verbindungen erhalten diese Zugangsdaten wieder direkt hinterlegt."); `secretFailures > 0` ⇒ rote Meldung im Sheet (Muster `knownHosts.removeError`).
4. Menü + Einstiege: Sessions-Menü-Eintrag „Logins…" ⌘⇧L (TabCommands-Closure `showLogins`, Key-Window-Guard wie `showKnownHosts`); Sidebar-Hintergrund-Menü „Logins…" direkt unter „Known Hosts…"; im Formular-Set-Modus ein „Manage logins…"-Link (öffnet dasselbe Sheet lokal, Muster der TOFU-Fußnote aus M10a).
5. Dreiweg im Formular (Mockup Abschnitt 3 unteres Sheet): Über dem heutigen Auth-Block ein Segment-Umschalter `Login set | Manual`. Set-Modus: Picker über `sessionList.loginSets` (Anzeige „Name — user"), ersetzt Username/Passwort/Key-Felder komplett; darunter der „Manage logins…"-Link. Manual-Modus: heutige Felder + Toggle „Save as new login set" + Namensfeld (Prompt = `suggestedSetName(forUsername:)` live). Neue `ConnectionViewModel`-Felder: `loginMode` (`enum LoginMode: String, CaseIterable, Sendable { case set, manual }`, Default `.manual`), `selectedLoginSetID: UUID?`, `saveAsNewLoginSet: Bool = false`, `newLoginSetName: String = ""`. Formular-Validierung: Set-Modus verlangt `selectedLoginSetID != nil` statt Username/Passwort.
6. Connect-Wiring in ContentView:
   - Formular-Connect im Set-Modus: vor `form.connect()` das Set auflösen (`loginSets` + Keychain über `resolvedLogin` einer synthetischen Session ODER direkt: Set aus `sessionList.loginSets`, Secret via `sessionList` — die kleinere Lösung: eine kleine Hilfsfunktion `fillForm(from set: LoginSet)` setzt username/authChoice/keyPath/password aus Set + Keychain-Read). Save-Pfad: `save(..., loginSetID: form.selectedLoginSetID)` im Set-Modus; im Manual-Modus mit aktivem „Save as new login set" ZUERST `saveLoginSet` (Name aus Feld, leer ⇒ `suggestedSetName`), dann `save(..., loginSetID: neuesSet.id)`.
   - `connect(in:stored:)`: `try sessionList.resolvedLogin(for: stored)` — non-nil ⇒ Formular aus `ResolvedLogin` füllen (statt Session-Eigenwerten); `LoginResolveError.missingSet` ⇒ NICHT verbinden, Formular zeigen mit Fehlermeldung `loginSets.missingSet` (EN „The stored login for this connection was not found. Choose a login or enter credentials." / DE „Das hinterlegte Login dieser Verbindung wurde nicht gefunden. Login wählen oder Zugangsdaten eingeben.") — über das bestehende Fehlerfeld des Formulars.
   - Edit-Modus des Formulars: `loginSetID` gesetzt ⇒ `loginMode = .set` + Vorauswahl; sonst `.manual` (heutiges Prefill).
7. Alle neuen Keys EN/DE in BEIDEN Katalogen; Grep-Gegenprobe. Vorschlag: `menu.logins`, `loginSets.title`, `loginSets.usage.one`, `loginSets.usage.many %lld`, `loginSets.new`, `loginSets.edit`, `loginSets.delete`, `loginSets.delete.title`, `loginSets.delete.message %lld`, `loginSets.delete.confirm`, `loginSets.deleteError %lld`, `loginSets.empty`, `loginSets.merge.banner %lld %@`, `loginSets.merge.ignore`, `loginSets.merge.action`, `loginSets.merge.confirmTitle`, `loginSets.merge.confirm`, `loginSets.editor.titleNew`, `loginSets.editor.titleEdit`, `loginSets.editor.name`, `loginSets.editor.username`, `loginSets.editor.keepSecret`, `loginSets.missingSet`, `form.loginMode.set`, `form.loginMode.manual`, `form.selectLogin`, `form.manageLogins`, `form.saveAsSet`, `form.saveAsSet.name` (endgültige Liste beim Implementieren festhalten).

- [ ] **Step 1:** ConnectionViewModel-Felder + Dreiweg-UI im Formular. **Step 2:** LoginSetsSheet + Editor + Merge-Banner. **Step 3:** Menü/Sidebar/TabCommands + ContentView-Wiring (Connect-Auflösung, Save-Pfade, missingSet-Fehler). **Step 4:** Lokalisierungs-Keys + Grep-Gegenprobe beide Kataloge. **Step 5:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T2). **Step 6:** Commit `feat: add reusable login sets with form picker and merge suggestions`.

---

### Task 4: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: Docker-Rig `start` (Haupt-Checkout), `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle Tests, zero skips; Rig `stop`.
- [ ] Visueller Smoke — an den Maintainer delegiert (Checkliste in der Zusammenfassung: Sheet ⌘⇧L, Set anlegen/bearbeiten, Dreiweg im Formular, Merge-Banner mit zwei gleichen Logins, Set löschen ⇒ Verbindungen funktionieren weiter, Connect über Set).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review (Review-Package über `git merge-base`), Fix-Runde falls nötig, Push develop, `gh run watch`, Memory-Update, Zusammenfassung. KEIN Release.
