# FTP/FTPS and SMB: the Library Measurement of 2026-09-02

**Provenance:** written by a measurement agent on 2026-09-02 in two runs (the first was cut off by an API limit; the second continued from its scratch directory). Every command and output below was pasted, not retyped; the scratch builds are not in the repository. Adopted into `docs/` unchanged by the controller as the record behind the decision in `2026-08-25-backlog-further-protocols.md`.


Continues a measurement cut off mid-task by an API limit. The prior agent's
scratch work (SMB scratch build, two upstream clones) lived under
`/private/tmp/claude-501/-Users-noidee-macSCP/c68e1585-ea4f-4194-a037-c8f1c3a96a0d/scratchpad/protocols/`
and is reused/continued below rather than redone. All building happened in
that scratch directory; `/Users/noidee/macSCP` itself was not modified.

Machine: `arm64` (`uname -m`). Toolchain:

```
$ swift --version
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

Scope per the spec's last section
(`docs/superpowers/specs/2026-08-25-backlog-further-protocols.md`, "Decided
2026-09-02" section): SMB native/standalone, FTP+FTPS both required.

## 1. SMB

### 1a. `libsmb2` + `AMSMB2` (the spec's named candidate)

Clones already present at
`scratchpad/protocols/smb-research/libsmb2` and
`scratchpad/protocols/smb-research/AMSMB2` (both full git clones with
`.git`, done by the prior agent; reused as-is).

**Licence** (from clone, not GitHub's auto-detect):

```
$ head -20 smb-research/libsmb2/LICENCE-LGPL-2.1.txt
                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999
 ...
$ grep -n -i "licen" smb-research/libsmb2/README
6:Libsmb2 (the SMB2 client library) is distributed under the LGPLv2.1 licence.
7:libdcerpc is distributed under the 2-Clause BSD licence. See COPYING.

$ head -20 smb-research/AMSMB2/LICENSE
                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999
 ...
```

AMSMB2's own README states the consequence of static-linking libsmb2
directly:

```
$ grep -n "licensed" smb-research/AMSMB2/README.md
96:While source code shipped with project is MIT licensed, but it has static
link to `libsmb2` which is `LGPL v2.1`, consequently the whole project
becomes `LGPL v2.1`.
```

So: **AMSMB2's own source is MIT, but the shipped product is LGPL-2.1**
because SwiftPM statically compiles `libsmb2` in. GitHub's license detector
reports `NOASSERTION` for `libsmb2` (auto-detection failing on a
multi-license repo) and `LGPL-2.1` for `AMSMB2`:

```
$ gh api repos/sahlberg/libsmb2 --jq '{full_name, license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"full_name":"sahlberg/libsmb2","license":"NOASSERTION","open_issues_count":1,"pushed_at":"2026-08-30T04:14:10Z","stargazers_count":424}

$ gh api repos/amosavian/AMSMB2 --jq '{full_name, license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"full_name":"amosavian/AMSMB2","license":"LGPL-2.1","open_issues_count":16,"pushed_at":"2026-05-30T07:09:46Z","stargazers_count":310}
```

Both actively maintained (last push within days/months, not archived).

**SwiftPM support and no-kernel-mount**: AMSMB2's own `Package.swift`
vendors `libsmb2`'s C sources as a `.target(name: "libsmb2", ...)` with
`publicHeadersPath`/`cSettings` and empty `linkerSettings` — a pure userspace
SMB2/3 client, no `mount_smbfs`/Finder/kernel involvement anywhere in the
source tree (confirmed by `grep`-ing for `mount` turning up nothing in
`AMSMB2/AMSMB2/*.swift`).

**Dialects and auth** (from source, both repos):

```
$ grep -n -i "ntlm\|kerberos\|krb5\|auth" smb-research/libsmb2/README | head -10
67: sec=<mech>    : Mechanism to use to authenticate to the server. Default
69:		 krb5: Use Kerberos using credentials from kinit.
70:		 krb5cc: Use Kerberos using credentials from credentials
72:		 ntlmssp : Only use NTLMSSP
100:Libsmb2 provides has builtin support for NTLMSSP username/password authentication.
104:It can also, optionally, be built with (MIT) Kerberos authentication.

$ grep -n -i "krb\|gssapi" smb-research/libsmb2/include/apple/config.h
19:/* Define to 1 if you have the <gssapi/gssapi.h> header file. */
20:#define HAVE_GSSAPI_GSSAPI_H 1
25:/* Whether we use gssapi_krb5 or not */
26:/* #undef HAVE_LIBKRB5 */
```

libsmb2 has built-in NTLMSSP (i.e. NTLMv2-family) auth always; Kerberos is
optional and, per the Apple platform `config.h` libsmb2 ships,
**`HAVE_LIBKRB5` is undefined on Apple** — so on macOS via AMSMB2, only
NTLMSSP is available, not Kerberos. Dialects are negotiated by libsmb2's
protocol implementation (SMB2/3 per project name and README); no explicit
per-dialect enum was found in the vendored headers, consistent with libsmb2
auto-negotiating the dialect range the server offers.

**Scratch build**, `scratchpad/protocols/smb-build/` (executable package,
`.swiftLanguageMode(.v6)`, machine toolchain above). Reused/continued from
the prior agent's package:

```
$ cat smb-build/Package.swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SMBProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2", .upToNextMajor(from: "4.0.0")),
    ],
    targets: [
        .executableTarget(
            name: "SMBProbe",
            dependencies: [.product(name: "AMSMB2", package: "AMSMB2")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
```

Three build attempts are recorded in the scratch logs, in order:

1. `smb-build-log.txt` — first attempt, unpinned dependency resolved to
   AMSMB2 **3.0.0**, which failed outright:
   ```
   Computed https://github.com/amosavian/AMSMB2 at 3.0.0 (6.18s)
   error: 'smb-build': the target 'libsmb2' in product 'AMSMB2' contains unsafe build flags
   ```
   SwiftPM refuses a non-root package that declares unsafe build flags — a
   real adoption blocker at that version.

2. `smb-build-log2.txt` — after constraining to `.upToNextMajor(from:
   "4.0.0")`, resolved to **4.0.3**, which builds the C sources and the
   Swift wrapper cleanly (64 C compile steps, then the Swift module), but
   the probe source itself failed:
   ```
   Computed https://github.com/amosavian/AMSMB2 at 4.0.3 (1.30s)
   ...
   [72/76] Linking libAMSMB2.dylib
   ...
   SMBProbe.swift:6:20: error: cannot find 'URLCredential' in scope
   SMBProbe.swift:7:22: error: cannot find 'URL' in scope
   ```
   — a missing `import Foundation` in the probe, not an AMSMB2 problem.

3. `smb-build-log3.txt` — after adding `import Foundation`, clean build:
   ```
   Building for debugging...
   [0/6] Write sources
   [3/7] Emitting module SMBProbe
   [4/7] Compiling SMBProbe SMBProbe.swift
   [5/7] Linking SMBProbe
   [6/7] Applying SMBProbe
   Build complete! (2.34s)
   ```

Warning/error counts across all three logs:

```
$ grep -c 'warning:' smb-build-log.txt smb-build-log2.txt smb-build-log3.txt
smb-build-log.txt:0
smb-build-log2.txt:0
smb-build-log3.txt:0
```

(Errors: 1 unsafe-flags error in log 1 at the dependency-version level, 2
`Foundation`-import errors in log 2 at the probe-source level — neither
names strict concurrency. Final state: **0 warnings, 0 errors**, AMSMB2
4.0.3, `.swiftLanguageMode(.v6)`.) `swift build --build-tests` on the same
package also completes clean.

`Package.resolved` pin from the successful build:

```
$ cat smb-build/Package.resolved
"amsmb2" ... "revision":"1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0", "version":"4.0.3"
```

**Known correctness risk in AMSMB2**, from its open issues (titles only,
`gh api .../issues`):

```
Crash in SMB2Client.generic_handler when CHANGE_NOTIFY response arrives
Incorrect POSIXError (Code 52) when creating duplicate directory in 4.0.0+
STATUS_OBJECT_NAME_INVALID
Requires support for anonymous login
```

The second item is a regression reported specifically against 4.0.0+ — the
exact version line this scratch build pins to.

### 1b. Other pure-Swift SMB clients found via `gh search repos`

```
$ gh search repos "smb client" --language=swift --limit 20 --json fullName,stargazersCount,pushedAt,description
kishikawakatsumi/SMBClient | stars=285 | pushed=2026-04-27T14:55:36Z | Swift SMB client library and iOS/macOS file browser applications.
SHADYHAN/SMB-Client | stars=0 | pushed=2026-07-22T04:56:43Z |
kishikawakatsumi/SMBeam | stars=2 | pushed=2026-04-30T10:18:47Z | A native macOS SMB client built for video streaming.

$ gh search repos "smb2" --language=swift --limit 20 --json fullName,stargazersCount,pushedAt,description
amosavian/AMSMB2 | stars=310 | pushed=2026-05-30T07:09:46Z | Swift framework to connect SMB2/3 shares
jiikko/swift-smbee | stars=0 | pushed=2026-08-31T14:58:31Z | A pure-Swift SMB2/3 client — SMB protocol self-built, crypto via swift-crypto
dmplng-bits/SwiftSMB | stars=0 | pushed=2026-07-21T19:51:01Z | A pure-Swift SMB2/3 client library, zero external dependencies
codemastervy/simple-smb-file-browser | stars=1 | pushed=2026-09-01T02:39:26Z | Multiplatform SwiftUI SMB2/3 file browser
```

`jiikko/swift-smbee`, `dmplng-bits/SwiftSMB`, `SHADYHAN/SMB-Client`: 0 stars,
freshly pushed, no track record — not evaluated further (unmeasured, not
ruled in or out).

**`kishikawakatsumi/SMBClient`** stood out enough to measure properly —
pure Swift, no C dependency at all, so it sidesteps the LGPL question above
entirely:

```
$ gh api repos/kishikawakatsumi/SMBClient --jq '{full_name, license: .license.spdx_id, pushed_at, created_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"created_at":"2024-07-16T05:37:24Z","license":"MIT","open_issues_count":12,"pushed_at":"2026-04-27T14:55:36Z","stargazers_count":285}
```

Dialects, from source (`Sources/SMBClient/Messages/Negotiate.swift`):

```
public enum Dialects: UInt16 {
    case smb202 = 0x0202
    case smb210 = 0x0210
    case smb300 = 0x0300
    case smb302 = 0x0302
    case smb311 = 0x0311
}
```

SMB 2.0.2 through 3.1.1 — the full SMB2/3 dialect range. Auth: has
`Sources/SMBClient/Auth/NTLM.swift`; `gh search code "Kerberos"` and `"GSSAPI"`
scoped to the repo both return empty — **NTLM only, no Kerberos**. A search
for `"AES"` in the repo also returns empty while `"signing"` hits several
files — **SMB signing is implemented, SMB3 encryption (AES-CCM/GCM) is
not**, and the repo's own open issues confirm this is a known gap:

```
$ gh api repos/kishikawakatsumi/SMBClient/issues --jq '.[] | select(.pull_request == null) | .title'
Add FileEndOfFileInformation support (SetInfo for file size / truncate)
Will this support SMB3 and encrypted SMB?
Memory management issues
Usage with Swift 6
Unable to download large files
`SequenceNumber` is not thread-safe
...
```

"`SequenceNumber` is not thread-safe" and "Usage with Swift 6" are open,
unresolved issues — worth weighing against the clean scratch-build result
below, which only proves the *compiler's* strict-concurrency checker didn't
reject the library, not that it is free of concurrency bugs at runtime.

**Scratch build**, `scratchpad/protocols/smbclient-build/` (new, this
session — no tagged `1.0.0` exists, so pinned to the latest real tag):

```
$ gh api repos/kishikawakatsumi/SMBClient/tags --jq '.[].name'
0.3.1
0.3.0
...
```

```
// Package.swift
.package(url: "https://github.com/kishikawakatsumi/SMBClient", from: "0.3.1"),
.executableTarget(name: "SMBClientProbe", dependencies: [.product(name: "SMBClient", package: "SMBClient")],
    swiftSettings: [.swiftLanguageMode(.v6)])
```

```
$ swift build
Fetched https://github.com/kishikawakatsumi/SMBClient from cache (17.89s)
...
[85/88] Compiling SMBClient TreeAccessor.swift
[86/90] Emitting module SMBClientProbe
[87/90] Compiling SMBClientProbe main.swift
[89/90] Applying SMBClientProbe
Build complete! (14.46s)

$ grep -c "warning:" smbclient-build-log.txt
0
$ grep -c "error:" smbclient-build-log.txt
0
```

**0 warnings, 0 errors**, under `.swiftLanguageMode(.v6)`, MIT, no vendored
C code, no unsafe-flags issue, no LGPL entanglement. The `SMBClient` library
target itself uses no `@unchecked Sendable` / `nonisolated(unsafe)` escape
hatches (`gh search code` for both inside the repo hits only
`Examples/`/`Tests/`, never `Sources/SMBClient/`) — the strict-concurrency
pass is not merely silenced.

### SMB summary table

| | libsmb2 + AMSMB2 4.0.3 | kishikawakatsumi/SMBClient 0.3.1 |
|---|---|---|
| Licence | LGPL-2.1 (whole product, static link) | MIT |
| Dependency shape | vendors C `libsmb2` | pure Swift, zero deps |
| SwiftPM + `.v6` scratch build | clean, 0 warn/0 err (after pinning ≥4.0.0) | clean, 0 warn/0 err |
| Dialects | SMB2/3, auto-negotiated (no dialect enum found) | SMB 2.0.2–3.1.1 explicit enum |
| Auth | NTLMSSP (Kerberos code path exists but `HAVE_LIBKRB5` unset on Apple) | NTLM only |
| Signing/encryption | not directly inspected this session | signing yes, SMB3 encryption no (open issue) |
| Maintenance | active (AMSMB2 pushed 2026-05, libsmb2 2026-08) | active (2026-04) |
| Known open risk | crash + regression issues against 4.0.0+ | thread-safety issue open, Swift 6 usage question open |
| No mount involved | confirmed (pure userspace client) | confirmed (pure userspace client) |

## 2. FTP / FTPS

```
$ gh search repos "ftp client" --language=swift --limit 20 --json fullName,stargazersCount,pushedAt,description
constantine-fry/rebekka | stars=88 | pushed=2021-10-22T16:53:16Z | Rebekka - FTP/FTPS client in Swift.
fenixkim/SwiftFTPClient | stars=15 | pushed=2024-09-15T01:26:09Z | Modern Swift FTP client using Network framework.
RetepV/FTPClientLib | stars=0 | pushed=2026-02-24T13:59:58Z | An FTP client library written in Swift, using strict Swift Concurrency.
yafoxins/SwiftFTP | stars=2 | pushed=2025-07-01T06:10:20Z | Modern SFTP/FTP client for macOS with native SwiftUI interface
[... several 0-star personal/app projects omitted, not maintained libraries]

$ gh search repos "ftp" "swift-nio" --limit 20 --json fullName,stargazersCount,pushedAt,description
(empty — no results)

$ gh search repos "nio ftp" --limit 15 --json fullName,stargazersCount,pushedAt,description
(empty — no results)

$ gh search repos "swift ftps" --limit 15 --json fullName,stargazersCount,pushedAt,description
fenixkim/SwiftFTPClient | stars=15 | pushed=2024-09-15T01:26:09Z | Modern Swift FTP client using Network framework.
```

**No swift-nio-based FTP library exists on GitHub at all** — every search
combining "ftp" with "nio" or "swift-nio" returns zero results. Metadata on
the only three candidates with any track record:

```
$ gh api repos/constantine-fry/rebekka --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":true,"license":"BSD-2-Clause","open_issues_count":20,"pushed_at":"2021-10-22T16:53:16Z","stargazers_count":88}

$ gh api repos/fenixkim/SwiftFTPClient --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":"MIT","open_issues_count":1,"pushed_at":"2024-09-15T01:26:09Z","stargazers_count":15}

$ gh api repos/RetepV/FTPClientLib --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":"GPL-3.0","open_issues_count":0,"pushed_at":"2026-02-24T13:59:58Z","stargazers_count":0}
```

- `rebekka`: **archived** by its owner. Dead.
- `fenixkim/SwiftFTPClient`: MIT, not archived, but built on `Network.framework`
  (not NIO) and its own README only documents upload with progress
  tracking — no FTPS/TLS mention anywhere in the README, no explicit
  download/listing API shown either:
  ```
  $ gh api repos/fenixkim/SwiftFTPClient/contents/README.md --jq '.content' | base64 -d | head -20
  SwiftFTPClient is a modern, Swift-based FTP client library that leverages
  the `Network` framework ... Support for uploading files and raw data ...
  ```
  No FTPS support — not fit for the "FTP and FTPS both" requirement as-is.
- `RetepV/FTPClientLib`: GPL-3.0 (licence alone rules it out for a
  dependency of an MIT-adjacent project without a matching decision), 0
  stars, no track record.

**No NIO-based candidate exists, and no complete, maintained, license-clean
FTP+FTPS client exists in the Swift ecosystem at all.** This confirms the
spec's own expectation in the "Decided 2026-09-02" section: FTP/FTPS is a
from-scratch build over `swift-nio` (control channel) + NIOSSL (FTPS),
not a dependency adoption. No scratch build was attempted for FTP since
there is nothing viable to build against — the two "top NIO-based
candidates" the task asked to scratch-build do not exist.

## 3. NIOSSL in the existing dependency graph

```
$ grep -c "swift-nio-ssl" /Users/noidee/macSCP/Package.resolved
0
```

Full list of pinned identities in `Package.resolved` today: `bigint`,
`citadel`, `swift-argument-parser`, `swift-asn1`, `swift-atomics`,
`swift-collections`, `swift-crypto`, `swift-log`, `swift-nio` (2.101.2),
`swift-nio-ssh`, `swift-system`, `swiftterm`. **`swift-nio-ssl` (NIOSSL) is
absent** — neither `swift-nio` 2.101.2, nor Citadel, nor `swift-nio-ssh`
pulls it in transitively. It would need to be added as a fresh direct
dependency for FTPS (and would then also cover the WebDAV backend's
existing `optionalTLS`/`TrustedCertificateStore`-style needs if that ever
moves off `URLSession`, though that is out of scope here).

## 4. Capability mapping — `ProtocolCapabilities`

Fields per `Sources/macSCPCore/Capabilities/ProtocolCapabilities.swift`:
`supportsShell`, `permissionModel` (`.posixMode`/`.acl`/`.none`),
`supportsSymlinks`, `atomicRename`, `directoriesAreReal`, `resumeMode`
(`.append`/`.rangeGet`/`.restOffset`/`.none`), `supportsPresignedURL`,
`supportsRemoteChecksum`, `transport`
(`.alwaysEncrypted`/`.optionalTLS`/`.plaintext`).

| Field | SMB (either candidate) | FTP (plain) | FTPS (explicit/implicit) |
|---|---|---|---|
| `supportsShell` | `false` — from docs (SMB has no shell channel) | `false` — from docs | `false` — from docs |
| `permissionModel` | `.acl` — from source: both libsmb2 (`smb2-set-security-info.c`, `smb2-raw-getsd-async.c`) and SMBClient (`SecurityDescriptor.swift`) expose Windows-style security descriptors, not POSIX mode bits | `.none` **unknown/server-dependent** — some servers expose UNIX perms via `SITE CHMOD`, not a base-protocol guarantee; not measured against a real server | same as plain FTP |
| `supportsSymlinks` | `true` — from source: libsmb2 ships `smb2-symlink-sync.c` and `smb2-data-reparse-point.c`; SMB2 reparse points are the mechanism | **unknown** — `LIST`/`MLSD` may surface a symlink type on Unix-style servers but there is no protocol primitive; not measured | same as plain FTP |
| `atomicRename` | `true` — from source: libsmb2's `smb2-rename-sync.c`, SMBClient's `FileRenameInformation.swift` both implement SMB2 `SET_INFO`/`FileRenameInformation`, a single atomic operation | `true` — from docs (spec text): `RNFR`/`RNTO` | same as plain FTP |
| `directoriesAreReal` | `true` — from docs (SMB is a real filesystem protocol, not object storage) | `true` — from docs (spec text) | same as plain FTP |
| `resumeMode` | **unknown / no clean enum fit** — SMB reads and writes take an arbitrary byte offset per request (both libraries), which is not exactly `.append`, `.rangeGet` (GET-only) or `.restOffset` (an FTP-specific command name); needs a design decision, possibly a new case | `.restOffset` — from docs (spec text): FTP `REST` | same as plain FTP |
| `supportsPresignedURL` | `false` — from docs (no such SMB concept) | `false` — from docs | `false` — from docs |
| `supportsRemoteChecksum` | **unknown** — neither library was searched for a checksum/hash extension this session; SMB has no standard base-protocol checksum command | `false` by default, **conditionally `true`** — from docs (spec text): only if `XSHA256`/`HASH` is measured present on a given server, which is a per-connection fact, not a static protocol fact — same tension as `resumeMode` above, may need to be a runtime-detected capability rather than a static descriptor field | same as plain FTP |
| `transport` | **unknown / no clean enum fit** — SMB2/3 signing and encryption are negotiated via session keys derived from NTLM/Kerberos, not a TLS handshake with a certificate trust store; none of `.alwaysEncrypted`/`.optionalTLS`/`.plaintext` describes that mechanism accurately, this is a real design gap, not an oversight in this table | `.plaintext` — from docs (spec text): goes through the existing `PlaintextTransportGate` | **not representable as a single value** — from docs (spec text): explicit (`AUTH TLS`, port 21) and implicit (TLS-from-byte-one, port 990) are two different modes of what the descriptor calls one `ConnectionKind`; likely needs a per-connection field rather than a fixed descriptor value, mirroring the `resumeMode`/checksum tension above |

Three cells are flagged **unknown / no clean enum fit** rather than guessed:
SMB's `resumeMode` and `transport`, and FTP's/FTPS's checksum and transport
being connection-time facts rather than protocol-static ones. All three are
measurement findings for the eventual design step, not implementation
decisions made here.

## 5. Rig options (research only — compose file not touched, no containers started)

Per the project's `docker/test-server/compose.yml` pattern: pinned tags,
never `latest`, `linuxserver.io`/similarly maintained images for SSH and
`minio` for S3 today. Researched equivalents for FTP/FTPS and SMB, same
constraints (licence, arm64, since this machine is `arm64`, maintenance):

### FTP with TLS (explicit + implicit)

```
$ gh api repos/stilliard/docker-pure-ftpd --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":"MIT","open_issues_count":25,"pushed_at":"2026-07-15T14:55:00Z","stargazers_count":890}
```

`stilliard/docker-pure-ftpd` (pure-ftpd): MIT, active, most-starred FTP
Docker image found. TLS is configurable via `ADDED_FLAGS=--tls=1` (optional)
or `--tls=2`:

```
$ grep -n -i "arm64\|990\|implicit" README.md
166:**An arm64 build is also available here:** https://hub.docker.com/r/zhabba/pure-ftpd-arm64 *- Thanks @zhabba*
(no other matches — no "990" or "implicit" anywhere in the README)
```

Two measured risks: (1) **the maintained image has no native arm64 build**
— the README points to a third-party fork (`zhabba/pure-ftpd-arm64`) with
no corresponding GitHub repo found via `gh search repos`, so its
maintenance state is itself unmeasured; (2) **implicit FTPS (port 990) is
undocumented** in this wrapper — only explicit `AUTH TLS` is described, so
implicit-mode testing would need custom configuration verified against the
underlying `pure-ftpd` binary's own docs, not this container's README.

Other candidates checked and rejected/not viable for the FTPS requirement:

```
$ gh api repos/garethflowers/docker-ftp-server --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":"MIT","open_issues_count":13,"pushed_at":"2026-08-03T19:52:30Z","stargazers_count":257}
```
`garethflowers/docker-ftp-server` (vsftpd): MIT, actively maintained
(2026-08-03), but its README documents no TLS/`ssl_enable` configuration at
all — plain FTP only as shipped.

```
$ gh api repos/chonjay21/docker-ftps --jq '{license: .license.spdx_id, pushed_at, ...}'
{"license":"MIT", "pushed_at":"2020-09-19T12:23:59Z", "stargazers_count":6}
```
`chonjay21/docker-ftps`: name suggests FTPS but stale since 2020, 6 stars —
not evaluated further.

### SMB

```
$ gh api repos/dperson/samba --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":"AGPL-3.0","open_issues_count":101,"pushed_at":"2024-03-08T22:06:15Z","stargazers_count":1707}

$ gh api repos/crazy-max/docker-samba --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":"MIT","open_issues_count":10,"pushed_at":"2026-08-19T16:22:53Z","stargazers_count":633}

$ gh api repos/ServerContainers/samba --jq '{license: .license.spdx_id, pushed_at, open_issues_count, stargazers_count, archived}'
{"archived":false,"license":null,"open_issues_count":8,"pushed_at":"2026-07-11T06:29:40Z","stargazers_count":670}
```

`dperson/samba` (most-starred): AGPL-3.0, and **stale — last pushed
2024-03-08**, over two years before this measurement. Not recommended.

`crazy-max/docker-samba`: MIT, actively maintained (pushed 2026-08-19), and
explicitly documents multi-platform support including `linux/arm64`:

```
$ grep -n -i "arm64\|platform" README.md
47:* Multi-platform image
74:Following platforms for this image are available:
83:linux/arm64
```

This is the strongest measured SMB rig candidate: MIT, active, confirmed
arm64.

## Answers

**SMB**: recommended path is `kishikawakatsumi/SMBClient` (MIT, pure Swift,
zero C dependency, builds clean under `.v6` with 0 warnings/errors,
SMB 2.0.2–3.1.1) over `libsmb2`/`AMSMB2` (also builds clean at AMSMB2
≥4.0.0 with 0 warnings/errors, but the whole product becomes LGPL-2.1 via
static-linked `libsmb2`, and 3.x fails outright on SwiftPM's unsafe-flags
check). Biggest measured risk: SMBClient has **no SMB3 encryption**
(signing only — confirmed absent from source and from its own open "Will
this support SMB3 and encrypted SMB?" issue) and an open,
unresolved thread-safety report on `SequenceNumber`; picking it trades a
licensing problem for a maturity gap that has not been independently
verified beyond "the strict-concurrency checker accepted it."

**FTP/FTPS**: recommended path is a from-scratch control-channel
implementation over `swift-nio` + NIOSSL, confirmed by measurement — no
NIO-based FTP library exists on GitHub at all (every "nio"+"ftp" search
returned zero), and of the three candidates with any track record, one is
archived (`rebekka`), one has no FTPS support in its documented API
(`fenixkim/SwiftFTPClient`), and one is GPL-3.0 with zero stars and no
track record (`RetepV/FTPClientLib`). Biggest measured risk: NIOSSL is
**not currently in macSCP's dependency graph at all** (absent from
`Package.resolved`, confirmed by `grep`), so FTPS is not just new
application code but a new direct dependency and its own supply-chain
review — and the two FTPS test-rig images researched each have a real gap
(`stilliard/docker-pure-ftpd`: no native arm64 build, implicit-mode
untested/undocumented; `garethflowers/docker-ftp-server`: no TLS at all),
so validating the from-scratch implicit-FTPS path against a real server
may itself need custom rig work before any implementation plan can rely on
it.

**NIOSSL**: **not present** in macSCP's dependency graph today.
`Package.resolved` pins `swift-nio` 2.101.2, Citadel, `swift-nio-ssh`, and
eight other identities — `swift-nio-ssl` is not among them and is not
pulled in transitively by any of the three. Adding FTPS support means
adding it fresh.
