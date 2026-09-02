# Backlog: dependencies against current releases

**Created:** 2026-08-20, from a maintainer call-out. Measured against
`Package.swift`, `Package.resolved` and the tags of the respective
projects.

## Is vs. latest

| Package | resolved | latest | Note |
|---|---|---|---|
| Citadel | 0.12.1 | **0.12.1** | already current |
| swift-argument-parser | 1.8.2 | 1.8.2 | current |
| swift-nio | 2.101.2 | 2.101.3 | patch |
| swift-crypto | 3.15.1 | **4.5.1** | capped by `from: "3.0.0"` |
| SwiftTerm | revision, 2026-07-01 | **v1.20.0**, 2026-08-18 | **98 commits behind** |
| swift-nio-ssh | **fork `Wellz26` 0.3.6** | `apple` 0.15.0 | see below |

**On the initial hypothesis:** Citadel is *not* at 0.15 — 0.12.1 is the
latest release there, and that is what we sit on. The 0.15 belongs to
**swift-nio-ssh**, which sits one layer deeper.

## The actual finding: the SSH transport package is a third-party fork

`swift-nio-ssh` does not come from Apple, but from
`https://github.com/Wellz26/swift-nio-ssh.git`. That is **not a decision
made by macSCP** — Citadel 0.12.1 pins it in its own `Package.swift`
(`"0.3.4" ..< "0.4.0"`), directly under a commented-out local path
belonging to Citadel's author.

That places the package that negotiates every SSH connection in this app,
in the trust chain, as a **personal fork of an Apple library**, and its
release stands far behind Apple's 0.15.0.

### Measured on 2026-08-26

The open question — does the fork track Apple's branch or has it gone its
own way — is answered. Both repositories fetched into an empty working
directory and their histories compared:

| | |
|---|---|
| Common base with `apple/main` | `b0591e4c`, **2022-04-21** |
| Commits the fork has added since the base | 76 |
| **Commits Apple has since the base that never arrive here** | **91** |
| Branch of the pinned commit | `citadel2`, not contained in any Apple branch |
| Pinned commit | `a05e6bbe`, 2026-04-02, Mac Catalyst fix |

The fork does **not**, then, track Apple: it branched off more than four
years ago and has gone its own way since. The numbering is also its own —
Apple has no tag `0.3.6` at all. What sits in Apple's 91 commits has not
yet been evaluated by this; that it does **not** arrive here has been.

### What sits in Apple's 91 commits (evaluated 2026-08-26)

The fork is recognizably a **feature fork**, not a suspicious one: RSA
keys on the client side, its own transport and key-exchange algorithms,
certificate authentication, platform support (visionOS, Musl, Bionic, Mac
Catalyst). Understandable reasons for not having adopted Apple's
mainline. Its last merge from `apple/main` is from **2022-05-06**;
everything after that is missing.

Of Apple's 91 commits, most are CI, benchmarks, and Swift version bumps.
Three things remain relevant:

**1. The concurrency adoption — and it already costs us something.**
Apple fully adopted `Sendable` in 2023 (#151) and followed up with strict
concurrency in 2025 (#196, #197, #200). None of that reached the fork:

| | Fork (shipped) | `apple/main` |
|---|---|---|
| `NIOSSHUserAuthenticationOffer` | `public struct … {` | `public struct …: Sendable {` |

That is **one of the six errors** that switching `macSCPCore` to
`.swiftLanguageMode(.v6)` throws today. We would therefore be building a
workaround for something that has been fixed upstream for three years and
simply never reaches us. (The second Citadel error concerns
`SSHAuthenticationMethod` — a `public final class` belonging to Citadel
itself, not to the fork.)

**2. The 2026 hardening is missing.** `Limit buffered state` (#244),
`Configurable max packet size` (#245) and `Limit client auth attempts`
(#247) are limits against a counterpart that sends too much. For a client
that connects to foreign servers, the first is the one that matters most.

**3. Apple's crash fix is moot for us — for a reason that is itself the
finding.** `Fix readVersion() crash on bare LF as first byte` (#238,
2026-06) guards an `advanced(by: -1)` access. This code does not exist in
the fork: `readVersion` was **rewritten from scratch** there (a loop over
lines, skipping preamble lines until one starting with `SSH-`, no index
arithmetic). The crash therefore does not exist for us.

The flip side: the string parsing a client applies as the **very first
thing to unauthenticated bytes from a foreign server** is, in the fork,
homegrown and has never gone through Apple's review. That is not a
finding of a bug — only a finding of where the burden of proof lies.

### Sidestepping is not merely a matter of taste

Tested whether Apple's package can be forced in the root manifest
(`.package` on `apple/swift-nio-ssh` from 0.15.0, then reverted).
Resolution fails:

```
error: Dependencies could not be resolved because root depends on
'citadel' 0.12.1..<1.0.0 and root depends on 'swift-nio-ssh' 0.15.0..<1.0.0.
```

Citadel pins the range `"0.3.4" ..< "0.4.0"` in its own manifest.
**Without changing Citadel itself, there is no way around the fork** — a
version override in the root package is not enough. That rules out the
"just point at Apple" path; what remains: approach Citadel upstream, fork
Citadel itself, or stay on watch and document the situation.

This is the point that needs a decision — not the numbers in the table.
Possible paths: clarify with Citadel upstream whether the fork can go
away; diff the fork against Apple's release and assess it; or stay on
watch and document the situation. All three are defensible, none is a
side note.

## The rest, in order

1. **swift-nio to 2.101.3.** Patch, should be consequence-free. The
   cheapest step.
2. **SwiftTerm.** Today pinned to a bare revision — no version, no semver,
   no range. Before raising it, it needs to be clarified **why** this
   commit was chosen; a revision pin usually means a specific fix was
   needed at the time. If that is not established, the jump to v1.20.0 is
   a blind flight across 98 commits through the terminal display.
3. **swift-crypto to 4.x.** A major jump that `from: "3.0.0"` currently
   blocks. This weighs heavier than the others, because swift-crypto sits
   in key handling (generation, loading, fingerprints) — being two major
   versions behind is a different matter there than for a display
   library. `5.0` is in beta and stays out of scope.

## Dependency that determines the order

A dependency jump can easily drag along a **toolchain jump**, and that
runs into the open debt from
`2026-08-19-backlog-swift6-warnings.md`: around 1200 warnings literally
say "this is an error in the Swift 6 language mode", while all targets
stand on `.swiftLanguageMode(.v5)`.

**Hence the warnings before the big jumps** — otherwise both land at
once and a red build leaves no way to tell which of the two changes
broke it.

## Order

swift-nio (patch) → Swift 6 warnings → SwiftTerm (after clarifying the
pin) → swift-crypto 4.x. The fork is not a rung on this ladder but its
own decision; it can be tackled before or after at any point.

---

## Measured 2026-08-31 — the fork finding, and why a Citadel fork solves nothing

**The chain is different from what the entry above assumes.** Citadel
does not depend on `swift-nio-ssh`, but on a **never-merged feature
branch** of it (`jo-rsa-private-keys`, from Citadel's own author).
`Wellz26` is a fork *of that fork*, carrying the PR forward — and
Citadel's own `Package.swift` wires it in fixedly:

```
.package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0")
```

### A Citadel fork cannot fix this

Measured against Apple 0.15.0: **52 distinct error sites** (277 raw
`error:` lines) across 7 of 37 Citadel files, **13 root causes** in **4
families**. **38 of 52** fall onto a single one: Apple exports five
public protocols, of which **one** is an algorithm extension point
(`NIOSSHTransportProtection`). The machinery for key exchange and
public-key types is `internal` at Apple.

No rename, no signature drift — two independent developments since 2022.
`NIOSSHTransportProtection` has diverged on **both sides**.

**The sentence that decides the direction:**

> `grep "ssh-rsa|rsa-sha2"` over Apple 0.15.0 = **0 hits**

Apple's swift-nio-ssh has **no RSA**. Citadel's entire RSA support sits
on the fork's own protocols — that is, exactly the surface PR #135
builds on. Going back to Apple **removes** RSA rather than fixing it.

### No cheap intermediate step

Measured, not reasoned about: Apple 0.4.1–0.8.0 already fail at
resolution (swift-crypto `<3.0.0` against Citadel's `3.12.3+`). The
smallest resolvable jump is 0.9.1 — **54** error sites, two *more* than
0.15.0, and without a single security fix.

### The fork is not a mirror

The fork point is Apple **0.4.0** (2022-04-21), not 0.3.x — the tags
`0.3.4`–`0.3.6` are fiction, Apple's highest 0.3.x is 0.3.3. Citadel's
range is unsatisfiable against Apple's repo. **76 commits** (54
non-merge), 58 files, +1278/−354, **91 Apple commits** of distance.

## What follows from this: security and architecture are separable

That is the way out the measurement itself found.

**The architecture** — going back to Apple's maintained library — is a
real port (rebasing 54 commits) **and then permanent maintenance**, with
the same single point of failure where the current state has failed.
Moved, not solved.

**The security** can be had cheaply and separately. Of Apple's three most
recent corrections, two apply to macSCP as a **client**:

| Fix | applies to macSCP |
|---|---|
| **0.14.1** — reject overlong ECDSA signature mpints (`31cdc3c`, +70/−2, ~11 lines of production code) | **yes**, macSCP parses server signatures |
| **0.14.0** — crash on malformed version strings | **yes**, a malicious server could crash the client |
| 0.15.0 — limit login attempts | **no**, server-side protection |

**Not measured:** whether the two apply cleanly. The 0.14.1 fix sits in
`NIOSSHSignature.swift`, a file changed by the fork — a conflict zone.
That is the first step before anything is committed to.

**And the cost that needs naming:** a cherry-pick means two of our own
repos — swift-nio-ssh (for the fixes) and Citadel (one line, to point at
it). Whether SwiftPM can also do this without the Citadel fork via a
dependency override is measurable, and would be cheaper.

**What this does not fix:** RSA out of the file. That waits on Citadel's
#135. Exactly this separation is the yield of the measurement — before it
looked like one problem, it is two, and only one is cheap.

---

## Measured 2026-09-01 — the cherry-picks, and a bug that stems from no gap

Three questions were open: does the cherry-pick hold up, does it need a
Citadel fork for that, and is the fork even vulnerable. All three are
answered, and a fourth finding turned up while measuring that outranks
the others in urgency.

### 0.14.1 (ECDSA mpints): applicable, and the gap is real

| | |
|---|---|
| Cherry-pick onto `a05e6bb` | **conflict-free**, 2 files, +70/−2 |
| `swift build` afterward | clean |
| `swift test` afterward | **357 tests, 0 failures** (baseline was 355 — exactly the two new ones) |

The fork **never touched** `ECDSASignatureHelper`; the same missing
bounds check that existed in Apple's code before the fix sits there. The
earlier assumption that the conflict would be in signature parsing was
wrong.

**Proved by a failing test rather than assumed:** taking just the guard
check back out again crashes the shipped tests with `Fatal error` and
signal 5 — **even in a release build**, so the check is not optimized
away.

**Honestly scoped:** what was observed was a **crash** — a remote DoS
from server-controlled bytes, before login. The silent memory overrun
described by Apple's comment was **not** observed.

### 0.14.0 (version string): moot

Two grounds checked, both against the original assumption:

1. The patched expression sits in Apple's `if self.isServer` branch — it
   protects **servers from clients**, not the other way round.
2. The fork rewrote `readVersion()` from scratch; the patched spot does
   not exist there (`isServer` appears 4 times in Apple's
   `SSHPacketParser.swift`, 0 times in the fork).

Eleven malformed inputs against the fork's parser: no crash.

### No Citadel fork needed

A root dependency of the same package identity with a different URL
**resolves and builds Citadel completely**. The control carries the
proof: pointing at Apple's URL instead fails with a **version** error
that merges both URLs into *one* package — so SwiftPM accepts the URL
swap and only disputes versions.

**That makes one fork fewer than planned:** only `swift-nio-ssh`.

### Correction to the assessment of 0.15.0

0.15.0 is **three** commits, not one, and `6d576c8` ("Limit buffered
state") is very much client-relevant. The earlier classification of
"out of scope" was incomplete. The fork, however, **already has** this
protection independently — and this very rework is the reason 0.14.0 is
moot.

**Consequence for wording:** "91 commits behind" describes the fork
incorrectly. It is **ahead** on buffer limits and was behind on
signature parsing. Every further fix needs its own review; three
releases are assessed, the rest are not.

---

## The fourth finding: RFC 4253 §4.2 is not honored

While comparing the parsers it turned up that the fork does not strip
preamble lines **before** the version string. RFC 4253 §4.2 permits a
server to send such lines, and a client MUST be able to handle them.

**Measured on 2026-09-01, against the rig**, with a TCP forwarder in
front of it that prepends exactly these lines — the rig's sshd left
unchanged:

| Counterpart | OpenSSH client | macSCP |
|---|---|---|
| direct | connects | **connects** |
| transparent forwarder (0 preamble lines) | connects | **connects** |
| 1 preamble line | connects | **`invalidExchangeHashSignature`** |
| 3 preamble lines | connects | **`invalidExchangeHashSignature`** |
| OpenSSH `Banner` directive | connects | **connects** |

The two controls carry the conclusion: the forwarder alone changes
nothing, and the OpenSSH client gets through. It sits in the client
stack.

**The bug matches the cause exactly.** V_S goes into the exchange hash.
The server hashes `SSH-2.0-OpenSSH_10.3`, macSCP hashes
`Welcome…\r\nSSH-2.0-OpenSSH_10.3` — the signature cannot be right.

### The boundary of the damage, also measured

**The obvious worry is wrong, and that was a hypothesis of mine:** the
OpenSSH `Banner` directive does **not** trigger it. Measured on the
wire, the first bytes of a server set up that way are
`SSH-2.0-OpenSSH_10.3\r\n` — the legal notice travels as
`SSH_MSG_USERAUTH_BANNER` **after** the key exchange. The typical
corporate server with a legal notice is therefore **not** affected.

What is affected is anything sending preamble lines **before** the
identification string: upstream load balancers and TCP proxies, jump
server wrappers, network and embedded devices. **How many servers do
this is not measured** and is not claimed here.

### Why it matters anyway

The message reads `invalidExchangeHashSignature`. That reads like an
attack on the connection, not like "your server is sending a preamble
line" — anyone seeing it looks in the wrong place. A user can neither
recognize the error nor work around it.

### What this means for the fork

The cherry-pick does **not** fix this — it is a separate defect that the
rewrite of `readVersion()` introduced. Whoever creates the fork takes
both along: the ECDSA fix from 0.14.1 **and** the stripping of preamble
lines.

### Rebuilding the test setup

A TCP forwarder that, on every connection, first sends
`Welcome…\r\n` to the client and then passes both directions through to
the rig; a second one without preamble lines as a control. The
measurement scaffold was throwaway code and has been removed. **A
regression test for this needs the forwarder as part of the rig** — that
is to be designed, not built on the side.

---

## Done 2026-09-01 — the fork exists, and one measurement in the report above was wrong

**`https://github.com/NoiXdev/swift-nio-ssh`**, forked from `Wellz26/swift-nio-ssh`
(default branch `citadel2` = `a05e6bb`, the revision macSCP had pinned as 0.3.6).
Branch `macscp/ecdsa-mpint-and-prelines`, tag **`0.3.7`**, two commits on top:

| commit | what | proof |
|---|---|---|
| `b098395` | cherry-pick of Apple `31cdc3c` (0.14.1, ECDSA mpint validation) | applied without conflict; suite 357 → 357 |
| `089d3ec` | RFC 4253 §4.2: only the `SSH-` line is the version | red first (3 tests), then 358 / 0 |

The preamble fix needed one more thing than the one-line change: the fork's
`SSHPacketParser` did not know its role, and `testServerRejectsLinesBeforeVersion`
went red — correctly, a client is not allowed to send a preamble. The parser now
takes `isServer` with **no default**, as Apple's does; a server treats the first
line as the version and `validateBanner` rejects it downstream, which is the
outcome that test pins. Two existing tests had asserted the preamble as part of
the version string; their names already described tolerance, only the expected
value was wrong.

### macSCP side

`Package.swift` carries a root dependency on the fork, `exact: "0.3.7"`, and
`macSCPCore` names the `NIOSSH` product. `Package.resolved`: identity
`swift-nio-ssh` → NoiXdev, **0 occurrences of Wellz26**. Build complete.

### The correction

The cherry-pick report above says the override resolved with *no* warning about
colliding URLs. **That was wrong.** `swift build` prints:

> warning: 'citadel': Conflicting identity for swift-nio-ssh: dependency
> 'github.com/wellz26/swift-nio-ssh' and dependency 'github.com/noixdev/swift-nio-ssh'
> both point to the same package identity 'swift-nio-ssh'. […] This will be
> escalated to an error in future versions of SwiftPM.

Measured against the CI gate: it counts only lines shaped `file:line:col: warning:`
(`.github/workflows/ci.yml`, the "Warning gate" step), and this one has no such
prefix — **CI does not count it**. So the override holds today, with an announced
expiry. When SwiftPM escalates, the choice returns: fork Citadel too, or get
Citadel upstream to move off Wellz26. Neither is done here; this entry is where
that day starts.

### End to end, against the rig

Same scaffold as the morning measurement — a TCP forwarder in front of the
untouched rig sshd, prepending RFC 4253 §4.2 lines — now against the fork:

| target | morning (Wellz26 0.3.6) | now (NoiXdev 0.3.7) |
|---|---|---|
| direct | connects | connects |
| transparent forwarder | connects | connects |
| 1 preamble line | `invalidExchangeHashSignature` | **connects** |
| 3 preamble lines | `invalidExchangeHashSignature` | **connects** |

Then the whole gated suite with `MACSCP_ITEST=1` — SSH, agent auth,
checksums, S3, WebDAV, cross-backend — with the new transport under all of
it: **3427 tests in 302 suites, 0 failures**, 71.7 s.

The scaffold was throwaway and is removed again. A permanent regression test
still needs the forwarder as part of the Docker rig — unchanged from the
morning entry, and still to be designed rather than bolted on.

---

## Measured 2026-09-01 (evening) — "are all security patches in the fork?"

The maintainer asked whether every security patch could go into the fork
while it was open. Measured rather than assumed:

**Published advisories for apple/swift-nio-ssh: exactly one.**
GHSA-998x-vgvp-xwpc (critical, 2026-07-17, patched in 0.14.1) — the ECDSA
mpint fix already cherry-picked as `b098395`. There is no second advisory.

**Everything else Apple has that the fork lacks:** merge-base `b0591e4`
(2022-04-21), 91 commits, all read by subject and the protocol-relevant ones
by diff. 85 of them are CI, docs, benchmarks, Swift-version floors, Sendable
annotations, Android and allocation limits. Six touch the protocol path:

| Apple | what | verdict |
|---|---|---|
| `7733e7e` 0.7.0 | no window update after local close | **taken** as `0395d9f`, test adapted to this fork's 1<<17 window. Red without the guard is a **crash**: `Sent channel window adjust on channel in invalid state` |
| `db57f32` 0.7.1 | `moveWriterIndex` past capacity in two places | **ported by hand** as `4cf1748` (cherry-pick conflicts with a refactor the fork never took); red = signal 5 |
| `baa05dc` 0.6.1 | AES-GCM sealed box from combined bytes | **ported by hand** as `d58f304`, Sources only |
| `ded5e5c` 0.8.0 | client-mode version parsing | **already covered** by `089d3ec` — same mechanism (`isServer`), this fork's own code |
| `c99a20b` | `dup()` of pipe descriptors | server example target only; macSCP does not build it — **not taken** |
| `a48586f` 0.5.0 | encryptPacket refactor | no fix in it — **not taken** |

Not taken either, with reasons measured earlier: `8257bc4` 0.14.0 guards a
server-only branch; `6d576c8`/`73d8f68` 0.15.0 buffer and packet-size limits
exist independently in the fork; `3ec2814` 0.15.0 limits client auth
attempts on the server side.

**Result:** tag **`0.3.8`**, fork suite 361 tests / 0 failures. `citadel2`
fast-forwarded to it.

One correction to how this was done: two of the three commits were first
written with a claim of a red test run that had not actually been observed —
a grep that matched nothing, read as "no failure". Both were rewritten before
anything was pushed, with the red that was then really seen (a trap, not an
assertion). A commit message is a measurement record too.

## Measured 2026-09-02 — RSA host keys need one fork change

Spike plan `../plans/2026-09-02-rsa-host-key-spike.md`; probes kept as
patches in the plan's workspace, nothing committed (verdict (b)). Every
error below is `String(reflecting:)` output; every server line is from
`/config/logs/openssh/current` inside the rig container (the linuxserver
image does not put sshd's per-connection lines on `docker logs`).

| route | registered | client offer (sshd's log) | result |
|---|---|---|---|
| 1 | Citadel's `ssh-rsa` pair (SHA-1) | `ssh-ed25519,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,ecdsa-sha2-nistp521,ssh-rsa` | `NIOSSHError.keyExchangeNegotiationFailure` — the server offers only `rsa-sha2-512,rsa-sha2-256`; registration itself works |
| 2 | an `rsa-sha2-512` pair (PKCS#1 v1.5 over SHA-512 via `_CryptoExtras`) | negotiated, no rejection line | `NIOSSHError.unknownPublicKey: ssh-rsa` — the blob lookup keys on the blob's own prefix; the parser was never called |
| 2b | both pairs | negotiated | blob parsed once, then `NIOSSHError.invalidHostKeyForKeyExchange: Expected rsa-sha2-512, got ssh-rsa` — the identity check compares blob type to negotiated name |

So NIOSSH's `NIOSSHPublicKeyProtocol.publicKeyPrefix` serves as the
offered host-key algorithm name (line numbers as of fork tag 0.3.8,
`d58f304` — 0.3.9 moves them: `SSHKeyExchangeStateMachine.swift:555-559`,
`NIOSSHPublicKey.swift:206-208`), the identity check
(`SSHKeyExchangeStateMachine.swift:254-256`), the blob lookup
(`NIOSSHPublicKey.swift:456`) and the `K_S` re-serialisation
(`NIOSSHPublicKey.swift:400-402`). RFC 8332 needs the first two to say
`rsa-sha2-512` while the last two say `ssh-rsa`. **The fork change:** a
`static var hostKeyAlgorithmNames: [String]` on the protocol, defaulting
to `[publicKeyPrefix]`, consulted by the offer and the identity check
only.

Not reached: whether the exchange hash then matches (the `K_S` write
path was read, not exercised), and the `_CryptoExtras` verification
itself (its log stayed empty in every run — Task 3 of the follow-up plan
must prove it, not assume it). Also measured: Citadel's
`SSHAlgorithms.publicKeyAlgorihtms` cannot be populated from a `.v6`
target without two `Sendable` warnings; the probes registered through
`NIOSSHAlgorithms.register` directly (same registry, `Client.swift:43-56`).
The registry is process-global with no public undo, so each probe was
env-gated and run alone.

## Done 2026-09-02 — the second fork: Citadel, and it starts at zero distance

**`https://github.com/NoiXdev/Citadel`**, forked from `orlandos-nl/Citadel`
(`gh` reports `isFork: true`, parent `orlandos-nl/Citadel`). Branch `noix`
at tag **`0.12.1`** = `ae8562f`, which is the revision macSCP's
`Package.resolved` already pinned. The fork's default branch is untouched
and `noix` carries no commits of its own yet.

### The measurement that shaped the task

`git log --oneline 0.12.1..upstream/main` is **empty**. `upstream/main` *is*
the `0.12.1` tag — same SHA, `git rev-list --count` = 0 — and its tip is
dated 2026-04-04. `0.12.1` is also the newest tag. Upstream has not moved in
five months.

So the classification the fork record for NIOSSH needed — 91 commits
triaged, one advisory chased — has **zero rows** here. There is no upstream
drift to inherit, no advisory backlog, no divergence to maintain. That is
the opposite of the NIOSSH situation and it should be re-measured before any
future rebase, not assumed to still hold.

| class | count |
|---|---|
| security | 0 |
| correctness | 0 |
| feature | 0 |
| noise | 0 |

Thirteen unmerged branches exist upstream (`feature/ssh-server`, several
`jo/*`, one dependabot). None was triaged — they are work-in-progress and
out of scope.

### Why the fork exists: PR #135

`orlandos-nl/Citadel#135`, "Add RFC 8332 rsa-sha2-256 / rsa-sha2-512
signature algorithms", by `mburlac`. **OPEN, `mergedAt: null`**, created
2026-07-25, **0 reviews, 0 comments** after 39 days against a repository
whose `main` has been still for five months. Waiting for the merge is not a
plan; that is what the fork is for.

Distance to `0.12.1`: **zero.** The PR branches directly off `ae8562f`.

| check | result |
|---|---|
| `git merge-base pr135 0.12.1` | `ae8562f` — the tag itself |
| `git cherry-pick -n 0d0b839 9f55d61` | exit 0, **0 conflicts** |
| `git apply --check` of the PR diff | exit 0 |
| `swift build --target Citadel` | complete, **0 warnings** naming either PR file |
| `swift test --filter RSASHA2` | **6 tests, 0 failures** |

Files: `RSASHA2.swift` (+166, new), `SSHAuthenticationMethod.swift` (+39/-2,
the two deletions are whitespace), `RSASHA2Tests.swift` (+109, new), and
`Package.resolved` — the last is pure v1→v2 format churn plus a
`Joannis`→`Wellz26` URL rename **at an unchanged revision**, and SwiftPM
ignores a dependency's own lockfile. Drop that hunk when cherry-picking.
**No `RSA.swift` change**: the PR is additive and leaves the SHA-1 `ssh-rsa`
path exactly as it was.

### The constraint, and the one keyword that decides it

The plan requires that no SHA-1 signature leaves the app. PR #135 hashes
with `SHA512`/`SHA256` into `RSA_sign` under `NID_sha512`/`NID_sha256` and
emits the `rsa-sha2-512` / `rsa-sha2-256` prefixes — correct on both counts.
But `rsaSHA2(username:privateKey:includeSHA1Fallback:)` defaults
`includeSHA1Fallback` to **`true`**, appending a legacy `ssh-rsa` offer.

That offer is not a harmless advertisement. swift-nio-ssh signs at offer
time — `UserAuthenticationMethod.swift:216`, `let signature = try
privateKeyRequest.privateKey.sign(dataToSign)` — with no two-phase probe, so
a rejected SHA-2 offer is followed by a real SHA-1 signature on the wire.
**macSCP must pass `includeSHA1Fallback: false`, and pin it with a test**,
because the safe value is not the default.

Unreproduced, and the claim that matters most: RFC 8332 has the userauth
algorithm name differ from the key blob's type (`rsa-sha2-512` vs
`ssh-rsa`), while swift-nio-ssh writes both from one `publicKeyPrefix`. The
PR argues OpenSSH accepts the result because it resolves the blob type by
name, and reports a live test against Alpine OpenSSH 9.x. We have not
verified it. It decides whether authentication actually works, so it is the
first thing to test against the rig.

### Why not write the signer ourselves

The option considered was a ~40-line `rsa-sha2-512` signer in macSCP instead
of a fork. **It cannot be written there.** Signing needs the private
exponent, and `RSA.swift:171` declares it `internal` with no public getter —
`PublicKey.rawRepresentation` yields `e` and `n`, never `d`. The
alternatives are to write the same lines *inside* the fork (the cherry-pick,
minus tests and attribution, plus our own bugs) or to reimplement
`openssh-key-v1` in macSCP: `OpenSSHKey.swift` is 466 lines, `enum OpenSSH`
is `internal` so none of it is reusable, and it would mean rewriting the
aes-ctr ciphers and the bcrypt KDF to keep passphrase-protected keys
working.

### Scope this fork does not yet cover

`OpenSSH.KeyType` in 0.12.1 has exactly two cases, `ssh-rsa` and
`ssh-ed25519`. ECDSA is absent entirely.

| | parse from file | sign |
|---|---|---|
| ed25519 | public API, works today | works |
| RSA | public API, works today (`init(sshRsa:decryptionKey:)`) | SHA-1 only — the gap PR #135 fills |
| ECDSA | **missing** | already in NIOSSH: `NIOSSHPrivateKey(p256Key:)`/`(p384Key:)`/`(p521Key:)` are public |

So the ECDSA half needs **only a parser**, not a signer — a third `KeyType`
case and an `OpenSSHPrivateKey` conformance for the three curves. That is a
separate fork patch and a separate task, not part of the cherry-pick.

## Done 2026-09-02 (evening) — fork tag 0.3.9, and macSCP verifies RSA host keys

Plan `../plans/2026-09-02-rsa-host-key-fork-change.md`.

**Fork:** `d756a67` on `citadel2`, tag **`0.3.9`** ("hostKeyAlgorithmNames
for custom host-key types"). `NIOSSHPublicKeyProtocol` gained
`static var hostKeyAlgorithmNames: [String]` with a protocol-extension
default of `[publicKeyPrefix]`; three sites read the names instead of the
prefix — the KEXINIT offer, the client's identity check on the KEX reply,
and `knownAlgorithms` (as a union; the prefix stays). Blob lookup and the
`K_S` write are untouched. Red run observed: 5 tests, 3 failing, the
offer listing `blob-x` where `alg-x` was expected; each changed line was
mutation-checked alone. Green: 368 tests, 0 failures (361 before the new
class). Not changed, confirmed: the signature blob is matched on
`signaturePrefix`, which RFC 8332 types with the negotiated name already.
Left as is: user-auth public keys still compare algorithm name and key
prefix strictly (`SSHMessages.swift:688`/`:759` at 0.3.9) — the place to
look if RSA client-key auth without `ssh-rsa` blob typing is ever
wanted; certified custom keys do not inherit their base type's names.
The `soundness.sh` formatter was not run (no `swiftformat` here).
Upstream PR candidate: this change, against `apple/swift-nio-ssh`.

**macSCP:** `e084d69` (fork `exact: "0.3.9"`, `_CryptoExtras` for Core),
`38b8781` (`Sources/macSCPCore/SSH/RSASHA2HostKey.swift`: the pair, and
`registerOnce()` before both `SSHClient.connect` sites), `3e66d86` (the
RSA row flips; a tampered-RSA hard stop). At that point: unit suite
`RSASHA2HostKeyTests` 9/9; gated `HostKeyTypeIntegrationTests` 4/4; full
gated run 3489/3489 on the first attempt. After the fix round below the
unit suite is 13/13 and the full run 3503 (the difference of 14 is the
four modulus-floor tests, the new registration guard's tests, and the
re-anchored timeout guard's two replaced tests — the fix round's own
report says "+13", which is off by one). Planted defects, measured after the compile-red:
SHA-512→SHA-256 red in 5 of 9; signature-type guard removed 1 of 9;
`write(to:)` re-encoding the mpints (the `K_S` path the spike could only
read) 2 of 9; `hostKeyAlgorithmNames = [publicKeyPrefix]` 1 of 9.
Fix round after the task review (`14f3ed3`, `08d5ef3`): a modulus below
1024 bits — OpenSSH's own `RequiredRSASize` default — is a parse failure,
never a key (bits counted from the mpint's minimal encoding, not its byte
length: a 1016-bit probe pads to 128 bytes and would pass a byte-length
floor); both `SSHClient.connect` sites now go through one private dial
helper that registers the algorithms first, pinned by a guard whose
ordering check is whole-line equality on the statement (a `defer`-wrapped
probe had passed a looser one); the stale claim in
`HostKeyValidation.swift` that the fork was not a package dependency is
gone. Port 2235 now records `ssh-rsa`, blob fingerprint
`SHA256:Cx5M3QK63oku6+YGU7DMU6ZaLCZOSdExs7CzpgLm72Q` (3072-bit), identical
to `ssh-keyscan`'s reading. Only `rsa-sha2-512` is offered. The jump
target hop is covered by reasoning (the hop registers first), not by a
measurement — the rig has no jump path to 2235.

## Done 2026-09-02 — Citadel fork tags `0.12.1-noix.1` and `.2`, and macSCP on them

- **`0.12.1-noix.1`** (`d228998` on `noix`): upstream PR #135 cherry-picked
  with `-x` (`ac2ac0e`, `2ec2751`; author Mihai Burlac kept; the PR's
  `Package.resolved` hunk dropped), plus our own `fix(rsa): no SHA-1
  fallback unless asked for` — `includeSHA1Fallback` defaults to `false`,
  pinned by a test whose red run showed the offer list
  `["rsa-sha2-512","rsa-sha2-256","ssh-rsa"]` under upstream's default.
  Fork suite: 43 tests, one pre-existing failure (`testSFTPUpload`
  hardcodes port 2222, held by macSCP's rig).
- **`0.12.1-noix.2`** (`b1f1dfd`): ECDSA private keys from the
  `openssh-key-v1` container — `P256/P384/P521.Signing.PrivateKey
  .init(sshEcdsa:decryptionKey:)` (Data and String), `OpenSSHKeyTypeMismatch`;
  `d` left-padded to 32/48/66 bytes; 13 tests, the parsed `d` reproduces
  the container's `Q`; a defaulted `keyTypeMismatch(found:)` protocol
  requirement is the fork's second divergence a rebase must re-apply.
- **Fork review** (Spec ✅, Quality approved): the userauth request types
  the key blob with the algorithm name — measured accepted by OpenSSH
  10.3 in macSCP's Task 4 (see `2026-08-31-backlog-ssh-key-formats.md`);
  `sk-*`/`ssh-dss`/cert files still throw an opaque `InvalidOpenSSHKey`
  (macSCP names those types before parsing, so it did not matter).
- **macSCP:** `Package.swift` → `https://github.com/NoiXdev/Citadel.git`
  `exact: "0.12.1-noix.2"` (`eaa5baa`; an incidental swift-log
  1.14.0→1.15.0 bump rode along in `Package.resolved`, named in the
  commit). `swift test` in the fork rewrites `Package.resolved` v1→v2 on
  every run — restore before every commit there.
- **Upstream PR candidates:** the SHA-1-fallback default flip and the
  ECDSA parser, against `orlandos-nl/Citadel` (dormant since 2026-04-04
  as of this measurement).

