# M15 — S3-Login-Sets komplettieren (Design/Spec)

**Datum:** 2026-08-01
**Status:** freigegeben (Brainstorm), bereit für writing-plans
**Branch:** `develop`
**Vorgänger:** M12 T6 (Login-Set-Fundament: `kind`+`accessKeyID`, Store,
Export/Import, `LoginResolveError.kindMismatch`), M14 (presigned URLs).

## Ziel

Ein S3-Login-Set (wiederverwendbare Access Key ID + Secret) lässt sich
anlegen, an eine S3-Session/Verbindung binden und beim Verbinden korrekt
auflösen — symmetrisch zu SSH-Login-Sets. Damit schließt M15 die drei in
M12 T6 bewusst offen gelassenen Lücken (Resolver, Editor-UI,
Formular-Integration).

## Ausgangslage (Ist)

- **Core-Fundament vorhanden:** `LoginSet.kind`(ssh/s3) + `accessKeyID`
  (`LoginSetStore.swift`), Store persistiert beide, Secret in Keychain unter
  `set.id`, Export/Import trägt `kind`+S3, `LoginResolveError.kindMismatch`
  existiert.
- **Lücke 1 (Core):** `LoginResolver.resolve(session:sets:secrets:)` liefert
  nur `ResolvedLogin` (username/authKind/keyPath/secret) — kein `accessKeyID`.
  Eine an ein S3-Set gebundene S3-Session bekommt beim Connect **keine**
  Zugangsdaten.
- **Lücke 2 (App):** `LoginSetEditorView` (`LoginSetsSheet.swift`) ist
  SSH-only (Auth-Picker + Username/KeyPath/Secret). Kein ssh/s3-Umschalter,
  keine S3-Felder → **kein S3-Login-Set anlegbar**.
- **Lücke 3 (App):** Der `Login`-Umschalter (Login set / Manuell) sitzt nur im
  SSH-Zweig von `ConnectionFormView`. Die S3-Sektion ist reine
  Manuell-Eingabe → **S3-Session kann kein Set nutzen**.
- **Persistenz-Lücke:** Die S3-`save(...)`-Verzweigung in
  `ContentView.swift` (~1893) übergibt **kein** `loginSetID` → eine
  set-gebundene S3-Session könnte die Bindung gar nicht speichern.

## Entscheidungen (Maintainer, 2026-08-01)

1. **Set-Inhalt:** Ein S3-Login-Set trägt **nur Access Key ID + Secret**.
   Region/Endpoint/Bucket bleiben an der Session (das „Wohin"). Spiegelt SSH
   (Login = Credentials, Session = Adresse); der M12-Store hat auch nur
   `accessKeyID`.
2. **Resolver-Form:** **Eigener `ResolvedS3Login`-Typ** + eigene
   `resolveS3`-Methode, nicht `ResolvedLogin` erweitern. Der Connect-Pfad
   kennt den `kind` schon (`switch kind`), ruft also gezielt die passende
   Methode. Skaliert sauber auf spätere Backends (jede Verbindungsart bringt
   ihren eigenen `Resolved…`-Typ mit).
3. **Picker-Filter:** Der Set-Picker im Formular zeigt **nur kind-passende
   Sets** (S3-Session → nur S3-Sets). `kindMismatch` bleibt der harte Schutz
   dahinter.
4. **Volle SSH-Parität im Formular:** Der S3-Manuell-Modus bekommt denselben
   „Als neues Login-Set speichern"-Weg wie SSH.

## Architektur

### Core

**Neuer Typ** (parallel zu `ResolvedLogin`, `LoginResolver.swift`):

```swift
/// S3-Zugangsdaten, aufgelöst aus einem Login-Set (M15). Parallel zu
/// `ResolvedLogin`; `secretAccessKey` ist der Keychain-Eintrag des Sets
/// (unter `set.id`), nil wenn keiner gespeichert ist.
public struct ResolvedS3Login: Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String?

    public init(accessKeyID: String, secretAccessKey: String?) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}
```

**Neue Resolver-Methode** (`LoginResolver`), spiegelbildlich zu `resolve`:

```swift
public static func resolveS3(
    session: StoredSession, sets: [LoginSet], secrets: any SecretStore
) throws -> ResolvedS3Login?
```

Verhalten:

| Fall | Ergebnis |
|------|----------|
| `session.loginSetID == nil` | `nil` (manuelle S3-Session, nutzt eigene Daten) |
| gebunden, `set.kind == .s3` | `ResolvedS3Login(accessKeyID: set.accessKeyID ?? "", secretAccessKey: (try? secrets.password(for: set.id)) ?? nil)` |
| gebunden, `set.kind == .ssh` | wirft `LoginResolveError.kindMismatch` |
| `loginSetID` verweist auf kein Set | wirft `LoginResolveError.missingSet` |

Der bestehende `resolve` (SSH) bleibt **unverändert** und wirft weiterhin
`kindMismatch`, wenn eine SSH-Session ein S3-Set bindet (Symmetrie).

**VM-Wrapper** (`SessionListViewModel`), dünn wie `resolvedLogin(for:)`:

```swift
public func resolvedS3Login(for session: StoredSession) throws -> ResolvedS3Login? {
    try LoginResolver.resolveS3(session: session, sets: loginSets, secrets: secrets)
}
```

### App

**A) `LoginSetEditorView` (`LoginSetsSheet.swift`):**

- Neuer **kind-Umschalter** (segmented, ganz oben): `SSH` / `S3`. Beim
  Editieren initial auf `existing.kind`.
- `kind == .ssh` → heutiger Block unverändert (Username + Auth +
  Secret/KeyPath).
- `kind == .s3` → nur **Access Key ID** (TextField) + **Secret Access Key**
  (`SecureField`). Kein username/keyPath/authKind.
- Set-Name bleibt für beide.
- `Save` baut je nach `kind` ein SSH- oder S3-`LoginSet`
  (`LoginSet(kind: .s3, accessKeyID: …)`, username/authKind auf ihren
  Defaults) und ruft dasselbe `onSave(set, secret)`. Die bestehende
  Edit-Regel „leeres Secret = unverändert" gilt für beide.
- `isSaveDisabled` je kind: SSH wie heute; S3 verlangt nicht-leere Access Key
  ID (Secret bei Neuanlage erforderlich, bei Edit optional — gleiche Logik
  wie SSH-Secret).

**Badge/Liste** (`LoginSetsSheet.swift`, `authKindBadge`/`badgeStyle`,
Zeilenlabel): S3-Sets bekommen einen **`S3`-Badge** (eigenes Token-Paar wie
`KEY`/`AGENT`/`PASS`). Zeilenlabel bei S3: `name — accessKeyID` statt
`name — username`.

**B) `ConnectionFormView.swift` — S3-Sektion:**

- Der `Login`-Umschalter (Login set / Manuell, segmented) rückt in die
  S3-Sektion (heute nur SSH-Zweig).
- **Set-Modus** → Set-Picker `ForEach(sessionList.loginSets.filter { $0.kind == .s3 })`,
  Zeilenlabel `name — accessKeyID`, daneben „Logins verwalten…"-Knopf.
- **Manuell-Modus** → heutige S3-Felder + „Als neues Login-Set speichern"-Toggle
  (SSH-Parität).
- **region/endpoint/bucket** bleiben in **beiden** Modi sichtbare
  Session-Felder.

**C) Füll-Pfade (`ContentView.swift`):**

1. `fillForm(_:from:)` (~1601) bekommt einen S3-Zweig: ist das gewählte Set
   `kind == .s3`, fülle `form.s3AccessKeyID = set.accessKeyID ?? ""` und
   `form.s3SecretAccessKey` aus dem Keychain (synthetische `StoredSession`
   unter `set.id`, wie der SSH-Zweig). `resolveSelectedLoginSet(in:)` ruft
   ihn dann für S3-Sessions genauso.
2. Gespeicherte-Session-Connect (`stored.kind == .s3`-Block, ~2008): wenn
   `stored.loginSetID != nil`, über `resolvedS3Login(for:)` auflösen und
   `s3AccessKeyID`/`s3SecretAccessKey` daraus füllen; region/endpoint/bucket
   weiter aus `stored.s3`. `kindMismatch`/`missingSet` landen im bestehenden
   `loginSets.missingSet`-Fehlerpfad (Formular zeigen statt verbinden).
   `form.loginMode`/`selectedLoginSetID` aus `stored.loginSetID` setzen.

**D) Persistenz-Lücke schließen (`ContentView.swift`, S3-`save`, ~1893):**
`loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID`
übergeben (heute fehlt der Parameter ganz). `maybeCreateNewLoginSet(from:)`
bekommt einen S3-Zweig, der ein `LoginSet(kind: .s3, accessKeyID: …)` +
Secret (Keychain) anlegt.

## Sicherheit / Invarianten

- Secret ausschließlich Keychain, adressiert über `set.id`; nie in JSON,
  Logs oder URLs.
- `kindMismatch` bleibt harter Stopp — **kein** Fallback auf falsch-typige
  Credentials.
- Kein `if kind == .s3`-Sonderpfad im Signer/Transport: die Auflösung endet
  im bestehenden `S3ConnectionConfig`-Bau (`connectS3`), der unverändert
  bleibt.
- Keine neue externe Dependency.

## Tests

**Core-Unit (Swift Testing, TDD rot→grün):**

1. `resolveS3` Happy-Path: set-gebundene S3-Session → `accessKeyID` aus Set +
   Secret aus Keychain.
2. `resolveS3` manuell (`loginSetID == nil`) → `nil`.
3. `resolveS3` `kindMismatch`: S3-Session bindet SSH-Set → wirft.
4. `resolveS3` `missingSet`: dangling `loginSetID` → wirft.
5. Regressions-Guard: SSH-Session mit SSH-Set liefert weiter unverändert
   `ResolvedLogin`.
6. Symmetrie-Guard: `resolve` (SSH) wirft weiter `kindMismatch` bei
   SSH-Session + S3-Set.

**Gated MinIO (`MACSCP_ITEST=1`, aus dem Haupt-Checkout):**

- S3-Login-Set anlegen → S3-Session daran binden → verbinden → Bucket listen
  gelingt. Beweist, dass die set-aufgelösten Credentials tatsächlich gegen
  MinIO authentifizieren (nicht nur im Fake).

**Runtime-Smoke (Maintainer):** Im Dev-Build ein S3-Set anlegen, Session
binden, verbinden — Sicht-Check.

## L10n

Neue nutzer-sichtbare Strings (Editor-kind-Umschalter „SSH"/„S3",
S3-Feld-Labels falls neu, `S3`-Badge, ggf. Picker-Platzhalter) in EN/DE/FR/PL,
typografische Anführungszeichen, FR/PL KI-generiert (Native-Review vor
Release). Bestehende S3-Feld-Labels (Access Key ID, Secret Access Key) werden
wiederverwendet, wo vorhanden.

## Nicht in M15

- Cross-Backend-Transfer S3↔SSH (→ M16).
- „Öffnen mit" S3-CLI-Tool, Verbindungs-Diagnose, SSH-Key-Manager,
  SSH-Terminal-Snippets (eigene spätere Meilensteine).

## Betroffene Dateien

- `Sources/macSCPCore/Sessions/LoginResolver.swift` — `ResolvedS3Login`,
  `resolveS3`.
- `Sources/macSCPCore/Presentation/SessionListViewModel.swift` —
  `resolvedS3Login(for:)`.
- `Sources/MacSCPApp/LoginSetsSheet.swift` — kind-Umschalter, S3-Felder,
  S3-Badge, S3-Zeilenlabel, kind-abhängiges Save/Disable.
- `Sources/MacSCPApp/ConnectionFormView.swift` — Login-Umschalter +
  gefilterter Picker + „als neues Set speichern"-Toggle in der S3-Sektion.
- `Sources/MacSCPApp/ContentView.swift` — `fillForm` S3-Zweig,
  Gespeicherte-Session-Connect S3-Resolve, S3-`save` `loginSetID`,
  `maybeCreateNewLoginSet` S3-Zweig.
- `Tests/macSCPCoreTests/…` — `resolveS3`-Unit-Tests + gated MinIO.
- String-Kataloge (App + Core) EN/DE/FR/PL.
