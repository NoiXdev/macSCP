# M10b — Login-Sets (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben (Mockup eingefroren:
`docs/design/assets/m10-mockups.html` Abschnitte 3+4; Design-Block „passt",
direkt los)

## Ziel

Wiederverwendbare Logins (Termius-artig): benannte Sets aus Benutzername +
Auth, referenzierbar von Verbindungen („einmal ändern, gilt überall"), mit
Dreiweg-Auswahl im Formular und automatischem Zusammenfassen-Vorschlag für
gleiche bestehende Logins.

**Maintainer-Entscheidungen (2026-07-28):**

1. ssh-agent-Auth wird NICHT Teil von M10b — eigener Meilenstein M10d
   (Citadel hat keine Agent-Auth; bräuchte eigene Protokoll-Implementierung
   über den Custom-Delegate-Haken). Das Set-Modell ist dafür
   vorwärtskompatibel (`authKind` String-Raw).
2. Dreiweg-Auswahl gilt in M10b für den ZIEL-Host; der Jump-Host (M10c)
   nutzt dieselben Bausteine.

## 1. Core-Modell

- `public struct LoginSet: Equatable, Identifiable, Sendable`:
  `id: UUID`, `name: String`, `username: String`,
  `authKind: StoredSession.AuthKind` (WIEDERVERWENDET — kein Duplikat-Enum),
  `keyPath: String?` (nur privateKey).
- Vorwärtskompatibilität: der Store persistiert intern Records mit
  `authKind` als String-Raw. Ein UNBEKANNTER Raw-Wert (z. B. ein
  künftiges „agent" aus M10d) wird von `all()` NICHT als Set geliefert
  (nie als Passwort-Set fehlinterpretiert), aber der Record bleibt in der
  Datei erhalten — auch über upsert/delete anderer Einträge hinweg.
- Secrets: Passwort bzw. Key-Passphrase liegen im Keychain UNTER DER
  SET-ID (bestehender `SecretStore`; kein neues Secret-Format, nie in
  `logins.json`).
- `LoginSetStore` (eigene `logins.json`, SessionStore-Muster: stateless,
  atomar, vorwärtskompatibel): `all()`, `upsert`, `delete(id:)`.
- `StoredSession.loginSetID: UUID?` — optional, decode-kompatibel (Legacy
  nil = Manuell). nil/non-nil IST der Formular-Modus.

## 2. Connect-Auflösung

- Referenziert eine Session ein Set, liefert die Auflösung beim Connect
  Username + Auth aus dem SET (Passwort/Passphrase aus dem Keychain unter
  der Set-ID). Eine testbare Core-Funktion (z. B.
  `LoginResolver.resolve(session:sets:secrets:)`) baut die
  `SSHConnectionConfig`-Bausteine; die App verdrahtet sie in den
  bestehenden Connect-Fluss (connectStored/Formular).
- Fehlt das referenzierte Set (gelöschte/kaputte Datei), schlägt der
  Connect mit einer EHRLICHEN lokalisierten Meldung fehl („Das
  hinterlegte Login wurde nicht gefunden") — kein stilles Raten, kein
  stiller Manuell-Fallback (die Session hat ja keine eigenen Daten mehr).

## 3. Set-Löschen = Rückstellung

- Rückfrage nennt die betroffenen Verbindungen (Anzahl + Namen).
- Bestätigen: pro betroffener Session werden Username/authKind/keyPath in
  die Session ZURÜCKKOPIERT, das Secret vom Set-Keychain-Eintrag in den
  Session-Keychain-Eintrag KOPIERT, `loginSetID` genullt; danach Set +
  Set-Secret gelöscht. Keychain-Fehler bei einer Session: Rückstellung
  der übrigen läuft weiter, Ergebnis meldet die Fehlzahl (Muster
  applyImport). Nie kaputte Verbindungen.

## 4. Gleichheits-Erkennung (LoginMergePlanner)

- Reine Core-Funktion über Sessions OHNE Set:
  - privateKey-Gruppen: gleicher (username, keyPath).
  - password-Gruppen: gleicher username UND identisches Keychain-Passwort
    (Vergleich über SecretStore-Reads; Werte werden nie angezeigt;
    Sessions ohne gespeichertes Passwort nehmen nicht teil).
- Gruppen ≥ 2 ⇒ Merge-Vorschlag (Banner). „Zusammenfassen…" zeigt die
  Vorschau (Session-Namen), legt EIN Set an (Namensvorschlag aus dem
  Username, bei Kollision „(2)"-Suffix wie Datei-Konflikte), setzt
  `loginSetID` auf allen Gruppen-Sessions, übernimmt das Secret unter die
  Set-ID; die Session-Secrets werden nach erfolgreicher Umstellung
  GELÖSCHT (die Auflösung läuft ab jetzt ausschließlich über das Set).
- „Ignorieren" persistiert die Gruppen-Signatur als MENGE der
  Session-IDs in `logins.json` (`ignoredMergeGroups: [[UUID]]`) — bewusst
  KEIN Passwort-Hash oder Ableitung davon auf Platte. Ein neues Mitglied
  (Session-ID nicht in der ignorierten Menge) reaktiviert den Vorschlag
  für die erweiterte Gruppe.

## 5. UI

- Logins-Sheet (⌘⇧L im Sessions-Menü; Sidebar-Hintergrund-Menü über
  „Bekannte Hosts…"; Link „Logins verwalten…" im Formular neben dem
  Picker): Liste nach Mockup Abschnitt 3 (KEY/PASS-Badge, Name,
  `user · Auth-Kurzform`, Nutzungszähler „n Verbindungen"), Fußzeile
  Neu…/Bearbeiten…/Löschen…/Schließen; Merge-Banner oben (Mockup-Optik,
  „Ignorieren" + „Zusammenfassen…" mit Vorschau-Dialog).
- Set-Editor-Sheet (Neu/Bearbeiten): Name, Benutzername, Auth-Segmente
  Passwort|SSH-Key (Passwort-SecureField mit „unverändert"-Prompt beim
  Bearbeiten wie das Session-Formular; Key-Pfad + fileImporter +
  Passphrase). Speichern validiert Name+Username nicht-leer.
- Formular-Dreiweg (Ziel-Host) exakt Mockup Abschnitt 3 unteres Sheet:
  Umschalter `Login-Set | Manuell` (Segmente); Set-Modus: Picker aller
  Sets + „Logins verwalten…"-Link; Manuell-Modus: heutige Felder + Toggle
  „Als neues Login-Set speichern" + Namensfeld (legt beim
  Verbinden/Speichern das Set an, referenziert es sofort, Session-Secret
  wandert unter die Set-ID). Edit-Modus zeigt den gemerkten Zustand
  (loginSetID gesetzt ⇒ Set-Modus mit vorausgewähltem Set).
- Export/Import (M9a): Sessions mit `loginSetID` exportieren die
  AUFGELÖSTEN Werte (Username/Auth/ggf. Passwort) — das Export-Format
  bleibt unverändert v1; Sets selbst werden NICHT exportiert (Backlog).

## 6. Tests

- Store: CRUD, Vorwärtskompatibilität (unbekannter authKind-Raw wird
  übersprungen, Datei unangetastet), loginSetID-Decode-Kompat alter
  sessions.json.
- Resolver: Set→Credentials inkl. Keychain; fehlendes Set ⇒ typisierter
  Fehler mit lokalisierter Meldung.
- Lösch-Rückstellung: Werte + Secret kopiert, loginSetID genullt,
  Keychain-Fehler zählt statt bricht (Mock-SecretStore).
- Merge-Planner: Key- und Passwort-Gruppierung (inkl. „ohne gespeichertes
  Passwort nimmt nicht teil"), Ignorier-Signaturen (Reaktivierung bei
  neuem Mitglied), Merge-Anwendung (Set angelegt, Sessions umgestellt,
  Session-Secrets gelöscht, Namens-Kollision „(2)").
- Export-Auflösung: Session mit Set exportiert aufgelöste Werte.
- UI (Sheets, Banner, Dreiweg, Menü): visueller Smoke (T4).

## 7. Bewusst NICHT in M10b

- Kein ssh-agent (M10d), kein Jump-Host (M10c — nutzt dann den Dreiweg).
- Kein Export/Import der Sets selbst (Backlog; Sessions exportieren
  aufgelöst).
- Keine Set-Nutzung im Edit-Session-„Speichern & verbinden"-Sonderfall
  über das Normale hinaus (der Dreiweg gilt überall im Formular).
