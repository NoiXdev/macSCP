# RSA aus der Datei — lokal verankern statt forken — Entwurf

**Stand:** 2026-08-31. Antwort auf `2026-08-31-backlog-ssh-schluesselformate.md`
und auf die Frage des Maintainers, ob sich die fehlenden Protokollteile
**lokal im Projekt** verankern und später wieder entfernen lassen.

**Die Antwort ist ja** — für unverschlüsselte Schlüssel, ohne Fork und ohne
handgeschriebene Kryptographie. Die Grenze verläuft an einer Stelle, die
gemessen ist und unten benannt wird.

---

## Der gemessene Ausgangszustand

| | aus der **Datei** | über den **Agenten** |
|---|---|---|
| ed25519 | ja | ja |
| RSA | **nein** — parst, authentifiziert nicht | ja |
| ECDSA P-256/384/521 | **nein** — kein Parser | ja, alle drei |

RSA scheitert **nicht am Parsen**: Citadels dateibasierter Signierer kann nur
SHA-1 (`ssh-rsa`), und OpenSSH hat das seit 8.8 aus den Vorgaben genommen.
Isoliert durch Ausführen — derselbe Schlüssel, derselbe Server, nur der
Algorithmus variiert (`ssh-rsa` abgelehnt, `rsa-sha2-512` angenommen).

## Warum das lokal geht

**Die Einsteckstelle gehört NIOSSH, nicht Citadel** — und macSCP bedient sie
bereits vollständig. `AgentBackedPrivateKey` erfüllt
`NIOSSHPrivateKeyProtocol`, `AgentBackedPublicKey` das öffentliche
Gegenstück, `AgentSignature` das Signatur-Protokoll, und **`RSASha512` steht
dort schon** mit dem richtigen Namen auf der Leitung.

Ein Datei-Zwilling unterscheidet sich in **genau einem** Punkt: er rechnet
die Signatur, statt sie zu erfragen.

**Das Rechnen kommt von swift-crypto**, nicht von Hand: `_CryptoExtras` ist
ein deklariertes Bibliotheksprodukt des Pakets, das macSCP ohnehin
einbindet, und `_RSA.Signing.PrivateKey.signature(for:padding:)` nimmt einen
`Digest` entgegen.

## Die Hürde, und was sie erzwingt

**Citadels geparster Schlüssel ist nicht wiederverwendbar.**
`Insecure.RSA.PrivateKey.privateExponent` ist `internal`, und
`signature(for:)` verdrahtet SHA-1 fest. macSCP muss den **OpenSSH-Container
selbst lesen**.

**Das ist Container-Parsen, keine Kryptographie** — Base64 plus ein
dokumentiertes Binärformat, um an Modulus und Exponenten zu kommen. Das
Rechnen bleibt bei swift-crypto. Diese Unterscheidung ist der Grund, warum
die Projektregel „kein eigener Schlüsselparser" hier nicht verletzt wird, und
sie gehört ausgesprochen statt stillschweigend umgedeutet.

## Die Grenze: verschlüsselte Schlüssel bleiben draußen

OpenSSH verschlüsselt private Schlüssel mit **bcrypt_pbkdf**. Gemessen:
Citadels Umsetzung ist `internal`, und swift-crypto liefert PBKDF2 und
Scrypt, aber **kein bcrypt_pbkdf**. Lokal zu verankern hieße, eine
Blowfish-basierte Schlüsselableitung von Hand zu schreiben.

**Das wird nicht gebaut.** Handgeschriebene Kryptographie ist in diesem
Projekt keine Option, und ein Entwurf, der sie durch die Hintertür einführt,
wäre schlechter als gar keine RSA-Unterstützung.

**Kein Rückschritt:** ein verschlüsselter RSA-Schlüssel scheitert heute
ebenso. Für ihn gibt es einen **gemessenen** Weg — den ssh-agent, in dem ein
passphrase-geschützter Schlüssel ohnehin meist liegt. Die Meldung sagt das.

## Der Entwurf

### Drei Teile, einer davon der Rückbau

**1. Den Container lesen.** Ein reiner Wert in Core, der aus einem
unverschlüsselten OpenSSH-RSA-Schlüssel die Bestandteile herausliest. Er
**entschlüsselt nichts**: trifft er einen verschlüsselten Schlüssel, sagt er
das als eigenes Ergebnis, nicht als Fehler — der Aufrufer verweist dann auf
den Agenten.

**2. Lokal signieren.** Ein Typ nach dem Vorbild von
`AgentBackedPrivateKey`, der dieselben NIOSSH-Protokolle erfüllt und die
Signatur über `_RSA.Signing` rechnet.

**Zwei Festlegungen, die jemand sonst „verbessert":**

- **Die Auffüllung ist PKCS#1 v1.5**, nicht PSS. RFC 8332 schreibt
  RSASSA-PKCS1-v1_5 vor; swift-crypto nennt die Wahl
  `.insecurePKCS1v1_5`, und dieser Name lädt zum Ändern ein. Ein Wechsel auf
  PSS erzeugt Signaturen, die **kein** SSH-Server annimmt. Das gehört als
  Kommentar an die Stelle **und** in einen Test.
- **`rsa-sha2-512` zuerst.** Ob zusätzlich `rsa-sha2-256` angeboten wird, ist
  beim Umsetzen zu **messen** — nicht anzunehmen: das Angebot geht über
  NIOSSHs Mechanismus, und ob sich zwei Algorithmen für denselben Schlüssel
  anbieten lassen, ist ungeprüft.

**3. Der Rückbau, als Wächter.** Landet Citadels PR #135, wird der lokale Typ
gelöscht und der Lader zeigt auf `rsaSHA2()`. Damit das eine Löschung bleibt
und keine Archäologie:

> Ein Wächter hält fest, dass der lokale Signierer **genau eine**
> Aufrufstelle hat — hinter `SSHPrivateKeyLoader`.

Verbreitet er sich, fällt das auf, bevor der Rückbau ansteht. Und weil das
eine **positive** Prüfung mit einer Zahl ist, kann sie nicht still veralten.

### Was der Nutzer danach sieht

| Schlüssel | Ergebnis |
|---|---|
| ed25519, Datei | verbindet (wie bisher) |
| **RSA unverschlüsselt, Datei** | **verbindet** |
| RSA verschlüsselt, Datei | Meldung: über den ssh-agent |
| ECDSA, Datei | Meldung: über den ssh-agent |
| alles im Agenten | verbindet (gemessen) |

Die Meldung nennt den **erkannten Typ** — `SSHKeyType` aus Citadel kann das —
statt einer Klammer, die sich als ihr Gegenteil lesen lässt.

**Ein Vorbehalt, ausdrücklich ungemessen:** der RSA-Blob des Agenten gilt als
inkompatibel mit Go-Servern (Gitea, Forgejo, SFTPGo). Gelesen, nicht geprüft
— wer die Meldung schreibt, misst das oder behauptet es nicht.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles: das Container-Lesen gegen erzeugte Schlüssel, die
Signatur gegen das Rig, die Auffüllung, die Verweigerung bei einem
verschlüsselten Schlüssel, und die eine Aufrufstelle.

**Nicht prüfbar** ist das Verhalten fremder Server jenseits des Rigs — das
Rig ist OpenSSH, und ein Go-Server ist nicht darin.

## Was ausdrücklich nicht dazugehört

- **Kein bcrypt_pbkdf**, keine handgeschriebene Kryptographie, keine
  Entschlüsselung privater Schlüssel.
- **Kein Fork** von Citadel und keine zweite Fremdquelle in
  `Package.resolved`.
- **Keine ECDSA-Datei-Unterstützung** in diesem Vorgang. Dasselbe Muster
  wäre dort sogar kleiner (`P256/384/521.Signing.PrivateKey(rawRepresentation:)`
  nimmt die rohen Bytes ohne DER-Umweg) — aber dieselbe Verschlüsselungs-
  grenze gilt, und ein Vorgang nach dem anderen.
- **Keine Änderung an TOFU** und keine am harten Stopp bei einem
  Fingerabdruck-Konflikt.
