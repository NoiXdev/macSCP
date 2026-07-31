# M11a — Zwischenhost aus gespeicherter Verbindung (Design)

Datum: 2026-07-29 · Status: vom Maintainer freigegeben („dann los")

## Ziel

Im Jump-Block des Verbindungsformulars eine gespeicherte Verbindung als
Zwischenhost auswählen können, statt Host/Port/Login erneut einzutippen.
Die Auswahl wird als REFERENZ persistiert: ändert sich die Bastion-
Verbindung, gilt das überall.

**Maintainer-Entscheidungen (2026-07-29):**

1. REFERENZ, nicht Kopie — und ausdrücklich NICHT die laufende Verbindung
   eines anderen Tabs mitbenutzen (das würde die Invariante „eine
   Verbindung pro Tab" brechen und Lebenszyklen koppeln).
2. Löschen einer referenzierten Verbindung stellt die betroffenen Jumps
   zurück (Werte + Secret kopieren, Referenz lösen) — dasselbe Muster wie
   das Login-Set-Löschen aus M10b. Nie kaputte Verbindungen.

## 1. Modell

- `StoredSession.JumpSpec.sessionID: UUID?` — non-nil = Session-Modus;
  die eigenen Felder (`host`, `port`, `username`, `authKind`, `keyPath`,
  `loginSetID`) sind dann inaktiv (bleiben als Datenträger für die
  Rückstellung erhalten). Optional OHNE Custom-Decoder (Muster
  `groupID`/`loginSetID`/`jump`) — alte `sessions.json` lesen nil.
- `secretID` bleibt unverändert: im Session-Modus ungenutzt, wird beim
  Wechsel in den Session-Modus wie beim Set-Wechsel aufgeräumt
  (Slot-Hygiene aus M10c/M10d).

## 2. Auflösung beim Verbinden

- `LoginResolver.resolveJump` bekommt zusätzlich die Session-Liste (und
  die ID der referenzierenden Session, um Selbstreferenz zu erkennen).
- Session-Modus: Session anhand `sessionID` suchen.
  - **nicht gefunden** ⇒ `LoginResolveError.missingJumpSession`
  - **referenzierte Session hat selbst einen Jump** ⇒
    `LoginResolveError.jumpChainNotSupported` (EIN Hop bleibt die Regel;
    der Picker filtert das vorher weg, aber die Referenz kann später
    kaputtgehen, wenn die Bastion nachträglich einen Jump bekommt)
  - **Selbstreferenz** (`sessionID == referencing session id`) ⇒
    ebenfalls `jumpChainNotSupported`
  - sonst: Host/Port aus der referenzierten Session; das LOGIN über den
    BESTEHENDEN `LoginResolver.resolve(session:sets:secrets:)` — damit
    funktionieren Login-Set, manuelles Passwort/Key und Agent am Jump
    automatisch, ohne neuen Codepfad. Ein fehlendes Login-Set der
    referenzierten Session propagiert als `missingSet` (unverändert).
- Kein stiller Fallback in irgendeinem Fall (M10b/M10c-Prinzip).
- Eligibility als reine Core-Funktion:
  `JumpSessionEligibility.eligible(for editingSessionID: UUID?, in sessions: [StoredSession]) -> [StoredSession]`
  — schließt die gerade bearbeitete Session und alle Sessions mit eigenem
  Jump aus; sortiert wie die Sidebar (name, case-insensitiv).

## 3. Formular

- Im Jump-Block über der Host-Zeile ein Umschalter
  `Gespeicherte Verbindung | Manuell` (Default Manuell — Bestandsverhalten).
- **Session-Modus:** Picker über die eligiblen Sessions; darunter eine
  nicht editierbare Zusammenfassung des aufgelösten Ziels
  (`host:port · user · Auth-Kurzform`, Auth-Kurzform wie im
  Login-Sets-Sheet). KEINE Host/Port/Login-Felder, KEIN Login-Dreiweg,
  kein „Als neues Login-Set speichern".
- **Manuell-Modus:** exakt das heutige Verhalten (Host/Port + Dreiweg).
- Validierung: Session-Modus verlangt eine Auswahl; die referenzierte
  Session muss eligibel sein (Ketten/Selbstreferenz werden schon beim
  Speichern abgelehnt, mit derselben Meldung wie beim Connect).
- Edit-Prefill: `sessionID` gesetzt ⇒ Session-Modus mit Vorauswahl.
- Neue `ConnectionViewModel`-Felder: `jumpSourceMode`
  (`enum JumpSourceMode: String, CaseIterable, Sendable { case session, manual }`,
  Default `.manual`), `jumpSessionID: UUID?`. Beide werden in
  `exitEditMode()`/`endEditing()` mitzurückgesetzt (M10b-Lektion).

## 4. Löschen = Rückstellung

- `SessionListViewModel.delete(_:)` prüft vor dem Löschen, welche
  Sessions die zu löschende als Jump referenzieren; die Lösch-Rückfrage
  nennt die Anzahl (App-Ebene).
- Beim Bestätigen: pro betroffener Session werden Host/Port/Username/
  authKind/keyPath der GELÖSCHTEN Session in deren JumpSpec kopiert und
  ihr aufgelöstes Secret (aus dem Session-Slot bzw. dem Login-Set der
  gelöschten Session) in den `secretID`-Slot des Jumps geschrieben;
  `sessionID` wird genullt. Agent-Logins übertragen kein Secret
  (M10d-Regel). Keychain-Fehler zählen, brechen nicht ab
  (`restored`/`secretFailures` wie `LoginSetDeleteResult`).
- Ein referenzierender Jump im SET-Modus der gelöschten Session behält
  seine Set-Referenz nicht — die Rückstellung schreibt genau die
  aufgelösten Werte, damit die Verbindung ohne die gelöschte Session
  weiterfunktioniert.

## 5. Export/Import

- Der Export löst einen Session-Jump zu konkreten Werten auf (Muster
  M10c: `jumpHost`/`jumpPort`/`jumpUsername`/`jumpAuthKind`/`jumpKeyPath`
  + `jumpPassword` nur bei `includePasswords`); die Referenz-UUID wandert
  NICHT mit (importierte Sessions bekommen ohnehin frische IDs).
- Fehlende/kaputte Referenz ⇒ Export exportiert die Spec-Eigenwerte und
  bricht nie ab (fehlendes Secret zählt wie gehabt in
  `missingPasswordCount`).
- Import: unverändert — es entsteht immer ein manueller Jump.

## 6. Tests

- Decode-Kompatibilität (`sessions.json` ohne `sessionID` ⇒ nil),
  Roundtrip.
- Auflösung über alle drei Login-Arten der referenzierten Session
  (Passwort, Key, Agent) inkl. Login-Set der referenzierten Session.
- Die drei Fehlerfälle: `missingJumpSession`, Kette, Selbstreferenz.
- Eligibility-Funktion (Ketten und die bearbeitete Session gefiltert,
  Sortierung).
- Rückstellung beim Löschen: Werte + Secret kopiert, Referenz genullt,
  Agent überträgt kein Secret, Keychain-Fehler zählt statt bricht.
- Export: Session-Jump aufgelöst; kaputte Referenz ⇒ Eigenwerte,
  kein Abbruch.
- Gated: Verbindung über einen SESSION-referenzierten Jump
  (Container 1 als gespeicherte Bastion → sshd2), plus der
  Ketten-Riegel gegen eine Bastion mit eigenem Jump.

## 7. Aufteilung

T1 Core (JumpSpec.sessionID + Resolver + Eligibility) → T2 VM
(Rückstellung + Export) → T3 App (Umschalter, Picker, Anzeige,
Fehlermeldungen, L10n) → T4 Abschluss (gated Rig-Test, Final-Review).
KEIN Release.

## 8. Bewusst NICHT in M11a

Keine Nutzung der LAUFENDEN Verbindung eines anderen Tabs; keine Ketten
(mehr als ein Hop); kein Session-Picker für den ZIEL-Host (die Session
IST das Ziel); kein Export der Referenz; keine automatische Umstellung
bestehender manueller Jumps auf passende gespeicherte Verbindungen.
