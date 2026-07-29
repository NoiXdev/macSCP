# M11e — Backlog-Sweep (Design)

Datum: 2026-07-29 · Status: vom Maintainer freigegeben („passt")

## Ziel

Die aus M10 gesammelten Härtungs- und Hygiene-Punkte abräumen und die
zwei nutzerrelevanten Grenzen dokumentieren, bevor jemand darüber
stolpert. Kein neues Feature.

**Reihenfolge-Entscheid (Maintainer 2026-07-29):** M11e zuerst, danach
M11a (Zwischenhost aus gespeicherter Verbindung — als REFERENZ auf eine
gespeicherte Session), M11b (Update-Prüfung), M11c (rekursive Rechte),
M11d (externes Terminal).

## 1. README „Known limitations" (EN, vor `## Install`)

Drei Punkte, sachlich und ohne Stack-Begriffe im Intro-Bereich (der
Abschnitt selbst darf technisch sein):

1. **ssh-agent + RSA:** RSA-Identitäten aus dem Agent authentifizieren
   gegen OpenSSH-Server; Server auf Go-Basis (Gitea, Forgejo, SFTPGo,
   gitlab-sshd) lehnen sie ab. ed25519/ECDSA sind unbetroffen. Die App
   zeigt den Fall derzeit als gewöhnlichen Auth-Fehler.
2. **Mehrere Agent-Identitäten:** werden als GETRENNTE Login-Versuche
   angeboten (max. 6). Auf Servern mit fail2ban (Standard
   `maxretry = 5`) kann das ab etwa fünf Identitäten eine IP-Sperre
   auslösen.
3. **Audit-Log-Ort:** `~/Library/Application Support/macSCP/audit/`
   (eine Datei pro gespeicherter Verbindung).

## 2. Härtungen (Core)

- **Agent-Frame-Limit:** `SSHAgentClient` akzeptiert nur Frames bis
  256 KiB (OpenSSH-Maximum); größere deklarierte Längen ⇒
  `AgentError.protocolError`, statt bis zum Deadline zu puffern.
- **Signatur-Timeout:** das Warten in `AgentBackedPrivateKey.signature`
  bekommt ein eigenes Wall-Clock-Limit (15 s) und wirft danach
  `AgentError.protocolError("timeout")` — schützt gegen den Fall, dass
  die Promise nie erfüllt wird (z. B. Task auf einer bereits
  heruntergefahrenen Event-Loop).
- **Ehrliche Meldung bei unbrauchbaren Identitäten:** wenn ALLE
  Agent-Identitäten von einem nicht unterstützten Typ sind, liefert der
  Connect nicht mehr `noIdentities` („Agent hat keine Identitäten
  geladen"), sondern einen eigenen Fall `AgentError.noUsableIdentities`
  mit eigener EN/DE-Meldung.
- **Aufräumen:** die nach dem M10d-Fix redundante `authRejectionError`-
  Variable in der Reconnect-Schleife entfällt (Verhalten identisch).
- **Ziel-Set-Asymmetrie (M10c):** ein ins Leere zeigendes Login-Set am
  ZIEL wird beim Verbinden aus dem Formular still ignoriert, während die
  Jump-Hälfte korrekt verweigert. Angleichen: `resolveSelectedLoginSet`
  liefert wie sein Jump-Gegenstück `Bool`, der Submit bricht mit der
  bestehenden `loginSets.missingSet`-Meldung ab (kein stiller Connect mit
  veralteten Feldern, keine Persistenz einer toten Referenz).

## 3. Audit-Log: Jump-Kontext

`AuditRecorder.recordConnected` bekommt einen optionalen Jump-Host; das
Detail des `connected`-Events nennt ihn (`via <jumphost>`), wenn über
einen Zwischenhost verbunden wurde. NUR der Host — keine Benutzernamen
der Bastion, keine Zugangsdaten. Direkte Verbindungen bleiben
byte-identisch zu heute.

## 4. Test-Hygiene

- `SSH_AUTH_SOCK`-Wettlauf: `AgentAuthTests` und die gated
  Agent-Integrationstests setzen beide die Prozess-Umgebung; `.serialized`
  wirkt nur INNERHALB einer Suite. Beide über eine gemeinsame
  Serialisierung (gemeinsame Suite-Zugehörigkeit oder ein globales
  Lock um die env-Mutation) absichern — latenter CI-Flake.
- Gated Jump-/Agent-Tests räumen ihre temporären KnownHosts-Verzeichnisse
  auf (`defer`-Muster der Datei, vier Stellen — inklusive der drei
  vorbestehenden Lecks).
- `transportErrorMapsToProtocolErrorDuringOperation` prüft heute den
  Mock-Erschöpfungs-Pfad statt der behaupteten Transport-Fehler-
  Abbildung: zwei Antworten einreihen bzw. auf einen einzigen do/catch
  umstellen.

## 5. Tests

Für jede Härtung ein gezielter Test: Frame über 256 KiB ⇒ protocolError;
Signatur-Timeout (Mock-Transport, der nie antwortet) ⇒ protocolError;
alle Identitäten unbrauchbar ⇒ `noUsableIdentities`; Ziel-Set-Asymmetrie
⇒ Submit verweigert (VM-Ebene, soweit ohne App-Target prüfbar; sonst
ehrlich als App-Layer-Verdrahtung im Report vermerken); Audit-Detail mit
und ohne Jump. Volle Suite + gated Suiten grün.

## 6. Aufteilung

T1 Core-Härtungen + Ziel-Set-Asymmetrie → T2 Audit-Jump-Kontext +
Test-Hygiene → T3 README + Abschluss (Koordinator). KEIN Release.

## 7. Bewusst NICHT in M11e

Agent-Forwarding (eigener Fork-Meilenstein), Identitäts-Picker/Pinning,
`deinit`-Sicherheitsnetz (widerspricht der Architektur-Regel „die UI
besitzt Lebenszyklen explizit"), ECDSA-P384/P521-Tests, der
unreproduzierte Suite-Hang (bleibt CI-Beobachtung), kosmetische
Duplikate (`supportedKeyTypes`-Liste, Test-Vektor-Konstruktion),
`ignoredMergeGroups`-Pruning, ssh-config-ProxyJump-Import.
