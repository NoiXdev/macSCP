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
