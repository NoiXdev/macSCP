# M17 — SSH-Key-Manager (Design/Spec)

**Datum:** 2026-08-02
**Status:** freigegeben (Brainstorm), bereit für writing-plans
**Branch:** `develop`
**Vorgänger:** M3b (`SSHPrivateKeyLoader`, ed25519-Laden), M10a/M3c (Known-Hosts-Store-Muster), S3-Programm M12–M16 abgeschlossen.

## Ziel

Ein eigener Settings-Tab „SSH-Schlüssel": ed25519/rsa/ecdsa-Schlüssel erzeugen
(mit Name, Kommentar, optionaler Passphrase), auflisten, löschen, Public-Key
kopieren/exportieren. Erzeugte **ed25519**-Keys sind direkt als Auth im
Verbindungsformular und in Login-Sets wählbar; ihre Passphrase wird zentral im
Keychain gehalten und beim Verbinden automatisch aufgelöst.

## Ausgangslage (verifiziert)

- **Laden heute:** `SSHPrivateKeyLoader` (`Sources/macSCPCore/SSH/SSHPrivateKeyLoader.swift:15`) lädt **nur ed25519** (OpenSSH-Format, optional passphrase-verschlüsselt) via Citadels `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`. RSA/ECDSA-Laden existiert nicht.
- **Referenz:** überall ein `keyPath: String?` (Dateipfad) — `StoredSession.keyPath`, `JumpSpec.keyPath`, `LoginSet.keyPath`, `ConnectionViewModel.keyPath`, `ResolvedLogin.keyPath`. Keine Key-Registry. Formular + Login-Set-Editor: `TextField` + `fileImporter`-„…"-Knopf, schreibt den rohen Pfad zurück.
- **swift-crypto** (`Package.swift:12`, `from: "3.0.0"`) ist da; `Curve25519.Signing` wird schon genutzt. **Key-Erzeugung + OpenSSH-Serialisierung existieren nicht.**
- **`ssh-keygen`-Vorlage:** die Tests erzeugen Keys via `/usr/bin/ssh-keygen` `Process()` (`Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift:14`, Flags `-t ed25519 -f <path> -N <pass> -q -C <comment>`).
- **`SecretStore`:** UUID-adressiert (`savePassword`/`password`/`deletePassword` für eine `UUID`), `kSecAttrService="dev.noix.macSCP"`. Login-Set-Secrets liegen unter `set.id` — dasselbe Muster ist für einen Key nutzbar.
- **Settings:** `SettingsView` (`Sources/MacSCPApp/SettingsView.swift:12`) ist ein `TabView` mit 5 Tabs; ein sechster `.tabItem` fügt sich gleich ein. Fenster fix 460×460.
- **`~/.ssh`:** wird **nirgends geschrieben** (strikt nur-lesen; Known-Hosts liegen in einem App-Ordner). Ein Schreibpfad nach `~/.ssh` wäre der erste im Projekt.

## Entscheidungen (Maintainer, 2026-08-02)

1. **Speicherort:** App-eigener Ordner, private Dateien 0600 (Verzeichnis 0700); **kein** `~/.ssh`-Schreiben.
2. **Erzeugung:** `/usr/bin/ssh-keygen` shellen (Argument-Array, keine Shell-Injection).
3. **Referenz:** pfadbasiert — `keyPath` zeigt auf die App-Key-Datei, **kein** Modell-/Export-Umbau. Der Picker füllt `keyPath`.
4. **Passphrase:** zentral im Keychain unter `key.id`; beim Connect automatisch aufgelöst (Pfad-Lookup), sonst Fallback auf den bisherigen Formular-/Session-Flow.
5. **Typ-Scope:** Generieren-Dialog bietet ed25519/rsa/ecdsa (+ RSA-Bitlänge). **Nur ed25519 ist als macSCP-Login verbindbar** (Lader-Grenze); RSA/ECDSA sind erzeugbar + pub-exportierbar, im Login-Picker **nicht** angeboten und in der Liste als „nicht verbindbar" markiert.

## Architektur

### Core

**`ManagedKey`** (Modell, Core):
```swift
public struct ManagedKey: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var comment: String
    public var type: KeyType          // .ed25519 / .rsa(bits:Int) / .ecdsa
    public var fingerprint: String    // "SHA256:…"
    public var publicKeyOpenSSH: String  // "ssh-ed25519 AAAA… comment"
    public var createdAt: Date
    public var hasPassphrase: Bool
    public var fileName: String        // relative to the key directory
}
```
`KeyType`: `enum` mit `.ed25519`, `.rsa(bits: Int)`, `.ecdsa`; `.isConnectable` → nur `.ed25519 == true`.

**`SSHKeyGenerator`** (Core, testbar):
```swift
func generate(type: KeyType, comment: String, passphrase: String?, into dir: URL)
    throws -> GeneratedKey   // { privateKeyURL: URL, publicKeyOpenSSH: String, fingerprint: String }
```
- Ruft `ssh-keygen` mit Argument-Array: `-t <ed25519|rsa|ecdsa>`, `-b <bits>` (nur RSA), `-f <appfile>`, `-N <passphrase | "">`, `-C <comment>`, `-q`. Nichtnull-Exit → typisierter Fehler.
- Liest die erzeugte `.pub` (OpenSSH-Zeile), stellt `chmod 0600` auf der Privatdatei sicher, leitet den Fingerprint ab (bestehender `HostKeyFingerprint`-Weg oder `ssh-keygen -lf`).
- **Doku-Hinweis:** die Passphrase steht kurzzeitig in `argv` (nur same-user via `ps` sichtbar) — akzeptierter Minor; `ssh-keygen` bietet für die Generierung keinen stdin-Passphrase-Weg.

**`ManagedKeyStore`** (Core): atomare JSON-Schreibweise wie `KnownHostsStore` (eigener App-Support-Ordner; der Key-Datei-Ordner ist ein Unterordner davon, 0700). **Secret-frei** (keine Passphrase, keine Privat-Bytes im JSON). API:
- `all() -> [ManagedKey]`
- `add(_ key: ManagedKey)`
- `remove(id: UUID)` — löscht Metadaten **und** die Privat-/Pub-Datei **und** (über den SecretStore) den Keychain-Slot unter `id`
- `key(forPath: String) -> ManagedKey?` — Pfad-Lookup (App-Key-Datei → verwalteter Key) für die Passphrase-Auflösung

**Passphrase-Auflösung beim Connect:** eine Ergänzung im bestehenden Auflöse-Weg (dort, wo `keyPath` + Passphrase für den `SSHPrivateKeyLoader` bestimmt werden): bevor die Passphrase aus Formular/Session genommen wird, `ManagedKeyStore.key(forPath: resolvedKeyPath)` prüfen; existiert ein verwalteter Key mit `hasPassphrase`, die Passphrase aus `SecretStore.password(for: key.id)` verwenden. Sonst unverändert der bisherige Weg. **`SSHPrivateKeyLoader` bleibt unangetastet.**

### App

**Settings-Tab „SSH-Schlüssel"** (sechster `.tabItem`, `systemImage: "key"`):
- **Liste:** pro Key Name, Typ-Badge (`ED25519`/`RSA`/`ECDSA`), Fingerprint-Kurzform, Kommentar, Erstelldatum, Schloss-Symbol bei Passphrase. RSA/ECDSA mit dezentem Hinweis „nicht als macSCP-Login verbindbar".
- **Erzeugen…** (Sheet): Name, Kommentar, Typ-Picker (ed25519/rsa/ecdsa), bei RSA Bitlängen-Picker (2048/3072/4096, Default 3072), optionale Passphrase (SecureField + Bestätigung). „Erzeugen" → `SSHKeyGenerator` → Datei anlegen, Passphrase (falls gesetzt) im Keychain unter neuer Key-ID, Metadaten in den Store.
- **Public-Key kopieren** (NSPasteboard), **Public-Key exportieren…** (`fileExporter` → `.pub`).
- **Löschen** (Bestätigung) → Store `remove(id:)` (Datei + `.pub` + Keychain). Warnhinweis mit Best-effort-Zählung, wenn Sessions/Login-Sets diesen `keyPath` referenzieren (wie die `usageCount`-Anzeige bei Login-Sets).
- Aktionen als Buttons **und** pro-Zeile-Kontextmenü.
- Fensterhöhe ggf. anpassen (heute fix 460×460); notfalls scrollbare Liste in fixer Höhe.

**Formular + Login-Set-Editor:** der bestehende `keyPath`-Block bekommt additiv ein Menü „Verwalteter Schlüssel", das die **ed25519**-Keys des Stores listet (Name + Fingerprint-Kurzform) und bei Auswahl `keyPath` mit dem App-Datei-Pfad füllt. Freitext + „…"-Durchsuchen bleiben daneben. Ein „Schlüssel verwalten…"-Knopf öffnet den Settings-Tab (analog „Logins verwalten…").

## Tests

**Core (Swift Testing):**
- `ManagedKeyStore`: CRUD, atomares secret-freies JSON, `key(forPath:)`, `remove` löscht Datei + Keychain-Slot (`MACSCP_KEYCHAIN=1`).
- `SSHKeyGenerator` (echtes `/usr/bin/ssh-keygen`): ed25519 → Datei existiert + 0600, `.pub` OpenSSH-Format, Fingerprint parsebar; **Roundtrip:** erzeugter ed25519-Key lädt via `SSHPrivateKeyLoader`; passphrase-geschützter Key braucht die Passphrase; RSA/ECDSA erzeugbar.
- Passphrase-Auflösung: verwalteter Key-Pfad mit Keychain-Passphrase liefert diese; Fremd-Pfad fällt auf den Formular-Flow zurück.

**App:** build-verifiziert + Runtime-Idle-CPU-Smoke (neuer Tab/Liste).

## Sicherheit / Invarianten

- Key-Bytes nie geloggt; Passphrase ausschließlich Keychain unter `key.id`; JSON-Store secret-frei.
- Privatdateien 0600, Verzeichnis 0700, im App-Support-Ordner — **kein** `~/.ssh`-Schreiben.
- `ssh-keygen` per Argument-Array (keine Shell-Injection).
- `remove` räumt Privat-/Pub-Datei + Keychain-Slot auf.
- Keine neue externe Dependency (swift-crypto ist bereits vorhanden; Erzeugung via System-`ssh-keygen`).

## L10n

Alle neuen nutzer-sichtbaren Strings (Tab-Label, Listen-/Aktions-Labels,
Generieren-Dialog, Typ-/Bitlängen-Optionen, „nicht verbindbar"-Hinweis,
Lösch-/Nutzungs-Warnung, Formular-Menü) in EN/DE/FR/PL, typografische Zeichen,
FR/PL KI-generiert (Native-Review vor Release).

## Nicht in M17 (→ v2)

- Key-**Import** vorhandener Schlüssel.
- `authorized_keys`-Ausrollen auf den Server.
- RSA/ECDSA als **verbindbarer** macSCP-Login (Lader-Grenze — bräuchte RSA/ECDSA-Laden in `SSHPrivateKeyLoader`).
- `managedKeyID`-Modellreferenz (der Pfad-Lookup genügt für v1).
- Umschaltbares Secret-Backend (1Password-Vault) — eigener Future-Milestone mit Machbarkeitsrunde.

## Betroffene Dateien

- `Sources/macSCPCore/SSH/ManagedKey.swift` (+ `KeyType`) — **create**.
- `Sources/macSCPCore/SSH/SSHKeyGenerator.swift` — **create**.
- `Sources/macSCPCore/SSH/ManagedKeyStore.swift` — **create**.
- Connect-Auflöse-Weg (Core, dort wo `keyPath`+Passphrase für `SSHPrivateKeyLoader` bestimmt werden — `ConnectionViewModel`/`LoginResolver`-Umfeld) — **modify** (Passphrase-Lookup).
- `Sources/MacSCPApp/SettingsView.swift` + neuer `SSHKeysSettingsTab` — **modify/create**.
- `Sources/MacSCPApp/ConnectionFormView.swift`, `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (Key-Picker-Menü).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/…` — `ManagedKeyStoreTests`, `SSHKeyGeneratorTests`, Passphrase-Auflösungs-Test — **create**.
