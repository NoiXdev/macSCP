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
