# Tab-Kontextmenü und Umordnen — Entwurf

**Stand:** 2026-08-27. Grundlage:
`docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`,
Punkte B1 (Kontextmenü), B2 (Umordnen) und B3 (woher die Einträge kommen).

Der Backlog verlangt, B1 und B2 **zusammen** zu bauen: „nach links / nach
rechts" und das Ziehen sind dieselbe zugrunde liegende Fähigkeit, nur zwei
Bedienwege. Getrennt gebaut entsteht die Umordnung zweimal.

---

## Der gemessene Ausgangszustand

| | |
|---|---|
| `TabStripView.swift` | kein `contextMenu`, kein `onMove`, kein `draggable` — beides ist neu |
| Tabs über einen Neustart | **werden nicht wiederhergestellt**; es gibt keinen solchen Weg |
| `TabsViewModel` | hält `tabs`, `activate`, `closeTab`, `addTab` — generisch über `Tab`, in Core |
| `TabCloseWarning` | prüft pro Tab laufende **und** eingehende Übertragungen, liefert einen Text |
| `teardown(_ tab:reason:)` | der eine Abbauweg: Warteschlange abbrechen → Terminal herunterfahren → trennen |
| `ProtocolCapabilities` | trägt `supportsShell`: `true` bei SSH, `false` bei S3 und WebDAV |
| `BrowserContextMenu.entries(…)` | Vorbild: Menü als reiner Wert in Core, mit eigener Testdatei |
| „Speichern & verbinden" | existiert nur **im Formular vor dem Verbinden**; eine laufende Ad-hoc-Verbindung lässt sich heute nicht nachträglich sichern |

---

## 1. Woher die Einträge kommen

B3 legt zwei Dinge fest. Das erste bleibt: **kein `switch` über
`ConnectionKind`.** Beim zweiten — „stattdessen Beiträge wie `fileActions`" —
weicht dieser Entwurf ab, und zwar gemessen.

| Herkunft | Einträge | Mechanismus |
|---|---|---|
| Der Tab selbst | Schließen, Andere schließen, Nach links, Nach rechts | Position und Anzahl |
| Der **Zustand** des Tabs | Als Sitzung speichern… | ad hoc **und** verbunden |
| Das **Protokoll** | Terminal öffnen | `capabilities.supportsShell` |

**Warum keine Beiträge.** `FileActionContribution` hat heute genau einen
Nutzer — S3s „Freigabe-Link". Sein Verhalten hängt an einem
`if action.id == "s3.presignedURL"` an der Aufrufstelle; der Kommentar dort
sagt, ein zweiter Beitrag brauche „nur ein weiteres `if`". Für das Tab-Menü
hieße das: ein Mechanismus mit null Nutzern plus eine
Zeichenketten-Verzweigung, um eine einzige Aktion zu zeigen, deren Bedingung
bereits als Fähigkeitsflag vorliegt.

Die Trennlinie aus B3 selbst — *„nicht welches Menü, sondern wovon der
Eintrag abhängt"* — führt hier zur Fähigkeitsabfrage. Ein Beitrag wird richtig,
sobald ein Backend eine Aktion hat, die **kein anderes kennt und die kein Flag
beschreibt**. Dann steht das Muster bereit und wird kopiert.

## 2. Das Menü als prüfbarer Wert

Nach dem Vorbild von `BrowserContextMenu`: eine Funktion in Core, die aus
Fakten eine Liste macht. Die Ansicht zeichnet nur, was herauskommt, und trifft
keine eigene Entscheidung.

Fakten, die hineingehen: Position des Tabs, Anzahl der Tabs, `supportsShell`,
ob die Verbindung ad hoc ist, ob sie steht.

Sichtbarkeitsregeln, jede einzeln prüfbar:

- **Nach links** fehlt beim ersten Tab, **Nach rechts** beim letzten. Kein
  ausgegrauter Eintrag, kein Fehler — der Eintrag erscheint dort nicht.
- **Andere schließen** fehlt, wenn es keine anderen gibt.
- **Terminal öffnen** erscheint bei SSH, fehlt bei S3 und WebDAV.
- **Als Sitzung speichern…** nur bei ad hoc **und** verbunden. Bei einer
  gespeicherten Sitzung ergibt der Eintrag keinen Sinn, bei einer
  gescheiterten Verbindung auch nicht.

**Ausdrücklich nicht dabei:** *Umbenennen* (ein eigener Tab-Titel wäre neuer
Zustand, der irgendwo leben müsste) und *Rechts schließen* (weniger Einträge
sind hier besser). Beides Maintainer-Entscheidung vom 2026-08-27.

## 3. Umordnen

**Eine Funktion in `TabsViewModel`**, dort wo `addTab`, `activate` und
`closeTab` schon leben — in Core, ohne Ansicht prüfbar. Beide Bedienwege rufen
sie: das Menü mit ±1, das Ziehen mit der Zielposition.

Drei Invarianten:

1. **Der aktive Tab bleibt aktiv.** Seine Position ändert sich, seine
   Identität nicht — auch wenn ein anderer Tab an ihm vorbeigeschoben wird.
   `activeTab` hängt an einer ID, das trägt.
2. **Keine Verbindung wird angefasst.** Umordnen ist reine Anzeigereihenfolge;
   Sitzung, Warteschlange und Terminal bleiben unberührt.
3. **Die Ränder tun nichts.** Eine Bewegung über den Rand hinaus ist kein
   Fehler und keine Ausnahme, sondern lässt die Reihenfolge, wie sie war.

**Nicht dabei:** einen Tab aus der Leiste heraus in ein neues Fenster ziehen.
Mehrfenster ist laut Architektur-Invarianten v2, und Verbindungszustände
hängen am Fensterbereich. Ein Ziehen ins Leere lässt den Tab, wo er war.

Weil Tabs keinen Neustart überleben, ist die Reihenfolge reiner
Sitzungszustand: kein Speicher, keine Migration, keine `SettingsStore`-Frage.

## 4. Schließen

**Ein Weg, nicht zwei.** „Andere schließen" ruft `teardown(_ tab:reason:)` pro
Tab auf. Einen zweiten Abbauweg zu bauen würde die Reihenfolge-Invariante der
Architektur unterlaufen (Warteschlange → Terminal → Verbindung).

**„Andere" heißt: alle außer dem angeklickten Tab** — nicht alle außer dem
aktiven. Das Menü hängt an einer bestimmten Zeile, und der Nutzer meint die,
auf die er geklickt hat. Ist der angeklickte Tab nicht der aktive, wird er
durch das Schließen zum aktiven, weil sonst kein Tab mehr da ist, der es sein
könnte.

**Eine Sammelwarnung, nicht N.** `TabCloseWarning` prüft heute einen Tab; für
das Sammelschließen kommt eine Fassung dazu, die über mehrere Tabs
zusammenfasst und benennt, wie viele der betroffenen gerade übertragen.
Einmal fragen, einmal entscheiden.

**Ablehnen bricht alles ab**, nicht nur die übertragenden Tabs. Eine Frage,
eine Antwort: wer „Abbrechen" wählt, will nicht, dass die Hälfte trotzdem
zugeht. Die ruhigen Tabs teilweise zu schließen wäre ein drittes Verhalten,
das niemand angefordert hat.

## 5. Als Sitzung speichern

Der Eintrag mit dem echten Neuwert: heute gibt es keinen Weg, eine laufende
Ad-hoc-Verbindung nachträglich zu sichern.

**Er öffnet den bestehenden Speichern-Weg, vorbefüllt** mit den Werten der
laufenden Verbindung, statt einen zweiten Speicher-Pfad zu bauen. Der Nutzer
sieht Name und Felder vor dem Sichern und kann den Namen setzen; die Frage,
ob das Geheimnis mitgeht, beantwortet das Formular wie sonst auch.

Quelle der Werte ist `values` in `ConnectionViewModel` — die generische Karte,
im Quelltext ausdrücklich als einzige Wahrheitsquelle geführt, aus der auch
die Verbinden- und Speichern-Wege lesen. **Nicht** `lastConnectedConfig`: das
ist ein `SSHConnectionConfig?` und trägt S3 und WebDAV nicht.

## 6. Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: welche Einträge erscheinen, was das
Umordnen mit der Reihenfolge und dem aktiven Tab macht, was die Sammelwarnung
sagt, und dass die Ansicht an die richtigen Funktionen verdrahtet ist.

**Nicht prüfbar** ist, dass SwiftUI das Ziehen auslöst und den Tab an der
erwarteten Stelle einfügt — es gibt hier keine Rendering-Umgebung. Das
entscheidet ein Blick in der laufenden App, wie zuletzt bei der
Eingabetaste auf der Seitenleistenzeile. Das gehört beim Abschluss ausdrücklich
als Maintainer-Prüfung benannt, nicht stillschweigend als „grün" verbucht.

---

## Was ausdrücklich nicht dazugehört

- Kein Wiederherstellen von Tabs über einen Neustart — eigener Vorgang.
- Kein Tab in ein neues Fenster ziehen — Mehrfenster ist v2.
- Keine Änderung an `fileActions` oder am Browser-Kontextmenü.
- Keine Antwort auf C2 („Sitzung ist schon offen") — eigener Backlog-Punkt.
