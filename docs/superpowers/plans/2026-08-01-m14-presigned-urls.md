# M14 — Presigned Share-URLs (S3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate time-limited signed S3 share URLs (GET download / PUT upload) from the browser, wired through the M12 file-action contribution seam.

**Architecture:** Add SigV4 query-param (presigned) signing to the existing signer; expose it via a `PresignedURLProvider` optional-capability seam that `S3FileSystem` conforms to; feed the S3 backend's `FileActionContribution` into the generic context menu; and add an App sheet (method + expiry + clipboard) plus a settings default. The generic layer stays protocol/capability-driven — no `if kind ==`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), Foundation (`URLSession` only in the gated test), swift-crypto (via `SigV4Signer`), SwiftUI/AppKit, Swift Testing. No new dependency.

## Global Constraints

- Swift 6, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- Code + comments English only. UI strings via the four `.strings` catalogs EN/DE/FR/PL, typographic quotes, no ASCII `"` in non-English values; FR/PL AI-generated (native review before release).
- No new external dependency (Foundation + swift-crypto via `SigV4Signer`).
- Secret only in the signer, never in logs/JSON/URL. The generated presigned URL goes ONLY to the clipboard — never logged, persisted, or interpolated into an error message. (The access key ID unavoidably appears in the URL query; the secret never does.)
- Generic layer reads only capabilities/contributions — no `if kind ==` in browser/menu; presigned dispatched via `fs as? PresignedURLProvider`.
- Expiry clamped to `[1, 604800]` seconds (SigV4 max 7 days).
- TDD red→green; new logic ships with tests. **Every signing-touching change is verified against live MinIO** (M13 lesson — fake tests don't validate SigV4). Runtime idle-CPU smoke for the new sheet.
- No release. Cross-backend S3↔SSH = M15; open-with S3 CLI = later milestone.

## Existing interfaces (verified, do not re-derive)

- `SigV4Signer` (`Sources/macSCPCore/S3/SigV4Signer.swift`), a `public struct Sendable`: stored `accessKeyID`, `secretAccessKey`, `region`, `service`, `sessionToken`. `public func authorizationHeader(method:host:path:query:headers:payloadHash:date:)`. Private static `signingKey(secretAccessKey:dateStamp:region:service:)`, `hmac(key:data:)`, `hexHMAC(key:data:)`; internal static `hexSHA256(_:)`, `canonicalURI(path:)`, `canonicalQueryString(query:)`; private static `amzDateFormatter` (`yyyyMMdd'T'HHmmss'Z'`, UTC/POSIX) + `dateStampFormatter` (`yyyyMMdd`, UTC/POSIX). Scope string form: `"\(dateStamp)/\(region)/\(service)/aws4_request"`.
- `S3FileSystem` (`Sources/macSCPCore/S3/S3FileSystem.swift`): `config: S3ConnectionConfig`; static `keyRequestURL(config:key:queryPairs:)` (path-style `/{bucket}/{key}` + virtual-host `{bucket}.{host}/{key}`, sets `percentEncodedQuery = SigV4Signer.canonicalQueryString(query:)`), static `canonicalKeyPath(config:key:)` (raw `/{bucket}/{key}`, empty key → `/{bucket}`), `objectKey(forPath:)`.
- `S3ConnectionConfig`: `accessKeyID`, `secretAccessKey`, `region`, `endpoint`, `bucket`, `usePathStyle`, `sessionToken`.
- `RemoteShellProvider` (`Sources/macSCPCore/RemoteFS/RemoteShell.swift`) — the model for an OPTIONAL capability queried via `as?`.
- `BackendContributions.swift`: `FileActionContribution(id:titleKey:titleDefault:)` (already defined, M12).
- `BackendDescriptor.swift`: `descriptor(for: ConnectionKind) -> BackendDescriptor`; `sshDescriptor`/`s3Descriptor` each have `fileActions: [FileActionContribution]` (both currently `[]`). `ProtocolCapabilities.supportsPresignedURL` (s3 true / ssh false).
- `BrowserContextMenu` (`Sources/macSCPCore/Presentation/BrowserContextMenu.swift`): `enum BrowserMenuEntry` (cases `transferToOtherPane`, `transferToSession(CrossSessionTarget)`, `openInEditor`, `rename`, `infoAndPermissions`, `newFolder`, `copyPath`, `delete`); `static func entries(for selection: [RemoteFileItem], side: BrowserPaneSide, crossSessionTargets: [CrossSessionTarget] = []) -> [BrowserMenuEntry]`.
- `RemoteFileItem`: `name`, `path`, `kind` (`.file/.directory/.symlink/.other`), `isDirectory`.
- `SettingsStore` (`Sources/macSCPCore/Settings/SettingsStore.swift`): the JSON-persisted settings pattern (Codable properties with defaults). App renders them in `Sources/MacSCPApp/SettingsView.swift` (a `TabView` incl. a Transfers tab).
- `RemoteFileTableView` (`Sources/MacSCPApp/RemoteFileTableView.swift`): its `Coordinator` builds the `NSMenu` from `BrowserContextMenu.entries(...)` in `menuNeedsUpdate`; `makeItem(_:selection:)` maps each `BrowserMenuEntry` to an `NSMenuItem`.
- Gated integration (`Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift`): `.enabled(if: MACSCP_ITEST)` suite, connects to `http://127.0.0.1:19000`, path-style, region `us-east-1`, creds `macscp`/`macscpsecretkey`, bucket `macscp-seed`, with a `connect` helper + a raw-DELETE cleanup helper.

---

### Task 1: SigV4 presigned query-signing

**Files:**
- Modify: `Sources/macSCPCore/S3/SigV4Signer.swift`
- Test: `Tests/macSCPCoreTests/SigV4SignerTests.swift`

**Interfaces:**
- Produces: `public func presignedQuery(method: String, host: String, path: String, expiresInSeconds: Int, date: Date) -> [(name: String, value: String)]` — returns ALL X-Amz-* query params INCLUDING `X-Amz-Signature`, ready to attach to a URL.

- [ ] **Step 1: Failing test — the AWS query-parameter reference vector.** The documented AWS "Authenticating Requests: Using Query Parameters (SigV4)" GET-object example. In `SigV4SignerTests.swift`:

```swift
@Test func presignedQueryMatchesAWSVector() {
    // AWS docs "Example: GET Object (query parameters)". Secret is the docs'
    // query-params example secret (note the '/' — distinct from get-vanilla).
    let signer = SigV4Signer(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1", service: "s3")
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
    let params = signer.presignedQuery(
        method: "GET", host: "examplebucket.s3.amazonaws.com",
        path: "/test.txt", expiresInSeconds: 86400, date: date)
    let dict = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value) })
    #expect(dict["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
    #expect(dict["X-Amz-Credential"] == "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
    #expect(dict["X-Amz-Date"] == "20130524T000000Z")
    #expect(dict["X-Amz-Expires"] == "86400")
    #expect(dict["X-Amz-SignedHeaders"] == "host")
    #expect(dict["X-Amz-Signature"] == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
}
```

- [ ] **Step 2: Run red.** `swift test --filter SigV4Signer` → FAIL (no `presignedQuery`).

- [ ] **Step 3: Implement `presignedQuery`.** Mirror `authorizationHeader`'s canonicalization, but put the auth params in the QUERY and sign with `UNSIGNED-PAYLOAD` + `host` as the only signed header:

```swift
    /// SigV4 query-parameter ("presigned") signing. Returns every `X-Amz-*`
    /// query parameter INCLUDING the final `X-Amz-Signature`, ready to attach
    /// to the object URL. The only signed header is `host`; the payload hash
    /// is `UNSIGNED-PAYLOAD`. Pure — no I/O.
    public func presignedQuery(
        method: String, host: String, path: String,
        expiresInSeconds: Int, date: Date
    ) -> [(name: String, value: String)] {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        // Query params that must be part of the canonical (signed) query, in
        // ANY order — canonicalQueryString sorts + RFC-3986-encodes them.
        var query: [(name: String, value: String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expiresInSeconds)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if let sessionToken {
            query.append(("X-Amz-Security-Token", sessionToken))
        }

        let canonicalRequest = [
            method,
            Self.canonicalURI(path: path),
            Self.canonicalQueryString(query: query),
            "host:\(host)\n",       // canonical headers block (host only)
            "host",                  // signed headers
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            Self.hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp,
                                          region: region, service: service)
        let signature = Self.hexHMAC(key: signingKey, data: Data(stringToSign.utf8))
        query.append(("X-Amz-Signature", signature))
        return query
    }
```

- [ ] **Step 4: Run green.** `swift test --filter SigV4Signer` → PASS (all, incl. the existing header vector). If the signature mismatches the documented value, the canonical query ordering/encoding is wrong — the reference is authoritative; fix until it matches.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/S3/SigV4Signer.swift Tests/macSCPCoreTests/SigV4SignerTests.swift
git commit -m "feat: add SigV4 presigned query signing"
```

---

### Task 2: `PresignedURLProvider` seam + `S3FileSystem.presignedURL` (+ gated MinIO)

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/PresignedURLProvider.swift`
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`, `Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift`

**Interfaces:**
- Consumes: `SigV4Signer.presignedQuery` (Task 1), `S3FileSystem.keyRequestURL`/`canonicalKeyPath`.
- Produces: `enum PresignedMethod: String, Sendable { case get = "GET"; case put = "PUT" }`; `protocol PresignedURLProvider: Sendable { func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL }`. `S3FileSystem: PresignedURLProvider`. The `key` is a RAW S3 key (no leading slash), e.g. `Self.objectKey(forPath: path)`.

- [ ] **Step 1: Failing unit test — presigned GET/PUT URL shape + expiry clamp.** In `S3FileSystemTests.swift` (no fake transport needed — pure computation; construct an `S3FileSystem` via the existing test `connect(...)` helper, which uses `FakeS3Transport` for the connect probe but `presignedURL` never calls the transport):

```swift
@Test func presignedGetURLCarriesSigV4QueryAndClampsExpiry() async throws {
    let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
    let url = try (fs as! any PresignedURLProvider).presignedURL(
        method: .get, key: "dir/file.txt", expiresIn: 999_999_999) // clamp to 7d
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
    #expect(q["X-Amz-Expires"] == "604800")               // clamped to SigV4 max
    #expect(q["X-Amz-Signature"]?.isEmpty == false)
    #expect(url.path.hasSuffix("/dir/file.txt"))
    #expect(!url.absoluteString.contains(fs.testSecretForAssertOnly ?? "\u{0}")) // secret never in URL
}
```
(For the "secret not in URL" check, assert on the known test secret string used by the `connect` helper's `S3ConnectionConfig` — reference it directly rather than adding a property; adapt to how the helper builds the config. If awkward, assert `!url.absoluteString.contains("wJalr")`-style against the literal test secret.)

- [ ] **Step 2: Run red.** `swift test --filter S3FileSystem` → FAIL.

- [ ] **Step 3: Implement the seam + conformance.** New `PresignedURLProvider.swift`:
```swift
import Foundation

public enum PresignedMethod: String, Sendable { case get = "GET"; case put = "PUT" }

/// An OPTIONAL backend capability (queried via `as?`, like `RemoteShellProvider`):
/// produce a time-limited signed URL for a key. `.get` downloads it, `.put`
/// uploads to it. Pure — no network. `expiresIn` is clamped to [1s, 7 days].
public protocol PresignedURLProvider: Sendable {
    func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL
}
```
In `S3FileSystem.swift`, add conformance:
```swift
extension S3FileSystem: PresignedURLProvider {
    public func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL {
        let seconds = Int(max(1, min(604_800, expiresIn)))   // SigV4 max 7 days
        // Base object URL (no query yet).
        let base = try Self.keyRequestURL(config: config, key: key, queryPairs: [])
        guard let host = base.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = base.port.map { "\(host):\($0)" } ?? host
        let signer = SigV4Signer(accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: config.region, service: "s3", sessionToken: config.sessionToken)
        let query = signer.presignedQuery(
            method: method.rawValue, host: hostHeader,
            path: Self.canonicalKeyPath(config: config, key: key),
            expiresInSeconds: seconds, date: Date())
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RemoteFSError.protocolError(reason: "Failed to build presigned URL")
        }
        comps.percentEncodedQuery = SigV4Signer.canonicalQueryString(query: query)
        guard let url = comps.url else {
            throw RemoteFSError.protocolError(reason: "Failed to build presigned URL")
        }
        return url
    }
}
```
(Note: the SIGNED `path` must be the raw `canonicalKeyPath` — the same value that produced `base`'s `percentEncodedPath` — matching the M13/T4 signing fix; and the wire query uses `canonicalQueryString` so signed and sent agree.)

- [ ] **Step 4: Run green (unit).** `swift test --filter S3FileSystem` → PASS.

- [ ] **Step 5: GATED MinIO — presign GET fetch + PUT upload (THE signing proof).** In `S3FileSystemIntegrationTests.swift`, add (reuse the suite's `connect` + cleanup helpers; use `URLSession.shared` to hit the presigned URL directly — no new dependency, gated only):
```swift
@Test func presignedGetURLDownloadsTheObject() async throws {
    let fs = try await connectToRig()
    let key = "m14-presign-get-probe.txt"
    let body = Data("hello presigned".utf8)
    try await fs.write(path: "/\(key)", contents: stream(of: [body]))   // seed via write
    let url = try (fs as! any PresignedURLProvider).presignedURL(method: .get, key: key, expiresIn: 600)
    let (data, resp) = try await URLSession.shared.data(from: url)
    #expect((resp as! HTTPURLResponse).statusCode == 200)
    #expect(data == body)
    try? await cleanupKey(fs, key)   // reuse the raw-DELETE cleanup helper
}

@Test func presignedPutURLUploadsToTheKey() async throws {
    let fs = try await connectToRig()
    let key = "m14-presign-put-probe.bin"
    let url = try (fs as! any PresignedURLProvider).presignedURL(method: .put, key: key, expiresIn: 600)
    var req = URLRequest(url: url); req.httpMethod = "PUT"
    let body = Data(repeating: 0x5A, count: 4096)
    let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
    #expect((resp as! HTTPURLResponse).statusCode / 100 == 2)
    let stat = try await fs.stat(path: "/\(key)")
    #expect(stat.size == 4096)
    try? await cleanupKey(fs, key)
}
```
(Match the suite's actual helper names — `connectToRig`/`stream(of:)`/`cleanupKey` are placeholders for whatever the file already defines; read it first. `URLSession.shared.upload(for:from:)` sends the PUT body.)

- [ ] **Step 6: Run gated.** `MACSCP_ITEST=1 swift test --filter S3FileSystemIntegration` → PASS incl. both presign tests (rig up at 127.0.0.1:19000). If either 403s, the presigned signature is wrong — iterate live until green.

- [ ] **Step 7: Commit.**
```bash
git add Sources/macSCPCore/RemoteFS/PresignedURLProvider.swift Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3FileSystemTests.swift Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift
git commit -m "feat: generate presigned S3 URLs via a provider seam"
```

---

### Task 3: Context-menu contribution seam

**Files:**
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`, `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Test: `Tests/macSCPCoreTests/BrowserContextMenuTests.swift` (extend, or create if absent)

**Interfaces:**
- Consumes: `FileActionContribution` (M12).
- Produces: `BrowserMenuEntry.backendFileAction(FileActionContribution)`; `BrowserContextMenu.entries(for:side:crossSessionTargets:fileActions:)` (new trailing param, defaulted `[]`). `s3Descriptor.fileActions == [FileActionContribution(id: "s3.presignedURL", titleKey: "browser.action.presignedURL", titleDefault: "Share Link…")]`.

- [ ] **Step 1: Failing test — a single FILE selection carries the backend action; folders/multi-select don't.**
```swift
@Test func singleFileSelectionIncludesBackendFileActions() {
    let file = RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file)
    let action = FileActionContribution(id: "s3.presignedURL", titleKey: "k", titleDefault: "Share Link…")
    let entries = BrowserContextMenu.entries(for: [file], side: .remote, fileActions: [action])
    #expect(entries.contains(.backendFileAction(action)))
}
@Test func folderAndMultiSelectOmitBackendFileActions() {
    let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory)
    let f1 = RemoteFileItem(name: "a", path: "/a", kind: .file)
    let f2 = RemoteFileItem(name: "b", path: "/b", kind: .file)
    let action = FileActionContribution(id: "s3.presignedURL", titleKey: "k", titleDefault: "Share Link…")
    #expect(!BrowserContextMenu.entries(for: [dir], side: .remote, fileActions: [action]).contains(.backendFileAction(action)))
    #expect(!BrowserContextMenu.entries(for: [f1, f2], side: .remote, fileActions: [action]).contains(.backendFileAction(action)))
}
```
(For `BrowserMenuEntry` to be `Equatable` with the associated value: `FileActionContribution` is already `Equatable`, and the enum's other cases carry `Equatable` payloads, so add `Equatable` conformance if the enum isn't already — check; the existing `.transferToSession(CrossSessionTarget)` implies it already is.)

- [ ] **Step 2: Run red.** `swift test --filter BrowserContextMenu` → FAIL.

- [ ] **Step 3: Implement.** Add the case + param + append logic:
```swift
    case backendFileAction(FileActionContribution)   // protocol-contributed file action (M14)
```
```swift
    public static func entries(
        for selection: [RemoteFileItem], side: BrowserPaneSide,
        crossSessionTargets: [CrossSessionTarget] = [],
        fileActions: [FileActionContribution] = []
    ) -> [BrowserMenuEntry] {
        // … unchanged body …
        if selection.count == 1, let only = selection.first {
            // … existing openInEditor / rename / infoAndPermissions …
            if only.kind == .file {
                entries.append(contentsOf: fileActions.map { .backendFileAction($0) })
            }
        }
        // … newFolder / copyPath / delete …
    }
```
In `BackendDescriptor.swift`, set `s3Descriptor`'s `fileActions:` to `[FileActionContribution(id: "s3.presignedURL", titleKey: "browser.action.presignedURL", titleDefault: "Share Link…")]` (leave `sshDescriptor.fileActions` `[]`).

- [ ] **Step 4: Run green.** `swift test --filter BrowserContextMenu` → PASS; `swift test` full green (baseline 982/71 + the presign tasks).

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/Presentation/BrowserContextMenu.swift Sources/macSCPCore/Capabilities/BackendDescriptor.swift Tests/macSCPCoreTests/BrowserContextMenuTests.swift
git commit -m "feat: surface backend file actions in the browser context menu"
```

---

### Task 4: Settings — default expiry

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (extend)

**Interfaces:**
- Produces: `enum PresignedExpiry: String, Codable, CaseIterable, Sendable { case fifteenMinutes, oneHour, oneDay, sevenDays; var seconds: TimeInterval }`; `SettingsStore.presignedDefaultExpiry: PresignedExpiry` (default `.oneHour`), persisted in the existing JSON, decoding a missing key as the default.

- [ ] **Step 1: Failing test — default + roundtrip + legacy decode.**
```swift
@Test func presignedDefaultExpiryDefaultsToOneHourAndRoundtrips() throws {
    #expect(PresignedExpiry.oneHour.seconds == 3600)
    #expect(PresignedExpiry.sevenDays.seconds == 604_800)
    var store = SettingsStore(/* the test init pattern this file already uses */)
    #expect(store.presignedDefaultExpiry == .oneHour)   // default
    store.presignedDefaultExpiry = .oneDay
    // reload from disk (match how other SettingsStore tests assert persistence)
    // → still .oneDay
}
```
(Adapt to how `SettingsStoreTests` constructs/persists the store — read it first; mirror an existing setting's test exactly.)

- [ ] **Step 2: Run red.** `swift test --filter SettingsStore` → FAIL.

- [ ] **Step 3: Implement.** Add the enum + property with a default, following the file's existing Codable-with-defaults pattern (a missing key must decode to `.oneHour`, like the other settings):
```swift
public enum PresignedExpiry: String, Codable, CaseIterable, Sendable {
    case fifteenMinutes, oneHour, oneDay, sevenDays
    public var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 900
        case .oneHour: return 3600
        case .oneDay: return 86_400
        case .sevenDays: return 604_800
        }
    }
}
```
Add `public var presignedDefaultExpiry: PresignedExpiry = .oneHour` and thread it through the store's Codable exactly like a neighboring property (decode with the missing-key default).

- [ ] **Step 4: Run green.** `swift test --filter SettingsStore` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add Sources/macSCPCore/Settings/SettingsStore.swift Tests/macSCPCoreTests/SettingsStoreTests.swift
git commit -m "feat: add a default expiry setting for share links"
```

---

### Task 5: App — menu wiring, sheet, settings control, L10n

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift`, `Sources/MacSCPApp/SettingsView.swift`, `Sources/MacSCPApp/ContentView.swift` (sheet presentation + handler), `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Create: `Sources/MacSCPApp/PresignedURLSheet.swift`

**Interfaces:**
- Consumes: `PresignedMethod`/`PresignedURLProvider`/`S3FileSystem.presignedURL` (Task 2), `BrowserMenuEntry.backendFileAction` + `s3Descriptor.fileActions` (Task 3), `SettingsStore.presignedDefaultExpiry`/`PresignedExpiry` (Task 4), `BackendDescriptor.descriptor(for:)`.

> **App layer has no test target** — verify by build + `plutil -lint` + `LocalizableStringsTests` parity + trace. The coordinator runs the runtime smoke (Task 6).

- [ ] **Step 1: Feed `fileActions` into the menu.** In `RemoteFileTableView.swift`'s `Coordinator.menuNeedsUpdate`, determine the active REMOTE backend's `ConnectionKind` (the pane/tab already references its connection — trace where the remote pane's `RemoteFileSystem`/session lives; the tab's `ConnectionViewModel.kind` or the stored session's `kind` is the source). Pass `fileActions: BackendDescriptor.descriptor(for: kind).fileActions` to `BrowserContextMenu.entries(...)` for the REMOTE side only (local side passes `[]`). In `makeItem(_:selection:)`, render `.backendFileAction(let contribution)` as an `NSMenuItem` titled `L10n.string(contribution.titleKey, contribution.titleDefault)`, whose action fires a handler with `contribution.id` + the selected `RemoteFileItem`.

- [ ] **Step 2: Handler → present the sheet.** When a `backendFileAction` with id `"s3.presignedURL"` fires on a single remote file, present `PresignedURLSheet` for that item, given the active remote `RemoteFileSystem` (as `any PresignedURLProvider` — guard `as?`; if not a provider, do nothing, though the menu only offered it for S3). Wire it through the same sheet-presentation mechanism ContentView already uses for the other browser sheets (rename/info/newFolder).

- [ ] **Step 3: `PresignedURLSheet.swift`.** A SwiftUI sheet with:
  - `@State method: PresignedMethod = .get` — a segmented `Picker` ("Download (GET)" / "Upload (PUT)").
  - `@State expiry: PresignedExpiry` initialized from `settingsStore.presignedDefaultExpiry` — a `Picker` over `PresignedExpiry.allCases` (localized labels).
  - When `method == .put`: an editable `TextField` `@State targetKey` pre-filled with the item's key (`objectKey`-style, no leading slash), plus a visible warning that PUT overwrites the target key.
  - A "Generate" button → `let url = try provider.presignedURL(method: method, key: method == .put ? targetKey : itemKey, expiresIn: expiry.seconds)`; on success show the `url.absoluteString` in a read-only, selectable `TextField`/`Text` + a "Copy" button (`NSPasteboard.general.clearContents(); .setString(url.absoluteString, forType: .string)`). On throw, show a localized inline error (do NOT include the URL or any secret).
  - Never log the URL. A "Done"/"Close" dismisses.

- [ ] **Step 4: Settings control.** In `SettingsView.swift`'s Transfers tab, add a `Picker` bound to `settingsStore.presignedDefaultExpiry` over `PresignedExpiry.allCases` (localized), labeled "Default share-link expiry".

- [ ] **Step 5: L10n — all four catalogs.** Add to `{en,de,fr,pl}.lproj/Localizable.strings`:
  - `browser.action.presignedURL` = "Share Link…" (the menu title; DE "Freigabe-Link…", FR "Lien de partage…", PL "Link udostępniania…").
  - `presigned.sheet.title`, `presigned.method.get` ("Download (GET)"), `presigned.method.put` ("Upload (PUT)"), `presigned.expiry.label`, `presigned.expiry.15min`/`.1h`/`.1d`/`.7d`, `presigned.put.targetKey`, `presigned.put.overwriteWarning`, `presigned.generate`, `presigned.url.label`, `presigned.copy`, `presigned.copied`, `presigned.error` (generic "Couldn't create the link."), `settings.transfers.presignedExpiry`.
  - FR/PL: typographic quotes (« … » / „…"), NO ASCII `"` in any value. Match the exact keys used in code.

- [ ] **Step 6: Verify (no App test target).** `swift build` clean (no new warnings); `for l in en de fr pl; do plutil -lint Sources/MacSCPApp/Resources/$l.lproj/Localizable.strings; done` all OK; `swift test --filter Localizable` GREEN (parity); `swift test` full green.

- [ ] **Step 7: Commit.**
```bash
git add Sources/MacSCPApp
git commit -m "feat: share-link context action, sheet and settings"
```

---

### Task 6: Coordinator — gated verification, review, finish

- [ ] **Step 1: Full gated suite.** Rigs up (`docker compose -f docker/test-server/compose.yml up -d minio minio-init sshd sshd2`), then `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, the presign GET/PUT MinIO tests RUN and pass, zero real skips. `swift build` clean (0 new warnings); `plutil -lint` ×4 OK; `LocalizableStringsTests` green.
- [ ] **Step 2: Runtime smoke.** Package the dev app (`MACSCP_VERSION=1.4.0-dev scripts/package-app` → codesign → xattr → open), open the new sheet (connect an S3 session → right-click a file → "Share Link…"), confirm idle ~0% CPU and that GET/PUT + expiry switch without a spin. Kill.
- [ ] **Step 3: Whole-milestone review.** `scripts/review-package <M14-base> HEAD` on the most-capable model. Focus: (a) presigned SigV4 correct (matches AWS vector; gated GET/PUT pass live); (b) the presigned URL never logged/persisted, secret never in the URL; (c) abstraction purity — the menu/sheet reach S3 only via `as? PresignedURLProvider` + the descriptor's `fileActions`, no `if kind ==`; (d) expiry clamp [1, 604800]; (e) PUT overwrite warned; (f) L10n parity + quote-safety across four catalogs; (g) SSH/local browser menu unchanged (empty fileActions). Fix rounds until "Ready to merge: Yes".
- [ ] **Step 4: Finish.** Tick this plan, update the ledger + roadmap memory, commit docs, push `develop`, `gh run watch`, redeploy the dev build. **No release/tag.**

---

## Self-Review

**Spec coverage:** presigned query-signing (T1), `PresignedURLProvider` + `presignedURL` + gated GET/PUT (T2), contribution seam into the menu + `s3Descriptor.fileActions` (T3), settings default expiry (T4), sheet + menu wiring + settings control + L10n (T5), gated + review + finish (T6). Security (clipboard-only, secret never in URL), expiry clamp, no-`if kind ==`, no-new-dependency enforced per task + in Global Constraints. ✅ All spec sections map to a task.

**Type consistency:** `presignedQuery(method:host:path:expiresInSeconds:date:)` (T1) consumed by T2; `PresignedMethod`/`PresignedURLProvider`/`presignedURL(method:key:expiresIn:)` (T2) consumed by T5; `BrowserMenuEntry.backendFileAction(FileActionContribution)` + `entries(...fileActions:)` (T3) consumed by T5; `PresignedExpiry`/`presignedDefaultExpiry` (T4) consumed by T5; `FileActionContribution(id:titleKey:titleDefault:)` used consistently (id `"s3.presignedURL"`, key `browser.action.presignedURL`). ✅

**Placeholder scan:** no TBD/TODO; each code step carries real code. The test-helper-name notes in T2/T4 ("match the suite's actual helper names", "mirror an existing setting's test") are calibration against real existing code the implementer reads — not logic placeholders; the production code is fully specified. ✅

---

## M14 close-out (2026-08-01)

**All 5 tasks implemented, each with a clean task review + fix rounds.** Task
3 was committed by the coordinator (the implementer returned from a
background test run without committing; the work was correct). Task 5 (App)
was finished by a continuation agent after the first implementer's API stall
(the correct threading/sheet scaffolding was preserved).

**Verification:**
- Full gated run `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → 992/71 green;
  the presign-GET/PUT MinIO tests ran and passed (plain URLSession using only
  the signed query — the one test that catches a real SigV4 bug), plus
  S3-MinIO/SSH-integration/Keychain. `swift build` clean except for ONE
  pre-existing `TransferEngine.swift:141` warning (non-Sendable capture, NOT
  touched by M14 — old debt for a later cleanup).
- **Whole-milestone Opus review: "Ready to merge: Yes"** — (a)–(g) all
  passed: presigned SigV4 against the AWS vector + gated GET/PUT live; the
  presigned URL only to the clipboard, never logged/persisted, secret never
  in the URL; abstraction purity (only `as? PresignedURLProvider` +
  descriptor `fileActions`, no `if kind ==`); expiry clamped [1,604800];
  PUT overwrite warning; L10n parity ×4; ⌘W refactor behavior-identical.

**Delivered:** SigV4 query signing (GET+PUT), `PresignedURLProvider` seam +
`S3FileSystem.presignedURL`, the first wiring of the M12 contribution seam
into the context menu (S3 contributes "Share Link…", the generic layer
renders it), `PresignedURLSheet` (method/expiry/PUT key/copy), settings
default expiry, EN/DE/FR/PL.

**Open (deliberately, not a blocker):** maintainer visual check of the live
share-link flow (right-click S3 file → "Share Link…" → GET/PUT/copy against
real MinIO) is still pending. Ledger minors: SettingsView's expiry picker
doesn't use `allCases` (future maintenance); the `supportsPresignedURL` flag
is purely documentary (pre-existing from M12); FR/PL AI-generated (native
review before release).

**Boundaries:** cross-backend S3↔SSH = M15; "Open with" S3 CLI = a later
milestone. **NO release.**
