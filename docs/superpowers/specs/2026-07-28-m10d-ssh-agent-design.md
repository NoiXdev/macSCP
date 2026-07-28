# M10d — ssh-agent-Authentifizierung (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben („los gehts")

## Ziel

Authentifizierung über den lokalen ssh-agent als DRITTE Auth-Art überall
(Formular Ziel + Jump, Login-Sets, gespeicherte Sessions). Der private
Schlüssel verlässt den Agent nie; macSCP spricht das Agent-Protokoll über
`SSH_AUTH_SOCK` selbst.

**Maintainer-Entscheidungen (2026-07-28):**

1. Scope: NUR Agent-Auth. Agent-FORWARDING (inkl. der Einstellung
   „Weiterleiten pro Host + globaler Default") ist ein eigener späterer
   Meilenstein — die Machbarkeits-Analyse hat gezeigt, dass Forwarding
   einen gepflegten Fork von swift-nio-ssh erfordert (Parser wirft bei
   `auth-agent@openssh.com`-Channel-Opens hart; Outbound-Channel-Requests
   sind verschlossen), während Auth ohne Fork über den offiziellen
   Erweiterungspunkt geht.
2. Kein Identitäts-Picker in M10d: Verhalten wie OpenSSH — Identitäten
   werden der Reihe nach angeboten. Bevorzugte Identität pinnen = Backlog.

## Machbarkeits-Grundlage (verifiziert gegen die vendorten Quellen)

- `NIOSSHPrivateKeyProtocol` + `NIOSSHPrivateKey.init(custom:)` sind der
  offizielle Custom-Signer-Haken (swift-nio-ssh `CustomKeys.swift:23-89`,
  `NIOSSHPrivateKey.swift:50-52`); Citadels `Insecure.RSA.PrivateKey`
  (`Citadel/Algorithms/RSA.swift:167-255`) ist das Produktions-Vorbild.
- Der zu signierende Blob ist exakt RFC 4252 §7
  (`UserAuthSignablePayload.swift:32-55`) — identisch mit dem `data`-Feld
  von `SSH_AGENTC_SIGN_REQUEST`. Der Custom-Key erhält ihn roh/ungehasht.
- Keine `NIOSSHAlgorithms`-Registrierung nötig (Registry wird nur beim
  PARSEN fremder Typen konsultiert; wir senden nur).
- swift-nio (NIOPosix `ClientBootstrap` mit
  `SocketAddress(unixDomainSocketPath:)`) ist bereits transitiv im Baum.

## 1. Agent-Client (Core, RISK)

- `SSHAgentCodec` (pur, testbar): Framing uint32-Länge + Typ-Byte;
  Requests `SSH_AGENTC_REQUEST_IDENTITIES` (11) /
  `SSH_AGENTC_SIGN_REQUEST` (13); Antworten
  `SSH_AGENT_IDENTITIES_ANSWER` (12) / `SSH_AGENT_SIGN_RESPONSE` (14) /
  `SSH_AGENT_FAILURE` (5). Identities-Antwort: Liste aus
  (Pubkey-Blob, Kommentar); aus dem Blob werden Typ-String und
  SHA256-Fingerprint abgeleitet (bestehende Fingerprint-Helfer aus M3c
  wiederverwenden, sofern passend).
- `SSHAgentClient`: Transport-Protokoll (injizierbar; produktiv
  NIO-`ClientBootstrap` auf den UDS-Pfad aus `SSH_AUTH_SOCK`), API
  `listIdentities() async throws -> [AgentIdentity]` und
  `sign(publicKeyBlob:data:flags:) async throws -> Data`
  (Signatur-Antwort roh: `string` mit Algo + Blob).
- RSA-Identitäten (Blob-Typ `ssh-rsa`): SIGN_REQUEST mit
  `SSH_AGENT_RSA_SHA2_256` (2) bzw. bevorzugt `…_512` (4) Flags —
  benanntes Restrisiko, gedeckt durch den gated Live-Test.
- Typisierte Fehler: `AgentError.socketUnavailable`
  (`SSH_AUTH_SOCK` fehlt/Verbindung scheitert), `.noIdentities`,
  `.refused` (FAILURE-Frame), `.protocolError(reason:)`.

## 2. NIOSSH-Anbindung + Connect (Core, RISK)

- `AgentBackedPrivateKey: NIOSSHPrivateKeyProtocol` (eine Instanz pro
  Agent-Identität; `signature(for:)` reicht den Blob an
  `SSHAgentClient.sign` durch) + `AgentSignature: NIOSSHSignatureProtocol`
  und `AgentBackedPublicKey: NIOSSHPublicKeyProtocol`, die den vom Agent
  gelieferten Blob VERBATIM re-emittieren.
- `SSHConnectionConfig.AuthMethod.agent` (ohne Payload). Der Connect-Pfad
  (CitadelFileSystem) baut dafür ein `SSHAuthenticationMethod`, das die
  Agent-Identitäten DER REIHE NACH anbietet (OpenSSH-Verhalten; NIOSSHs
  Delegate wird pro Fehlversuch erneut gefragt — Citadel-Muster
  `SSHAuthenticationMethod` mit konsumierbarer Liste). Bounded: jede
  Identität genau einmal.
- Identitäten werden EINMAL beim Connect gelistet (kein Re-Listing
  zwischen den Versuchen); Jump-Hop und Ziel-Hop dürfen beide `.agent`
  nutzen (je eigene Signaturen, gleicher Agent).
- Fehler-Mapping: `.socketUnavailable`/`.noIdentities` ⇒ eigene
  lokalisierte, EHRLICHE Meldungen (kein generisches „Auth failed");
  alle Identitäten abgelehnt ⇒ `RemoteFSError.authenticationFailed`
  (am Jump-Hop: `jumpAuthenticationFailed` — bestehende
  Stage-1-Klassifikation greift unverändert). TOFU-Invarianten
  unangetastet.

## 3. Modell überall (Core)

- `StoredSession.AuthKind.agent` (Raw „agent" — exakt der Wert, für den
  M10bs logins.json-Record-Store vorwärtskompatibel gebaut wurde).
  `keyPath` bleibt nil; Keychain-Slots bleiben für Agent-Logins unberührt
  (Slot-Hygiene: Wechsel auf `.agent` räumt einen alten manuellen Slot
  wie der Set-Wechsel).
- `JumpSpec.authKind` erbt `.agent` automatisch (gleiches Enum).
- Login-Sets: `.agent`-Sets (kein Secret, kein keyPath); Editor drittes
  Segment; AGENT-Badge im Sheet; `LoginResolver.resolve/resolveJump`
  liefern `ResolvedLogin` mit `authKind: .agent`, `secret: nil`.
- Merge-Erkennung: Agent-Gruppen = gleicher Username (kein
  Secret-Vergleich; Sessions mit `.agent` nehmen OHNE Keychain-Zugriff
  teil).
- Lösch-Rückstellung: `.agent`-Sets kopieren nur username/authKind
  zurück (kein Secret-Transfer — trivialer Sonderfall der bestehenden
  Maschinerie).
- Export/Import: `authKind` „agent" wandert als Wert mit (kein Passwort);
  Import übernimmt ihn.

## 4. Bekannte Downgrade-Grenze (bewusst akzeptiert)

`logins.json` ist dank M10b sicher (alte Versionen überlesen
„agent"-Records). `sessions.json` und Export-Dateien sind es NICHT: eine
ältere App-Version scheitert beim Enum-Decode einer „agent"-Session
(Datei liest leer bzw. Import schlägt fehl). Betrifft nur Downgrades
NACH Nutzung des Features; als Grenze dokumentiert, keine Gegenmaßnahme
in M10d.

### 4a. T2-Review-Nachträge (Reconnect-Verhalten + RSA-Grenze)

**Pro-Identität-RECONNECT statt wiederholter Delegate-Aufrufe (verifiziert):**
Citadels `SSHAuthenticationMethod.custom(_:)` konsumiert seinen Delegate
GENAU EINMAL pro Verbindungsversuch (`implementations.removeFirst()` leert
die einzige `.custom(delegate)`-Eintragung beim ersten Aufruf endgültig).
Bietet der Agent N Identitäten an, bedeutet das N SEPARATE
`SSHClient.connect()`/`jump(to:)`-Aufrufe — je einen FRISCHEN
`SSHAuthenticationMethod.custom(...)`-Wrapper um dieselbe
`AgentAuthDelegate`-Instanz, deren interner Cursor (`remaining`) so über
die Aufrufe hinweg fortschreitet (siehe `CitadelFileSystem.connectHop`).
Aus Sicht des Ziel-Servers erscheint jeder Fehlversuch als ein SEPARATER,
fehlgeschlagener Login — sysadmin-seitig sichtbar z. B. in `auth.log`/
`journalctl` als mehrere `Failed publickey`-Einträge statt eines einzigen
Login-Vorgangs mit mehreren Angeboten. Die Anzahl ist bewusst begrenzt
(siehe M-3/I-3: Cap auf `min(identities.count, 6)`, MaxAuthTries-Parität),
damit ein Agent mit vielen Identitäten keinen Login-Spam gegen den Server
erzeugt.

**Bekannte RSA-Grenze (verifiziert, nicht hypothetisch):** Eine
`ssh-rsa`-Identität wird über den Agent mit dem Blob-Tag `rsa-sha2-512`
angeboten (swift-nio-ssh koppelt Algorithmusname und Blob-Tag für
`.custom`-Schlüssel untrennbar, siehe `AgentBackedPrivateKey.swift`,
`AgentAlgorithm.RSASha512`-Dokumentation). Gegen echtes OpenSSH `sshd`
funktioniert das (gated `agentAuthConnectsRSA`-Test, Docker-Rig). Gegen
Server auf Basis von Go's `golang.org/x/crypto/ssh` (Gitea, Forgejo,
Gogs, `gitlab-sshd`, SFTPGo u. a.) schlägt es fehl — direkt gegen
`x/crypto/ssh` verifiziert, exakte Fehlermeldung:

```
ssh: signature algorithm "rsa-sha2-512" isn't a key format; key is
malformed and should be re-encoded with type "ssh-rsa"
```

ed25519- und ECDSA-Identitäten sind NICHT betroffen (Blob-Tag und
Signaturname sind bei ihnen bereits identisch, keine Drei-Wege-Kopplung
nötig). Der eigentliche Fix müsste in swift-nio-ssh selbst passieren
(Blob-Tag und Algorithmus-/Signaturname für `.custom`-Schlüssel
entkoppelbar machen) — außerhalb des macSCP-Scopes; als bekannte Grenze
dokumentiert, nicht in M10d behoben.

## 5. App (Formular + Sets-Editor)

- Auth-Segmente Ziel UND Jump: `Passwort | SSH-Key | Agent`. Agent-Modus
  blendet Passwort-/Key-Felder aus; Validierung verlangt nur den
  Username. `selectAuthChoice`/`selectJumpAuthChoice` räumen Secrets beim
  Wechsel wie gehabt.
- Set-Editor: drittes Segment „Agent" (Name + Username genügen).
  LoginSetsSheet: AGENT-Badge (Muster KEY/PASS), Kurzform `user · Agent`.
- Fehlermeldungen: „Kein SSH-Agent erreichbar (SSH_AUTH_SOCK)."
  / „Der SSH-Agent hat keine Identitäten geladen." EN/DE, dem
  Auth-Segment zugeordnet (Jump-Varianten markieren die Jump-Felder).
- Edit-Prefill: `.agent` ⇒ Segment Agent, keine Secret-Felder.

## 6. Tests

- Codec pur: Framing-Roundtrip, Identities-Parse (mehrere, leer),
  Sign-Request-Bytes (inkl. RSA-Flags), FAILURE-Frame ⇒ `.refused`,
  Garbage ⇒ `.protocolError`.
- Client mit Mock-Transport: listIdentities/sign-Sequenz, Socket-tot ⇒
  `.socketUnavailable`.
- Auth-Reihenfolge mit Mock: Identitäten nacheinander, Erfolg stoppt,
  alle abgelehnt ⇒ authenticationFailed; `.agent` am Jump ⇒
  `jumpAuthenticationFailed`-Klassifikation.
- Modell: AuthKind.agent Decode/Encode, Set ohne Secret, Resolver,
  Merge-Gruppierung per Username, Rückstellung, Export/Import-Roundtrip.
- Gated (MACSCP_ITEST, Rig): Test startet EIGENEN `ssh-agent`-Prozess
  (SSH_AUTH_SOCK aus dessen Ausgabe), `ssh-add` mit generiertem
  ed25519-Key, Pubkey per docker-exec ins Rig (M3b-Muster), Connect mit
  `.agent` ⇒ list("/"); RSA-Variante für die sha2-Flag-Aushandlung;
  Agent-Prozess im Teardown beendet. Ein Test mit totem Socket-Pfad ⇒
  `.socketUnavailable` (ungated möglich).
- App: visueller Smoke (T5) inkl. echtem Agent des Maintainers
  (1Password/ssh-agent).

## 7. Aufteilung

T1 Agent-Codec + Client (RISK) → T2 NIOSSH-Key + AuthMethod.agent +
Connect inkl. Jump + gated Live-Tests (RISK) → T3 Modell/VM/Sets/Export →
T4 App (Segmente, Editor, L10n) → T5 Abschluss. KEIN Release (stehende
Regel).

## 8. Bewusst NICHT in M10d

- Kein Agent-Forwarding (eigener Fork-Meilenstein, Backlog), keine
  Pro-Host-Weiterleitungs-Settings, kein Identitäts-Picker/-Pinning,
  keine sessions.json-Downgrade-Absicherung, kein FIDO/sk-Sonderweg
  (sk-Identitäten laufen, sofern der Agent sie normal signiert).
