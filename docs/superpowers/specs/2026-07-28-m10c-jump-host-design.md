# M10c — Jump-Host (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben („ja passt"; Mockup
eingefroren: `docs/design/assets/m10-mockups.html` Abschnitt 2)

## Ziel

Verbindungen über einen Zwischenhost (ProxyJump): optionaler Jump-Block im
Verbindungsformular mit eigener Login-Wahl (Login-Set aus M10b ODER
Manuell), eigener TOFU-Fluss für BEIDE Hops, gespeicherte Sessions merken
sich die Jump-Konfiguration. Bewusst EIN Hop — Ketten sind Backlog.

**Maintainer-Entscheidungen (2026-07-28):**

1. Export (M9a): Jump-Konfiguration wird AUFGELÖST mit exportiert
   (Login-Sets → Klartext-Werte wie in M10b; Passwort nur bei aktivierter
   Passwort-Option). Alte App-Versionen ignorieren die neuen Felder.
2. Ein Hop; Merge-Erkennung bleibt Ziel-only (Jump-Logins nehmen nicht an
   der Gleichheits-Erkennung teil — Backlog).

## 1. Verbindungsaufbau (Core, RISK)

- Machbarkeit verifiziert: die gepinnte Citadel-Version hat
  `SSHClient.jump(to: SSHClientSettings)` — öffnet einen
  direct-tcpip-Kanal über den bestehenden Client und fährt darüber eine
  volle SSH-Session mit EIGENER Auth und EIGENEM Host-Key-Validator
  (`.build/checkouts/Citadel/Sources/Citadel/Client.swift:197`).
- `SSHConnectionConfig.jump: Jump?` — `struct Jump: Equatable, Sendable`
  mit `host/port/username/auth` (gleiche Validierungsregeln wie das Ziel:
  Host/Username nicht-leer getrimmt, Port 1…65535; Prüfung im
  Config-Init).
- `CitadelFileSystem.connect` zweistufig: (1) Jump-Client via
  `SSHClient.connect` mit TOFU-Validator + Box für den JUMP-Host, (2)
  `jumpClient.jump(to:)` mit Ziel-Settings, TOFU-Validator + Box für das
  ZIEL, (3) `openSFTP()` auf dem Ziel-Client.
- TOFU-Retry-Semantik: die bisherige „unknown → Decider → upsert → genau
  EIN Retry"-Logik wird zu einer begrenzten Schleife mit **max. zwei
  Accept-Retries (einer pro Hop)**. Jeder Accept upserted den Key; derselbe
  Key prompted nie zweimal. Mismatch bleibt auf JEDEM Hop der harte Stopp
  (Decider wird nie gefragt); alle bestehenden TOFU-Invarianten
  unangetastet.
- Lebenszyklus: `CitadelFileSystem` hält den Jump-Client; `disconnect`
  schließt Ziel-Client, DANN Jump-Client; jeder Fehlpfad im Connect
  schließt einen bereits offenen Jump-Client (kein Leak). SFTP und
  Terminal (withPTY) multiplexen unverändert über den ZIEL-Client — die
  „eine Verbindung pro Tab"-Invariante bleibt.
- Fehler-Ehrlichkeit: `HostKeyError` trägt den Host (Prompt/Mismatch
  zeigen, welcher Hop). Auth-Fehler der Stufe 1 werden als NEUER Fall
  `RemoteFSError.jumpAuthenticationFailed` surfaced (additiv; bestehende
  Switches haben default-Zweige), damit das Formular die JUMP-Felder
  markiert statt irreführend das Ziel-Passwort; übrige Stufe-1-Fehler
  tragen einen Jump-Kontext im reason-String
  (`connectionFailed(reason: "jump host: …")`).
- Gated-Integrationstest am Rig: Container 1 (2222) als Jump zu
  Container 2 — Ziel-Adresse aus Sicht des Jump-Containers (compose-
  interner Servicename; Fallback Host-Gateway). T1 verifiziert die
  Erreichbarkeit empirisch, bevor der Test festgeschrieben wird.

## 2. Modell + Persistenz

- `StoredSession.jump: JumpSpec?` — verschachteltes
  `struct JumpSpec: Codable, Equatable, Sendable` mit `host: String`,
  `port: Int`, `username: String`, `authKind: StoredSession.AuthKind`,
  `keyPath: String?`, `loginSetID: UUID?`, `secretID: UUID`. Optional
  OHNE Custom-Decoder (groupID/loginSetID-Muster): Legacy-JSON liest nil.
- Keychain: manuelle Jump-Secrets liegen unter `secretID` (eigener Slot —
  der Session-Slot gehört dem Ziel); `secretID` wird beim Anlegen der
  JumpSpec generiert. Jump im Set-Modus nutzt den Set-Slot (M10b).
- Session-Löschen löscht auch den Jump-Slot. Session-Update, das den
  Jump entfernt oder auf Set-Modus wechselt, räumt den verwaisten
  `secretID`-Slot auf.
- **Login-Set-Löschen (M10b-Rückstellung) stellt AUCH Jump-Referenzen
  zurück**: Sessions, deren `jump.loginSetID` auf das Set zeigt, bekommen
  username/authKind/keyPath in die JumpSpec kopiert und das Set-Secret in
  ihren `secretID`-Slot; Zählung/Fehlertoleranz wie die bestehende
  Rückstellung (Keychain-Fehler zählt, bricht nicht). Die Lösch-Rückfrage
  zählt Jump-Referenzen mit.
- Merge-Erkennung (LoginMergePlanner) bleibt unverändert Ziel-only.
- Auflösung beim Connect: Jump-Login analog `LoginResolver` (Set →
  Werte + Set-Secret; fehlendes referenziertes Set ⇒ ehrliche Meldung,
  kein stiller Fallback — wie M10b fürs Ziel).

**Bekannte Einschränkung (Final-Review M-5, KnownHosts):** Der bekannte
Schlüssel des ZIELS wird ausschließlich über dessen eigene literale
Adresse (`host`/`port`) verwaltet — `CitadelFileSystem` reicht beim
Zwei-Hop-Connect `config.host`/`config.port` unverändert an den
Ziel-`TOFUHostKeyValidator` durch, ohne den benutzten Jump in den
Schlüssel einzubeziehen. Zwei verschiedene Maschinen, die zufällig unter
derselben literalen Ziel-Adresse über unterschiedliche Bastions erreicht
werden, teilen sich dadurch EINEN KnownHosts-Eintrag. Das ist bewusst
fail-closed: ein abweichender Schlüssel löst weiterhin den harten Stop
(`HostKeyError.mismatch`, kein Decider-Aufruf) aus statt eines stillen
Falls — die Sicherheitseigenschaft bleibt gewahrt, nur die Fehlermeldung
nennt aktuell nicht den Jump-Kontext ("über welchen Bastion"). Ein
jump-bewusster Schlüssel (z. B. `host@via-jump-host`) ist Backlog, kein
M10c-Scope.

## 3. Formular (exakt Mockup Abschnitt 2)

- Toggle „Über einen Zwischenhost verbinden (ProxyJump)", Default AUS.
- Eingeschaltet: Bastion-Host + Port + die M10b-Dreiweg-Bausteine fürs
  Jump-Login (Login-Set-Picker ODER Manuell mit User + Passwort/Key).
  Bastion und Ziel dürfen verschiedene Sets nutzen; „Als neues Login-Set
  speichern" gibt es NUR am Ziel (Jump bietet Set/Manuell — YAGNI).
- Validierung: Toggle an ⇒ Jump-Host nicht-leer, Port numerisch, Login
  gewählt (Set) bzw. User+Passwort/Key ausgefüllt (Manuell).
- Edit-Modus zeigt den gemerkten Zustand (JumpSpec ⇒ Toggle an +
  Set-Vorauswahl bzw. Manuell-Prefill; Passwortfeld „unverändert"-Prompt).
- Beim Erstkontakt bis zu ZWEI TOFU-Prompts nacheinander (erst Bastion,
  dann Ziel) über den bestehenden Prompt-Mechanismus — der Prompt zeigt
  den jeweiligen Host.
- ConnectionViewModel-Felder (Core, reine stored properties):
  `jumpEnabled: Bool`, `jumpHost/jumpPort/jumpUsername/jumpPassword/
  jumpKeyPath: String`, `jumpAuthChoice`, `jumpLoginMode`,
  `jumpSelectedLoginSetID: UUID?`.

## 4. Export/Import (M9a-Erweiterung)

- `ExportedSession` bekommt OPTIONALE Jump-Felder (Host/Port/User/
  authKind/keyPath + `jumpPassword` nur bei `includePasswords`);
  Login-Sets werden beim Export aufgelöst (M10b-Muster); fehlendes
  Jump-Set exportiert die Session mit ihren Jump-Eigenwerten, Export
  bricht nie ab. Fehlende Jump-Secrets zählen im missingPasswordCount.
- Format bleibt v1 (additive optionale Felder): alte App-Versionen
  ignorieren sie und importieren die Session ohne Jump.
- Import legt für mitgelieferte Jump-Passwörter frische `secretID`-Slots
  an; Keychain-Fehler zählen wie gehabt.
- ssh-config-ProxyJump-Import: Backlog (Mockup-Entscheid).

## 5. Tests

- Config: Jump-Validierung (leerer Host/User, Port-Grenzen), Equatable.
- JumpSpec: Decode-Kompat alter sessions.json (nil), Roundtrip.
- TOFU-Zweistufigkeit mock-seitig: Accept je Hop (zwei Retries), Mismatch
  auf Hop 1 und Hop 2 = harter Stopp, Reject speichert nichts.
- Secret-Lebenszyklus: Save legt `secretID`-Slot an, Session-Delete räumt
  ihn, Jump-Entfernen/Set-Wechsel räumt ihn, Set-Lösch-Rückstellung
  kopiert Werte+Secret in die JumpSpec.
- Resolver: Jump-Set-Auflösung inkl. fehlendem Set (typisierter Fehler).
- Export: aufgelöster Jump, Passwort-Gating, Import-Roundtrip mit
  frischer secretID; Alt-Datei ohne Jump-Felder liest nil.
- Gated: Jump-Integrationstest Container 1 → Container 2 (SFTP-Listing
  über den Hop, byte-echter Transfer optional).
- UI: visueller Smoke (T4-Checkliste an den Maintainer).

## 6. Aufteilung

T1 Config + zweistufiger Connect + Rig-Test (RISK) → T2 JumpSpec + VM
(Save/Edit/Delete/Rückstellung/Resolver/Export) → T3 App (Formular-Block,
Wiring, Edit, L10n) → T4 Abschluss. KEIN Release (stehende Regel).

## 7. Bewusst NICHT in M10c

- Keine Jump-Ketten (ein Hop), kein ssh-config-ProxyJump-Import, keine
  Merge-Erkennung für Jump-Logins, kein „Als neues Set speichern" im
  Jump-Block, kein ssh-agent (M10d).
