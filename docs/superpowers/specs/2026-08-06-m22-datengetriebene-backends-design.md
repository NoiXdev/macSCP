# M22 — Datengetriebene Backend-Registrierung

**Stand:** 2026-08-06
**Vorgänger:** M12 (Fähigkeits-Framework), M21 (WebDAV als drittes Backend)

## Zweck

M21 hat WebDAV als drittes Backend gebaut und dabei die Grenze des M12-Frameworks
vermessen. Das Ergebnis, in der Ledger-Auswertung von M21/Task 8: die generischen
Schichten (Browser, Transfer-Engine, Warteschlange) blieben unangetastet — aber
der Compiler meldete **sechs** nicht mehr vollständige `switch`-Anweisungen, und
**keine** ließ sich aus dem Descriptor bedienen.

Diese sechs Stellen sind keine Protokollfähigkeiten. Sie sind Formularfelder,
CLI-Konventionen, Fehlertexte und Login-Sets — vier Dinge, die das Framework nie
beschrieben hat. M22 beschreibt sie.

**Der ausdrückliche Wunsch des Maintainers (2026-08-04):** Login-Sets sollen auch
WebDAV können, und die `kind`-Abfragen sollen weg — abgeleitet aus dem Interface
statt von Hand verzweigt. Beides greift ineinander: Login-Sets scheitern heute
genau daran, dass `LoginSet` protokollspezifische Felder trägt.

## Bindende Entscheidungen

Aus dem Brainstorming, in der Reihenfolge der Klärung:

1. **SSH ist dabei.** Nicht nur S3 und WebDAV — der Dispatcher soll am Ende
   wirklich verschwinden, nicht auf einen Zweig schrumpfen.
2. **Das Schema ist vollständig deklarativ.** Nichts bleibt maßgeschneidert;
   auch SSHs Auth-Arten, Schlüsselauswahl und Jump-Block werden beschrieben.
3. **Feld-IDs sind typisiert, pro Backend.** Ein Enum je Backend, aus dem beide
   Schemata, die Fabrik und der Adapter schöpfen.
4. **Zwei getrennte Schemata** — eines fürs Verbindungsformular, eines für den
   Login-Set-Editor.
5. **Das Persistenzformat ändert sich nicht.** Auf der Platte bleibt alles
   typisiert und `Codable`; generisch wird nur der Weg dazwischen.

Zu (4) gehört eine Einordnung: weil (3) gilt, sind das **nicht zwei Listen loser
Zeichenketten**, sondern zwei Listen aus demselben Enum. Ein Feld, das es nicht
gibt, lässt sich in keines der beiden schreiben. Bleibt die Gefahr, dass ein Feld
in *keinem* steht — dagegen der Vollständigkeitstest (siehe Tests).

## Das Vokabular

### Typisierte Feld-IDs

```swift
public protocol BackendFieldID: RawRepresentable, CaseIterable, Hashable, Sendable
where RawValue == String {}

enum WebDAVField: String, CaseIterable, BackendFieldID {
    case baseURL, username, password, useNextcloudPath
}
```

Eine Quelle für beide Schemata, die Fabrik und den Adapter. Es gibt keine losen
Zeichenketten mehr, also auch keine Tippfehler.

### Feldarten

```swift
enum Kind {
    case text, number, secret, toggle
    case picker(OptionSource)
    case group([LeafField])        // LeafField.Kind kennt kein .group
}

enum OptionSource {
    case managedKeys                    // aus dem ManagedKeyStore (App-Schicht)
    case loginSets(kind: ConnectionKind)
    case fixed([Option])                // z. B. Auth-Art
}

struct Condition { let field: String; let equals: String }
```

Zwei Schnitte sind bewusst so gewählt:

**Die Verschachtelung ist eine Typeigenschaft, keine Laufzeitprüfung.** Eine
`.group` enthält `LeafField`, und `LeafField.Kind` hat keinen `.group`-Fall.
„Genau eine Ebene tief" garantiert damit der Compiler, nicht ein Test, den jemand
vergessen kann. Der Jump-Block ist die eine Gruppe, die gebraucht wird.

**Die Bedingung kann genau eine Sache:** „Feld X hat Wert Y". Kein Und, kein
Oder, keine Negation. Das deckt den einzigen realen Fall ab (SSH: Schlüsselpfad
nur bei `authKind == .privateKey`) und kann nicht zur Ausdruckssprache
auswachsen. Braucht ein Backend jemals mehr, ist das ein Anlass zum Nachdenken,
nicht zum Erweitern.

### Werte

```swift
values[WebDAVField.baseURL]     // kompiliert
values["basURL"]                // existiert nicht
```

`FieldValues` ist eine dünne Hülle um ein Wörterbuch, deren Zugriff über das
Feld-Enum läuft.

## Der Descriptor

```swift
BackendDescriptor(
    kind: .webdav,
    capabilities: …,                    // unverändert aus M12
    connectionSchema: [ … ],
    credentialSchema: [ … ],
    makeConfig: { values, secret in … },
    displaySummary: { values in … },
    connect: { config, deciders in … },
    secretEnvironmentVariable: "MACSCP_PASSWORD",
    requiresSecret: true)
```

`secretEnvironmentVariable` und `requiresSecret` sind die zwei Achsen, die
M21/Task 8 als fehlend zutage gefördert hat — mit ihnen verschwinden die
CLI-Fundstellen.

`makeConfig` ist eine Closure, in der das Backend über sein **eigenes** Enum
schaltet. Die Vollständigkeit prüft damit der Compiler an der Stelle, wo sie
zählt: ein neues Feld ohne Behandlung ist ein Build-Fehler.

### `displaySummary`

Seitenleiste, Tab-Titel und Prüfprotokoll bauen heute `benutzer@host` aus
Feldern, die S3 und WebDAV nicht füllen — deshalb steht im Prüfprotokoll
`host: "unused"` und ein WebDAV-Tab heißt `tim@`. Der M21-Abschlussreview hat das
als Drift benannt. Eine Zusammenfassung je Backend behebt es nebenbei.

## Datenfluss

```
connectionSchema  →  Formular rendert  →  FieldValues
                                              ↓
                                        makeConfig
                                              ↓
                                       ConnectionConfig  →  connect
```

Das Formular kennt kein Protokoll mehr. Es rendert Felder, löst Optionsquellen
auf, sammelt Werte. `ConnectionViewModel` verliert seine getippten `s3*`- und
`webdav*`-Eigenschaften und behält ein `values: FieldValues`.

**Die Optionsquellen sind die einzige Stelle, an der die App etwas beisteuert.**
`OptionSource.managedKeys` kann der Core nicht auflösen — der Schlüsselspeicher
lebt in der App. Das Formular bekommt einen Auflöser hereingereicht, der aus
einer Quelle eine Optionsliste macht: drei Fälle, ein `switch`, an genau einer
Stelle.

## Persistenz

Die Platte ändert sich nicht. Pro Backend gibt es einen kleinen Adapter in beide
Richtungen — `FieldValues` ⇄ `StoredWebDAVConfig`. Das ist Codable-Arbeit, die
der Compiler prüft; die Dateien der Nutzer bleiben unberührt. Kein
Migrationslauf, kein zweiter Lesepfad.

`LoginSet` bekommt **additiv** die WebDAV-Felder, genau wie es in M12 die
S3-Felder bekommen hat: neue optionale Eigenschaften, alte Dateien lesen sich
unverändert als `nil`.

## Login-Sets und der Auflöser

```swift
// heute: zwei Funktionen, bei WebDAV würden es drei
LoginResolver.resolve(session:sets:secrets:)    -> ResolvedLogin?
LoginResolver.resolveS3(session:sets:secrets:)  -> ResolvedS3Login?

// künftig: eine
LoginResolver.resolve(session:sets:secrets:)    -> FieldValues?
```

Der Auflöser sucht das Set, lässt dessen Adapter die typisierten Felder in
`FieldValues` übersetzen, holt das Geheimnis aus der Keychain unter der Set-ID —
und liefert ein Wörterbuch, das die Fabrik genauso verarbeitet wie eines aus dem
Formular. `ResolvedLogin` und `ResolvedS3Login` fallen zusammen.

Der Login-Set-Editor rendert das `credentialSchema` mit demselben generischen
Code wie das Verbindungsformular. Der handaufgezählte Typ-Picker, der heute nur
SSH und S3 anbietet, wird ein `ForEach` über die Backends — WebDAV erscheint
darin, ohne dass irgendwo „WebDAV" steht.

**Damit sind Login-Sets für WebDAV keine Arbeit, sondern eine Folge.**

### Offener Punkt, ausdrücklich benannt

`authKind` ist bei SSH kein gewöhnliches Feld: es entscheidet, welche anderen
Felder sichtbar sind, und ob überhaupt ein Geheimnis nötig ist. Im Schema wird es
ein `.picker(.fixed([...]))`, und die Sichtbarkeitsbedingungen der übrigen Felder
zeigen darauf. Genau dafür existiert die Bedingung — aber SSHs Login-Sets sind
damit die einzigen, deren Editor Felder ein- und ausblendet. Erweist sich das im
Bau als unhandlich, ist das die erste Stelle, an der die Umsetzung anhält und
nachfragt.

## Was verschwindet

| Fundstelle (M21/Task 8) | Wird zu |
|---|---|
| `ConnectionViewModel.connect()` | `descriptor.makeConfig(values, secret)` |
| `ConnectionViewModel.validateForEditSave()` | derselbe Aufruf, anderer Zweck |
| `CLISecretSources` (Umgebungsvariable) | `descriptor.secretEnvironmentVariable` |
| `CLISecretSources.needsSecret` | `descriptor.requiresSecret` |
| `LoginSetsSheet.isSaveDisabled` | Pflichtfeldprüfung über `credentialSchema` |
| `LoginSetsSheet` Speichern-Knopf | dito; der `preconditionFailure` entfällt |

Dazu wird `CLIErrorMapping`s `.missingWebDAVConfiguration` zu
`.missingBackendConfiguration(kind:)` und damit protokollneutral.

`BackendConnector` verschwindet ebenfalls, weil der Descriptor die
Verbindungs-Closure mitführt. Der letzte verbleibende `switch` über
`ConnectionKind` ist dann der in `BackendDescriptor.descriptor(for:)` selbst —
die Registrierungstabelle, kein Dispatcher.

## Tests

**Vollständigkeitstest je Backend.** Jedes Feld beider Schemata wird von
`makeConfig` gelesen und vom Adapter übersetzt; keines fällt zwischen die
Schemata. Das fängt den Fall, den auch ein erschöpfender `switch` nicht sieht: ein
Feld, das die Fabrik behandelt, das aber in keinem Schema steht und deshalb nie
ein Eingabefeld bekommt.

**Rundlauf je Backend.** Formularwerte → Konfiguration → gespeicherte Session →
Formularwerte. Am Ende steht dasselbe da wie am Anfang.

**Altbestands-Test mit echten Dateien.** Eine Session-JSON und eine
Login-Set-JSON im heutigen Format, als Baustein eingefroren, müssen nach dem
Umbau unverändert laden und dieselbe Konfiguration ergeben. Das ist der einzige
Test, der beweist, dass die gespeicherten Verbindungen der Nutzer den Meilenstein
überleben — und der einzige, der sich nicht durch Nachdenken ersetzen lässt.

**Die vorhandenen SSH- und S3-Tests sind das Sicherheitsnetz.** Sie dürfen nicht
angepasst werden, damit sie zu einer neuen Implementierung passen. Wird einer rot,
ist die Implementierung falsch, nicht der Test.

## Nicht in diesem Meilenstein

Änderungen am Persistenzformat; UX-Änderungen an SSHs Formular (etwa den
Jump-Block in ein eigenes Sheet zu verlegen); neue Protokolle; die aus M21
offenen Kleinbefunde, soweit sie nicht ohnehin auf dem Weg liegen.

## Erfolgskriterien

1. `grep -rn "kind == \." Sources/` findet außerhalb der Descriptor-Registrierung
   keine Protokollverzweigung mehr.
2. Ein Login-Set für WebDAV lässt sich anlegen, an eine Session binden und
   verbinden — ohne dass für WebDAV eigener UI-Code existiert.
3. Der Altbestands-Test lädt eine vor M22 geschriebene Session und ein vor M22
   geschriebenes Login-Set unverändert.
4. Alle vorhandenen SSH- und S3-Tests bleiben unverändert grün.
5. Ein viertes Backend bräuchte: ein Feld-Enum, zwei Schemata, eine Fabrik, einen
   Adapter, eine Verbindungs-Closure — und keine Änderung an einer generischen
   Schicht.
