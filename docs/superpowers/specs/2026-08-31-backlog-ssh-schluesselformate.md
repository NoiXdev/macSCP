# Backlog: SSH-Schlüsselformate, und eine Meldung, die ihr Gegenteil sagt

**Angelegt:** 2026-08-31, aus einem Fehlerbericht von außen (v1.3.0).
Gemeldet wurde eins, beim Nachsehen sind es **zwei** Dinge.

## Der Bericht

> „it looks it doesn't support the SSH key in ed25519 format"

Gezeigt wurde dabei:

> SSH key format is not supported (currently: OpenSSH ed25519).

## Befund 1 — die Meldung liest sich als ihr eigenes Gegenteil

**Gemessen:** `SSHPrivateKeyLoader.authentication` versucht **ausschließlich**
`Curve25519.Signing.PrivateKey(sshEd25519:)`. Ed25519 ist also der **einzige**
Typ, der verbindet — der Kommentar am Lader sagt das auch so, und
`ManagedKey.canConnect` ist nur für ed25519 wahr.

Die Meldung meint demnach „unterstützt wird derzeit: OpenSSH ed25519". Der
Tester hat sie gelesen als „dein ed25519 wird nicht unterstützt" — und diese
Lesart ist die naheliegendere, weil der Satz mit „is not supported" beginnt
und die Klammer wie eine Beschreibung *des vorgelegten Schlüssels* wirkt.

**Das ist der billigste und wahrscheinlich wirksamste Teil dieses Eintrags.**
Ein Satz, der sagt, was der Schlüssel ist und was gebraucht wird, statt beides
in eine Klammer zu legen. Vier Kataloge.

## Befund 2 — RSA und ecdsa verbinden gar nicht

`ManagedKey` kann rsa- und ecdsa-Schlüssel **verwalten**, aber nicht mit ihnen
verbinden. Das war eine bewusste YAGNI-Entscheidung aus M3b und steht so im
Quelltext.

**Was daran heute nicht mehr trägt:** RSA ist auf älteren Servern weiterhin
der Normalfall, und der Tester ist genau darüber gestolpert. Ein Programm,
das einen Schlüssel importieren lässt und ihn dann nicht benutzen kann, hat
die Entscheidung an die falsche Stelle gelegt.

**Zu klären, bevor jemand das angeht:**

1. **Welcher der beiden Fälle war es beim Tester?** Der Bericht sagt es nicht,
   und die Meldung unterscheidet sie nicht — ein RSA-Schlüssel und ein
   ed25519-Schlüssel, der aus einem anderen Grund nicht las (PEM-Umhüllung,
   Passphrase-Fehler, der auf `unsupportedFormat` abgebildet wird), erzeugen
   **denselben Satz**. Befund 1 zu beheben beantwortet also auch diese Frage
   für den nächsten Bericht.
2. **Kann Citadel RSA überhaupt?** Vor jedem Entwurf nachsehen, statt es
   anzunehmen. Der Lader benutzt Citadels Parser; was der kann, entscheidet
   den Umfang.
3. **ssh-agent als Ausweg.** `AgentBackedPrivateKey` kennt bereits
   `ssh-ed25519`, `ecdsa-sha2-nistp256/384` und die RSA-SHA2-Kennungen. Wer
   seinen Schlüssel im Agenten hat, verbindet also womöglich schon heute —
   das gehört gemessen, denn falls ja, ist es die Antwort, die ohne neuen
   Parser auskommt.

## Was das nicht ist

- **Keine Änderung an TOFU** oder am harten Stopp bei einem Fingerabdruck-
  Konflikt.
- **Kein eigener Schlüsselparser.** Was Citadel nicht liest, liest macSCP
  nicht.

---

## Gemessen 2026-08-31 — und Befund 2 sieht danach anders aus

Fünf Wegwerf-Schlüssel, eigener `ssh-agent` auf einem Scratch-Socket, gegen
das Rig gefahren.

| | aus der **Datei** | über den **Agenten** |
|---|---|---|
| ed25519 | **ja** | ja |
| RSA | **nein** — parst, authentifiziert nicht | **ja** |
| ECDSA P-256/384/521 | **nein** — kein Parser | **ja, alle drei** |

### Warum RSA aus der Datei scheitert

Nicht am Parsen. Der Schlüssel wird gelesen und die Anmeldung fällt danach:

```
rsa/openssh/file: PARSED
rsa/openssh/file: AUTH FAILED: allAuthenticationOptionsFailed
```

Isoliert durch Ausführen — derselbe Schlüssel, derselbe Server, nur der
Signaturalgorithmus variiert:

```
-o PubkeyAcceptedAlgorithms=ssh-rsa       → Permission denied
-o PubkeyAcceptedAlgorithms=rsa-sha2-512  → RSA_SHA2_OK
```

**Citadels dateibasierter RSA-Signierer kann nur SHA-1** (`ssh-rsa`), und
OpenSSH hat das seit 8.8 aus den Vorgaben genommen. Der Agent-Weg umgeht
den Signierer und signiert `rsa-sha2-512` — deshalb funktioniert RSA dort.

**Damit ist „RSA ist reine Verdrahtung" widerlegt.** Diese Aussage stammte
aus dem Lesen der Abhängigkeit und war zweimal behauptet, bevor sie gemessen
wurde.

### Was der Agent-Weg schon konnte

`agentAuthConnectsECDSA` existiert seit `387dd9b` — ECDSA über den Agenten
war **nie** unmessbar, nur P-384 und P-521 hatten keine Abdeckung. Beide
verbinden.

### Weitere Funde

- **PEM-RSA** (`-----BEGIN RSA PRIVATE KEY-----`) scheitert bereits am
  Parser (`invalidOpenSSHBoundary`), also **anders** als OpenSSH-RSA. Nutzer
  haben beide Formen auf der Platte, und sie scheitern verschieden.
- Ein **verschlüsselter** RSA-Schlüssel parst über `decryptionKey:`
  problemlos; ohne Passphrase kommt `missingDecryptionKey`, was der
  bestehende Fehler-Abbilder schon behandelt.
- **Nebenbefund, kein Sicherheitsproblem:** die gegatete Suite lässt
  Agent-Sockets in `~/.ssh/agent/` liegen — `spawnAgent` beendet den Prozess,
  räumt den Eintrag aber nicht. Zwei Altlasten vom 21. und 28.08. gefunden.
- `AgentPrivateKeyFactory` führt dieselben fünf Typen als **zwei** Literale
  (`supportedKeyTypes` und der `switch`). Heute deckungsgleich, gezählt —
  eine Umbenennung kann sie still auseinanderziehen.

## Upstream (geprüft 2026-08-31)

Beide Lücken sind bei Citadel bekannt, beide haben Code, **keine ist
gemerged**:

| PR | Inhalt | Stand |
|---|---|---|
| **#135** | `rsa-sha2-256`/`-512` in neuer `RSASHA2.swift`, plus `rsaSHA2()` an `SSHAuthenticationMethod` | offen, **ohne Review**, letzte Aktivität 2026-07-26 |
| **#131** | dasselbe, schmaler (nur SHA-256) | offen seit Juni |
| **#136** | OpenSSH-Parsen für ECDSA P-256/384/521 | offen |

#135 begründet sich wortgleich mit unserem Befund: OpenSSH 8.8 hat `ssh-rsa`
aus den Vorgaben genommen.

**Die Abwägung, die daran hängt:** `swift-nio-ssh` kommt bereits über
`Wellz26/swift-nio-ssh` herein — den Fork eines Fremden, und der offene
Befund des Abhängigkeits-Eintrags. Eine zweite Fremdquelle darüber
verlängert dieselbe Kette. Warten, bis #135 landet, kostet nichts außer
Zeit; forken kostet die Kette.

## Was daraus für die Meldung folgt

Sie darf **nicht** auf „RSA aus einer Datei" zeigen — das funktioniert
nicht. Sie soll den erkannten Typ nennen (`SSHKeyType` kann das) und für RSA
und ECDSA auf den **ssh-agent** verweisen, den einzigen gemessenen Weg.

**Mit einem benannten Vorbehalt:** der RSA-Agent-Blob gilt als inkompatibel
mit Go-Servern (Gitea, Forgejo, SFTPGo, `gitlab-sshd`). **Nicht gemessen** —
gelesen. Wer die Meldung schreibt, sollte das entweder messen oder nicht
behaupten.
