# Backlog: Werkzeuge zum Untersuchen einer Verbindung

**Angelegt:** 2026-08-25, aus Maintainer-Zuruf. Gesicherte Idee, **kein
Entwurf**.

## Der Wunsch

Werkzeuge pro Verbindung, um eine tote Leitung zu untersuchen: **Ping**,
**Trace**, Ähnliches. Und ausdrücklich **auch ohne gespeicherten Host** — mit
einem Feld für IP oder Domäne, sodass man etwas prüfen kann, das man noch
gar nicht angelegt hat.

## Warum das gerade jetzt naheliegt

Der Verbindungszustands-Zweig hat der App beigebracht, einen Abriss zu
**bemerken** und ihn zu **zeigen**. Was fehlt, ist die nächste Frage des
Nutzers: *woran liegt es?* Heute endet die Auskunft bei „keine Verbindung
möglich" plus technischer Meldung im Details-Dialog — was die App weiß, aber
nicht, was die Leitung tut.

Der Fehler-Zweig hat außerdem gemessen, dass eine Zeitüberschreitung und ein
hängender Namensdienst sich völlig verschieden verhalten und heute gleich
aussehen. Genau diese Unterscheidung würden solche Werkzeuge sichtbar machen.

## Vor einem Entwurf zu klären

**Was heißt „Ping" hier eigentlich?** Ein echtes ICMP-Echo braucht erhöhte
Rechte oder einen besonderen Socket-Typ; ein TCP-Verbindungsversuch auf den
Zielport braucht das nicht und beantwortet die praktisch interessantere
Frage — *nimmt dort jemand Verbindungen an?* Das ist die erste Entscheidung
und sie bestimmt den ganzen Umfang.

**Was heißt „Trace"?** Ein Wegverfolgen im Netz ist wieder ein Rechtethema.
Ein Protokoll dessen, was **macSCPs eigener Verbindungsaufbau** tut — Name
aufgelöst, TCP steht, Handschlag, Authentifizierung, Kanal offen, mit Zeiten
— wäre vermutlich nützlicher und ist vollständig in eigener Hand. Es
beantwortet „woran hängt es?" genauer als ein Traceroute, weil es die
Schichten zeigt, die dieses Programm tatsächlich durchläuft.

**Wo lebt das?** Ein eigenes Fenster, ein Bereich im Tab, oder ein Weg vom
Details-Dialog der Fehlerfläche aus. Der letzte hätte den Vorzug, dass man
dort landet, wo die Frage entsteht.

**Und pro Protokoll verschieden?** Für SSH ist der Handschlag interessant,
für S3 und WebDAV eher die HTTP-Antwort. Falls die Werkzeuge sich
unterscheiden, gilt dieselbe Regel wie beim Tab-Menü: **Beiträge über den
`BackendDescriptor`, kein `switch` über die Art.**

## Zwei Auflagen, die von Anfang an gelten

**Kein Geheimnis in der Ausgabe.** Ein Verbindungsprotokoll ist genau die
Sorte Fläche, auf der ein Passwort landet, wenn niemand hinsieht — dieser
Zweig hat drei solche Lecks geschlossen, zwei davon in Texten, die als
harmlose Diagnose galten. Was das Werkzeug ausgibt, ist von Anfang an so zu
bauen, dass ein Geheimnis dort keinen Platz hat, statt es hinterher
herauszufiltern.

**Und es bleibt ein Werkzeug.** Ein Feld für eine beliebige Adresse ist ein
Weg, Verbindungen zu beliebigen Hosts aufzubauen. Was es tun darf, gehört
eng gefasst: nachsehen, ob dort jemand antwortet — nicht sich anmelden,
nichts speichern, nichts anheften. Insbesondere darf ein Versuch aus diesem
Feld **keine Vertrauensentscheidung schreiben**; genau diese Verwechslung
war der schwerste Fund dieses Zweigs.
