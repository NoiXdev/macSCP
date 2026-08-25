# Backlog: Tests, die an echte Ablagen kommen

**Angelegt:** 2026-08-22, nach einem Vorfall während der Umsetzung des
Verbindungszustands. Kein Entwurf — ein Befund über das Projekt, nicht über
einen Zweig.

## Was passiert ist

Ein Umsetzer wollte beweisen, dass sein neuer Sicherungs-Test eine
Regression fängt, und entfernte dafür testweise das Tor vor der
Sitzungsübergabe. Sein Test baut eine echte `ContentView`. Der kurzzeitig
ungesicherte Code lief daraufhin durch und schrieb **in die echten Ablagen
des Entwicklers**:

- einen Eintrag in `~/Library/Application Support/macSCP/sessions-v2.json`
- ein Passwort in den Login-Keychain unter `dev.noix.macSCP`

Der geschriebene Wert war eine Testzeichenkette, kein echtes Geheimnis. Der
Umsetzer hat die Änderung sofort zurückgenommen, gestoppt und gemeldet; der
Schutzmechanismus hat ihm das Aufräumen im Keychain verweigert, was richtig
ist.

**Korrektur, gemessen 2026-08-22:** eine frühere Fassung dieses Absatzes
behauptete, beide Einträge seien entfernt. Nachgesehen: der Keychain-Eintrag
ist weg, der Eintrag in `sessions-v2.json` stand noch da. Die Behauptung war
eine Annahme, keine Messung.

Das ist nicht nur Unordnung. `SessionListViewModel.save` sucht per **Namen** —
ein Lauf mit gebrochener Naht schreibt denselben Eintrag also erneut und
erzeugt **byte-identisches JSON**. Der Schnappschuss-Test, der die Isolation
beweisen soll, besteht damit ausgerechnet in dem Zustand leer, den der
Vorfall hinterlassen hat.

## Der eigentliche Befund

**`ContentView` verdrahtet Keychain und Sitzungs-Store fest.** Es gibt keine
Test-Umleitung. Damit kann *jeder* Test, der eine `ContentView` baut, in die
echten Ablagen schreiben.

Betroffen sind heute zwei Dateien:

- `Tests/macSCPAppKitTests/ConnectAttemptHandoffTests.swift`
- `Tests/macSCPAppKitTests/LivenessGiveUpOrderingTests.swift`

Bei grünem Lauf schreibt keiner von beiden. Das ist aber kein Schutz,
sondern ein Zufall der Wegführung: **die nächste echte Regression an dieser
Aufrufstelle schreibt in einen echten Keychain** — auf dem Rechner des
Entwicklers und in der CI.

Ein Test, der beweisen soll, dass eine Absicherung wirkt, muss ihr Versagen
durchspielen können. Solange die Ablagen echt sind, heißt „Versagen
durchspielen" genau das.

## Was zu tun ist

**Eine Test-Naht für die echten Ablagen**, sodass ein Test sie auf ein
temporäres Verzeichnis und einen Speicher-nur-Geheimnisspeicher zeigen
lassen kann. Das behebt die Klasse statt der zwei Fälle und ist die
Voraussetzung dafür, dass ein Test auf `ContentView`-Ebene überhaupt sicher
existieren darf.

**Und die Isolation muss vorgeführt werden, nicht behauptet:** Ablage auf
ein temporäres Verzeichnis zeigen lassen, Suite laufen, und zeigen, dass die
echte Datei unberührt ist. Eine Behauptung über Isolation ohne Nachweis ist
dieselbe Sorte Zusicherung, die dieser Zweig wiederholt widerlegt hat.

## Regel, die ab sofort gilt

Kein Mutationsversuch, der an echte Zugangsdaten-, Sitzungs- oder
Konfigurationsablagen reichen kann. Verlangt ein Beweis das, ist zuerst der
Testaufbau zu ändern.

---

## Nachtrag 2026-08-25: `SessionListViewModel` hat dieselbe Naht-Lücke, und sie ist neu folgenreich

Aus der Abschlussdurchsicht des Plans *gescheiterter Aufbau*, hier nur
**festgehalten**, nicht behoben.

`SessionListViewModel.init` hat Vorgabewerte, die auf die realen
Verzeichnisse zeigen, und `init` ruft `reload()`. Gezählt in dem Durchgang,
der diesen Absatz schreibt, über alle Konstruktionsstellen unter `Tests/`:

- **16** Stellen lassen `loginSetStore:` weg und lesen damit die echte
  `~/Library/Application Support/macSCP/logins.json`
  (`PaneVisibilityPersistenceTests` 2, `SessionExportTagsTests` 3,
  `SessionListViewModelTests` 9, `SessionSecretPolicyTests` 2).
- **51** Stellen lassen `auditStore:` weg. **9** davon rufen danach
  `vm.delete(...)`, alle in `SessionListViewModelTests`, was ein
  `removeItem` gegen das **echte** Audit-Verzeichnis auslöst — heute
  folgenlos, weil die Sitzungs-IDs frisch sind und die Datei nie existiert.

Altlast, aber `c1db9a6` hat sie erstmals folgenreich gemacht: dort wird
`loginSets = (try? loginSetStore.all()) ?? []` durch ein `do/catch` ersetzt,
das den Fehler an `errorMessage` **anhängt**. Damit hängt der beobachtbare
Zustand dieser 16 Tests am Inhalt einer echten Nutzerdatei. Heute geht es
gut — von den 16 lesen zwei danach `errorMessage`, und beide Zusicherungen
sind `hasPrefix`-förmig und überleben ein Anhängen. Kein Schreibzugriff auf
dem Leseweg.

**Billige Behebung, dieselbe Klasse wie oben:** die Vorgabewerte aus dem
`init` entfernen und die Aufrufstellen explizit machen. Dann ist „liest die
echte Datei" nichts, was ein Test aus Versehen tun kann.

## Nachtrag 2026-08-25: `catalogDirectories` ist eine hartkodierte Liste

`LocalizationParityTests.catalogDirectories` und `GermanAddressFormTests
.catalogs` zählen die Katalogorte fest auf. Die *Locales* innerhalb eines
Ortes werden von der Platte abgeleitet, die **Orte selbst nicht**. Ein
drittes lokalisiertes Ziel bliebe stillschweigend ungeprüft.

Das ist genau die Klasse, für die `ReconnectWiringGuardTests` eigens
`everySourceDirectoryIsScannedOrExplicitlyExcluded` besitzt: eine Prüfung,
die weniger prüft, als sie glaubt, ist schlechter als keine, weil sie Erfolg
meldet. Heute gibt es genau zwei `Resources/`-Verzeichnisse, also folgenlos
— und dieselbe Ableitung von der Platte wäre hier so billig wie dort.
