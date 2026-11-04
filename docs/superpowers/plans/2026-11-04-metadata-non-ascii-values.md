# Non-ASCII Metadata Values Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A person can type any text into a custom metadata value — umlauts,
CJK, emoji — and macSCP writes it, reads it back, and confirms it.

**Architecture:** The wire form and the user-facing form are separated at one
boundary. `ObjectMetadata.custom` holds what the person typed, everywhere, at
every layer. `S3FileSystem` encodes to an RFC 2047 encoded-word on the way
out and decodes on the way in, so every header value it signs is pure ASCII
and the 403 cannot arise. The three standard headers are not encoded — they
are token-valued by their own specifications — and are refused with a named
message instead.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v6)`, macOS 15, SwiftPM, Swift
Testing. No new dependency: `Data.base64EncodedString()` and
`Data(base64Encoded:)` are Foundation.

**Spec:** no separate spec. The authority is the measurement record: the
`docs/BACKLOG.md` row whose title begins "A non-ASCII custom metadata value
is reported to the user as a credentials problem", and the gated cases in
`Tests/macSCPCoreTests/S3MetadataGatedTests.swift` that currently assert the
403 as the record of the defect. The maintainer's decision of 2026-11-04 is
**emit and parse RFC 2047**, chosen over rejecting non-ASCII and over
percent-encoding.

## Global Constraints

- RFC 2047 applies to `x-amz-meta-*` values ONLY. `content-type`,
  `cache-control` and `content-disposition` are token-valued per RFC 9110 and
  RFC 6266; an encoded-word in them is not the standard and a strict store may
  refuse it. They get a refusal, not an encoding.
- `ObjectMetadata.custom` carries the DECODED form at every layer above the
  transport. Nothing outside `S3FileSystem` ever sees an encoded-word.
- The decoder is lossless for anything that is not an encoded-word, including
  raw non-ASCII: a value another tool wrote without encoding must read back
  unchanged. Measured 2026-11-04: curl's own SigV4 writes raw UTF-8 and
  RustFS answers 200, so such values exist in the wild.
- Every user-facing string goes through `L10n.string`/`L10n.text` (App) or
  `CoreL10n.string` (Core), in all four catalogues `en`, `de`, `fr`, `pl`,
  German in du-form. At this plan's base each holds 24 `"s3.metadata.` keys
  with byte-identical key sets.
- Tests never block the cooperative pool: every wait is an `await`. No
  wall-clock ceiling; any `.timeLimit` is `.minutes(5)`.
- No secret, key, credential, token or endpoint in a test name, a failure
  message, a log or a `reason:` string. `#expect` reports the source text of
  its expression.
- The gated rig suite runs only behind `MACSCP_ITEST=1`, and the rig is
  started ONLY from the main checkout at `/Users/noidee/macSCP`. The buckets
  `macscp-seed`, `macscp-second` and `macscp-probe-lock` are not ours: no
  writes, no deletes, no configuration changes, and no retention of any kind
  on a bucket the suite means to delete.
- `swift build` / `swift test` take no `--build-system` flag.

## Review Focus

Five input classes this plan's own tasks would otherwise not exercise, most
likely to bite first. Each gets its test in the task that owns the code.

1. **A value the person types that already looks like an encoded-word** —
   literally `=?UTF-8?B?SGk=?=`. Encoding it again double-encodes; decoding on
   read then yields `Hi`, which is not what they typed. Task 1 pins the
   decision: such a value is encoded as a whole, so it round-trips literally.
2. **A store that returns the value raw rather than encoded.** RustFS was
   measured returning an encoded-word; another store may not. The read-back
   comparison must find both forms equal to what was sent. Task 2's test.
3. **A custom NAME with non-ASCII**, already refused by `headerNameIsToken` —
   but with the generic reason, so the person is not told which field. Task 3.
4. **A value long enough that one encoded-word is large.** RFC 2047 caps an
   encoded-word at 75 characters and expects longer text to be split into
   adjacent words. Whether any store cares is **unmeasured**. Task 1 emits one
   word of any length and the decoder accepts adjacent words; Task 4 measures
   a long value against the rig.
5. **An empty value and a whitespace-only value.** Already measured kept and
   kept empty (Task 7a, 2026-11-04); the encoder must not turn `""` into an
   encoded-word, which would change a measured behaviour. Task 1.

---

## File Structure

- Create `Sources/macSCPCore/S3/RFC2047.swift` — the codec, with no knowledge
  of metadata or HTTP. Beside `S3ACLXML.swift`, which is the project's pattern
  for a wire-format parser owned by the S3 backend.
- Create `Tests/macSCPCoreTests/RFC2047Tests.swift`.
- Modify `Sources/macSCPCore/S3/S3FileSystem.swift` — `replacementHeaders(for:)`
  encodes custom values; `objectMetadata(from:)` decodes them; the three
  standard headers refuse non-ASCII.
- Modify `Sources/MacSCPAppKit/ObjectMetadataSheet.swift` — `DraftProblem`
  gains the cases that name a field whose value cannot be sent.
- Modify the four `Localizable.strings`.
- Modify `Tests/macSCPCoreTests/S3MetadataGatedTests.swift` — the cases that
  assert the 403 become the round-trip cases.
- Modify `docs/BACKLOG.md` — close the row, with the measurement.

---

### Task 1: The RFC 2047 codec

**Files:**
- Create: `Sources/macSCPCore/S3/RFC2047.swift`
- Test: `Tests/macSCPCoreTests/RFC2047Tests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum RFC2047` with
  `static func encodedWord(_ value: String) -> String` and
  `static func decoded(_ value: String) -> String`. Both total: neither throws,
  neither returns nil.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anASCIIValueIsReturnedUnchanged() {
    #expect(RFC2047.encodedWord("max-age=60, must-revalidate")
        == "max-age=60, must-revalidate")
    #expect(RFC2047.encodedWord("") == "")
    #expect(RFC2047.encodedWord("   ") == "   ")
}

@Test func aNonASCIIValueBecomesOneBase64EncodedWord() {
    #expect(RFC2047.encodedWord("Jahresübersicht")
        == "=?UTF-8?B?SmFocmVzw7xiZXJzaWNodA==?=")
}

@Test func anEncodedWordDecodesToTheBytesItCarries() {
    #expect(RFC2047.decoded("=?UTF-8?B?SmFocmVzw7xiZXJzaWNodA==?=")
        == "Jahresübersicht")
}

@Test func theQEncodingIsDecodedToo() {
    #expect(RFC2047.decoded("=?UTF-8?Q?Jahres=C3=BCbersicht?=") == "Jahresübersicht")
    #expect(RFC2047.decoded("=?UTF-8?Q?a_b?=") == "a b")
}

@Test func adjacentEncodedWordsAreJoined() {
    #expect(RFC2047.decoded("=?UTF-8?B?SmFocmVz?= =?UTF-8?B?w7xiZXJzaWNodA==?=")
        == "Jahresübersicht")
}

/// Review Focus 2: a store that answers with the raw bytes, and any value
/// that is simply not an encoded word, survives the decoder untouched.
@Test func anythingThatIsNotAnEncodedWordPassesThrough() {
    #expect(RFC2047.decoded("Jahresübersicht") == "Jahresübersicht")
    #expect(RFC2047.decoded("attachment; filename=\"report.pdf\"")
        == "attachment; filename=\"report.pdf\"")
    #expect(RFC2047.decoded("=?UTF-8?B?not valid base64!?=")
        == "=?UTF-8?B?not valid base64!?=")
    #expect(RFC2047.decoded("=?SHIFT_JIS?B?gqA=?=") == "=?SHIFT_JIS?B?gqA=?=")
}

/// Review Focus 1: what the person typed comes back, even when what they
/// typed looks like an encoded word. The encoder treats it as text.
@Test func aValueThatLooksLikeAnEncodedWordRoundTripsLiterally() {
    let typed = "=?UTF-8?B?SGk=?="
    let round = RFC2047.decoded(RFC2047.encodedWord(typed))
    #expect(round == typed)
}

/// Review Focus 4: one word of any length, and the round trip holds.
@Test func aLongValueRoundTrips() {
    let typed = String(repeating: "übersicht-日本語-", count: 40)
    #expect(RFC2047.decoded(RFC2047.encodedWord(typed)) == typed)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter RFC2047Tests`
Expected: FAIL, `cannot find 'RFC2047' in scope`.

- [ ] **Step 3: Implement `enum RFC2047` in `Sources/macSCPCore/S3/RFC2047.swift`**

`encodedWord(_:)` returns the value unchanged when every unicode scalar is
below 0x80; otherwise `"=?UTF-8?B?" + Data(value.utf8).base64EncodedString() + "?="`,
one word regardless of length. Note in a comment that RFC 2047's 75-character
limit is deliberately not applied, that no store has been measured caring, and
that the decoder accepts adjacent words so a value split by another tool still
reads.

`decoded(_:)` scans for `=?charset?enc?text?=` runs; a run whose charset is not
UTF-8 (case-insensitively), whose encoding is not `B` or `Q`, or whose payload
does not decode, is left exactly as it stands. `B` is base64; `Q` is
quoted-printable with `_` meaning space. Adjacent words separated only by
whitespace join with nothing between them, per RFC 2047 section 6.2; a
non-encoded run between two words is kept verbatim.

Write the two functions as total functions — a codec that throws would push a
decision about malformed input into every caller, and the decision is already
made here: leave it alone.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `swift test --filter RFC2047Tests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/S3/RFC2047.swift Tests/macSCPCoreTests/RFC2047Tests.swift
git commit -m "feat(core): an RFC 2047 codec for metadata values"
```

---

### Task 2: The wire boundary

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` — `replacementHeaders(for:)`,
  `objectMetadata(from:)`
- Test: `Tests/macSCPCoreTests/S3ObjectMetadataTests.swift`

**Interfaces:**
- Consumes: `RFC2047.encodedWord(_:)`, `RFC2047.decoded(_:)` from Task 1.
- Produces: no signature changes. The invariant it establishes is the one
  later tasks rely on: `ObjectMetadata.custom` holds decoded text.

- [ ] **Step 1: Write the failing tests**

Against the existing fake transport, so no rig is needed:

```swift
@Test func aNonASCIICustomValueIsSentAsAnEncodedWord() async throws
@Test func anEncodedWordInTheHeadAnswerReachesTheCallerDecoded() async throws
/// Review Focus 2.
@Test func aRawNonASCIIValueInTheHeadAnswerReachesTheCallerUnchanged() async throws
/// The read-back confirms, which is what the person sees.
@Test func aNonASCIIValueWrittenAndReadBackIsConfirmed() async throws
```

The first asserts the header the transport was handed is ASCII — compute the
`Bool` before the expectation, because the expectation's source text is
reported on failure and the point of this test is a value with non-ASCII in
it.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter S3ObjectMetadataTests`
Expected: FAIL — the sent header still carries raw UTF-8, and the read-back
comparison still compares an encoded-word against what was typed.

- [ ] **Step 3: Encode in `replacementHeaders(for:)` and decode in `objectMetadata(from:)`**

In `replacementHeaders(for:)`, the custom loop puts
`RFC2047.encodedWord(value)` into `headers[...]`, and `headerValueIsSendable`
is checked against the ENCODED value, which is what the signer will see.
Leave the three standard headers untouched here; Task 3 owns them.

In `objectMetadata(from:)`, each custom value becomes `RFC2047.decoded(value)`.
The three standard headers are not decoded — they were never encoded.

Write beside the custom loop why the standard headers differ, in prose rather
than by quoting the code: this file is scanned by source-reading guards and a
comment that quotes code is indistinguishable from code to a scanner.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `swift test --filter S3ObjectMetadataTests` — Expected: PASS.
Then `swift test` and expect no other suite to change.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Tests/macSCPCoreTests/S3ObjectMetadataTests.swift
git commit -m "fix(core): a custom metadata value is encoded on the wire and decoded on the way back"
```

---

### Task 3: The three standard headers refuse, by name

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` — the standard-header loop
- Modify: `Sources/MacSCPAppKit/ObjectMetadataSheet.swift` — `DraftProblem`
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/S3ObjectMetadataTests.swift`,
  `Tests/macSCPAppKitTests/ObjectMetadataSheetTests.swift`

**Interfaces:**
- Consumes: the invariant from Task 2.
- Produces: a `DraftProblem` case naming a field whose value cannot be sent,
  which the sheet renders before Core is reached.

- [ ] **Step 1: Write the failing tests**

Core: a non-ASCII `contentType`, `cacheControl` or `contentDisposition` is
refused and nothing is written. App: `draftProblem` names the field and the
reason BEFORE a save is attempted, so Save is refused rather than failing —
this is the F4 gap for these three fields, and the sheet's design elsewhere is
to say which pair and why.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter 'S3ObjectMetadataTests|ObjectMetadataSheetTests'`
Expected: FAIL — today the value reaches Core, which refuses with the generic
reason and no field named.

- [ ] **Step 3: Require ASCII for the three, and name the field in the sheet**

In Core, the standard-header loop requires the value to be ASCII as well as
sendable. In the App, `DraftProblem` gains the case and
`ObjectMetadataLines` the sentence, in all four catalogues, German du-form,
through `L10n`. The sentence says which field and that it takes plain text —
never the mechanics of header encoding, which the person did not type.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `swift test --filter 'S3ObjectMetadataTests|ObjectMetadataSheetTests'` — Expected: PASS.
Then check the four catalogues still hold byte-identical key sets.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift Sources/MacSCPAppKit Tests
git commit -m "fix(app): a standard header that cannot carry the text says which field it is"
```

---

### Task 4: The rig measures the round trip

**Files:**
- Modify: `Tests/macSCPCoreTests/S3MetadataGatedTests.swift`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: the measurement record that replaces the one asserting the 403.

- [ ] **Step 1: Start the rig FROM THE MAIN CHECKOUT**

Run, from `/Users/noidee/macSCP` and nowhere else:
`docker compose -f docker/test-server/compose.yml up -d`
Expected: the S3 store answers on 127.0.0.1:19000.

- [ ] **Step 2: Flip the cases that assert the defect**

The case that asserts `copy=403 refusalCode=SignatureDoesNotMatch` becomes the
round trip: write `Jahresübersicht-日本語`, `HEAD` it back, and assert the
decoded value equals what was sent. **Withdraw the old assertion's comment
verbatim** — it records a defect that no longer exists, and this project's
rule is that a correction quotes what it replaces. Add the long-value case
from Review Focus 4, and a case that writes a value with curl's own SigV4
raw — the pass-through path of Review Focus 2 — if that can be done from the
suite; if it cannot, say so in the report rather than asserting it.

- [ ] **Step 3: Run the gated suite**

Run: `MACSCP_ITEST=1 swift test --filter S3MetadataGatedTests`
Expected: PASS, with the elapsed time printed and no figure asserted.

- [ ] **Step 4: Run the plain suite and prove the gated cases do not run**

Run: `swift test`
Expected: PASS, the gated suite reported skipped, and a `grep` for the suite's
own log prefix printing 0 with exit 1.

- [ ] **Step 5: Commit**

```bash
git add Tests/macSCPCoreTests/S3MetadataGatedTests.swift
git commit -m "test(core): the rig measures a non-ASCII metadata value round-tripping"
```

---

### Task 5: Closeout

**Files:**
- Modify: `docs/BACKLOG.md`
- Modify (separate repository, separate branch, NOT pushed):
  `/Users/noidee/_dev/noix-docs-s3-metadata-and-acls/src/content/docs/macscp/guide/s3-metadata.md`

**Interfaces:**
- Consumes: Task 4's measurement.

- [ ] **Step 1: Close the backlog row**

Correct the non-ASCII row in place, quoting verbatim every passage it
withdraws, and carry Task 4's measurement with the command that produced it.
Both layers the row names are closed: the signing, because an encoded-word is
ASCII, and the read-back, because both sides are decoded. The row's note that
the defect reaches `content-type`, `cache-control` and `content-disposition`
closes differently — by a named refusal, not by encoding — and the row must
say which of its two halves closed which way. Every row is one physical line
and a cell takes no pipe at all.

- [ ] **Step 2: The user documentation**

The page's only character rule today constrains the custom NAME. Add what is
now true of a VALUE — that it may carry any text — and say nothing about
encoded-words, which is mechanism the reader does not need. Public text: no
tech-stack terms. Work on the existing branch
`docs/macscp-s3-metadata-and-acls` in that worktree; `npm run build` and
`npm run check` must both pass. **Do not push or merge** — that is the
maintainer's in a shared repository.

- [ ] **Step 3: Commit**

```bash
git add docs/BACKLOG.md
git commit -m "docs(backlog): the non-ASCII metadata row closes, both layers measured"
```

---

## Self-Review

**Spec coverage.** The authority is the backlog row and the gated cases. The
row names two layers (signing, read-back) and three extra field classes. Tasks
1-2 close both layers for custom values; Task 3 closes the three field classes
by refusal; Task 4 replaces the record; Task 5 closes the row and the docs.
The row's "no typing needed" path — an object that already carries such a
value makes an unrelated edit fail, because `draftMetadata` resends every
field — is closed by Task 2 without its own task: the value is decoded on
read, so it is re-sent encoded. Task 2's read-back test is the one that proves
it, and it is named in that task.

**Step scan.** Each step is one action with a checkable result. Task 1 carries
its tests as code because the exact encoded forms are the decisions; Tasks 2-4
carry test names and the assertion in prose, because the fake transport and the
rig fixtures already exist and their shapes are not this plan's to decide.

**Type consistency.** `RFC2047.encodedWord(_:) -> String` and
`RFC2047.decoded(_:) -> String` are used under those names in Tasks 2 and 4.
`ObjectMetadata.custom` is `[String: String]` throughout and holds decoded
text above the transport.

**Review Focus.** Five classes, each with its test placed: 1 and 4 and 5 in
Task 1, 2 in Tasks 1 and 2, 3 in Task 3.

**Proportion.** Five tasks, one new 2-function file, four modified files plus
catalogues. The plan is longer than the diff will be, which is right for work
whose risk is a wrong wire format rather than a hard algorithm — the decisions
are what needed writing down.
