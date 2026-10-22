# Task 3 report: CORS with macSCP's own validation

Status: DONE_WITH_CONCERNS. Commit: fd025c88 (one commit on s3-bucket-settings, on top of fcde650d; not pushed).

## What changed
- Sources/macSCPCore/RemoteFS/S3BucketSettings.swift: protocol gains `cors(ofBucket:)` and `setCORS(_:ofBucket:)`; adds `CORSRule` (Sendable, Equatable, Identifiable; `id: String?`), `CORSRule.allowedMethodNames` (GET, PUT, POST, DELETE, HEAD), `CORSRule.validate()` and `CORSValidation`.
- Sources/macSCPCore/S3/S3SettingsXML.swift: `parseCORS`, `parseCORSResponse(status:body:path:)`, `corsBody`, and a private `CORSDelegate`.
- Sources/macSCPCore/S3/S3FileSystem.swift: conformance methods; new `static func contentMD5(of:)`; `deleteTree` and `setVersioning` moved onto it (ruling B).
- Tests: new S3CORSTests.swift (24 test cases counting arguments), new S3CORSGatedTests.swift, new Support/S3SettingsFakeTransport.swift; S3BucketSettingsTests.swift and S3BucketSettingsGatedTests.swift lose their private copies of the shared set-up.

## Decisions
- Validation order: no origin, then no method, then each method against the five names (case-sensitive, so `get`, `GET ` and the empty string are refused). First failure wins.
- `setCORS` throws `RemoteFSError.protocolError(reason:)` with an English reason naming the failure. I did NOT add a `RemoteFSFinding` case: that costs a case plus four catalogue sentences, and a UI that wants a localized message calls `validate()` itself. Say if you want a finding instead.
- All rules are validated before anything is built, so one bad rule among good ones sends nothing (tested).
- `parseCORSResponse` recognizes absence by the `NoSuchCORSConfiguration` code (status is not consulted, same stance as `S3ErrorCode`), and sends every other non-2xx through `S3FileSystem.mapErrorStatus`. A 404 `NoSuchBucket` is therefore `.notFound`, not nil (tested). It has a `path:` parameter defaulting to "" because the brief's signature had none.
- Parser: order-independent inside a rule; foreign root and non-integer `MaxAgeSeconds` abort with the delegate's own reason (the foreign-root reason string is asserted verbatim); only a CORSRule under the root and a field directly under a rule count (a positive assertion sits beside that negative one); undocumented elements inside a rule are skipped, not refused. Values are trimmed of whitespace.
- `corsBody` uses `S3XMLText.escaped`, so markup in an origin or ID round-trips and a control character throws `.requestBodyUnencodable`. It does not validate, so it stays the exact inverse of `parseCORS`.
- Ruling A: `PUT ?cors` carries a signed `Content-MD5`; the test asserts the literal digest `z5NRbjB3frWWZtwtWBl//w==` of the exact body and that `content-md5` is in the Authorization header.
- Ruling B: `contentMD5(of:)` is the single spelling; it has a literal-value test (`abc` -> `kAFQmDzST7DWlj99KOF/cg==`). The comment in `setVersioning` that said "Same construction as deleteTree" now points at the helper.
- Shared test set-up: `S3SettingsFake` (config, empty listing, `httpResponse(status:)`, `connect(responses:)`) and `S3SettingsRig` (rig config, throwaway bucket name, raw bucket request). No third copy; I migrated Task 2's two test files onto them. The copies in S3FileSystemTests.swift are untouched (different `httpResponse` signature, about a dozen suites use them).

## The FETCH test
`aFetchRuleIsRefusedBeforeAnyRequestReachesTheTransport` (S3CORSTests): records the transport's request count, calls `setCORS` with a `FETCH` rule, asserts `.protocolError` whose reason names `FETCH`, and asserts the count is unchanged. The gated test additionally shows that, against the live rig, the same call throws locally and the stored configuration is still the earlier one; its header says it cannot prove the refusal.

## Red, then green
- Red: with the three source files reverted to HEAD, `swift test --filter S3CORSTests` failed to compile: `cannot find type 'CORSRule' in scope`, `type 'S3SettingsXML' has no member 'corsBody'` / `'parseCORS'` / `'parseCORSResponse'`. Quoted in the commit message. Order was not strict TDD: I wrote the types first, then copied them aside and reverted to take the red, then restored them (restored files compared equal to the copies).
- Green: `swift test --filter S3` -> 403 tests in 56 suites passed (a second run block of 2 tests also passed). `swift test --filter "S3CORSTests|S3BucketSettingsTests|S3BucketSettingsGatedTests|S3CORSGatedTests"` -> 33 tests, 4 suites passed (gated ones skipped without the env).
- Gated: `MACSCP_ITEST=1 swift test --filter "S3CORSGatedTests|S3BucketSettingsGatedTests"` -> both passed against the rig. The full-schema rule round-tripped equal, a fresh bucket read as nil, a FETCH write was refused locally and the stored rule was unchanged, and the throwaway bucket was deleted. `macscp-seed`, `macscp-second` and `macscp-probe-lock` were not touched.
- I did not run the whole suite, so the known `ViewTestabilitySpike` failure was not observed.
- Mutation probes (scripts/mutation-probe, run after the commit on a clean tree, all reported RED with the plant caught; tree clean afterwards): (1) validation gate in `setCORS` replaced by `switch CORSValidation.ok`; (2) the parser's `depth == 3` field test loosened to `>= 3`; (3) `Content-MD5` removed from `setCORS`. I did not record which test names caught each.

## Concerns
1. `setCORS([])` is not specially handled: an empty list sends `<CORSConfiguration/>` and the store decides (AWS rejects it as MalformedXML; I did not measure the rig). Clearing CORS is a DELETE ?cors, which is not in this task. A later task or the UI needs to decide what "no rules" means.
2. docs/BACKLOG.md row about the signed Content-MD5 (around line 279) says each later task confirms the requirement against AWS's own `PutBucketCors` page. I did not fetch that page and relied on ruling A; I did not edit the row. The closeout should update it, noting the request-level test now exists for `PUT ?cors` (`writingIsAPutOfTheRulesWithTheBodysHashAndASignedContentMD5`).
3. `deleteTree`'s doc comment still carries a "Correction:" sentence about `setVersioning` sending the same header; it remains true, I left it.
4. `Identifiable` on `CORSRule` uses the optional `id`, as specified; it is not a usable identity (documented on the type), so a UI list will need its own.
5. No user-docs page written (noix-docs); presumably the plan's closeout task.

---

# Fix round 1 (commit e463802c, on top of fd025c88; not pushed)

Written from `git diff --stat fd025c88 HEAD`: 11 files, 224 insertions, 64 deletions (RemoteFSFinding.swift, S3BucketSettings.swift, four Localizable.strings, S3FileSystem.swift, S3SettingsXML.swift, RemoteFSFindingTests.swift, S3CORSGatedTests.swift, S3CORSTests.swift).

Concerns 1 and 3 above are superseded by this round (1 by I-1; 3 is unchanged and still true).

## I-1: `setCORS([])` performs `DELETE ?cors`
- `setCORS` validates every rule first, then: empty list -> one signed `DELETE` on `{bucket}?cors` (no body, no Content-MD5), otherwise the PUT as before. A non-2xx goes through `sendExpectingSuccess` -> `mapErrorStatus`.
- The asymmetry is documented on `S3BucketSettings.setCORS` (write `[]`, read `nil`; why S3 has no zero-rule configuration), and again at the implementation.
- Measurement, as ruled by the coordinator and independently reproduced by the reviewer: `PUT` of a zero-rule `<CORSConfiguration>` is `400 MalformedXML` with the previous rules untouched; `DELETE ?cors` is `204`, after which `GET` is `404 NoSuchCORSConfiguration`. I did not measure the 400 myself; I did exercise the rest end to end in this round: the gated test writes the rule, reads it, writes `[]`, reads and gets `nil` (passed).
- Unit tests: `writingNoRulesIsADeleteOfTheConfigurationAndNotAPut` (method DELETE, path `/other`, query `cors=`, `httpBody == nil`, exactly one request, none of the recorded requests is a PUT) and `aRefusedRemovalIsMappedThroughTheSharedStatusMapping` (403 -> `.authenticationFailed`).
- `grep -rn "corsBody(\[\])" Tests Sources` still returns nothing, and that is now intended: `setCORS` never builds a body for an empty list, so `corsBody([])` is unreachable from the write path and not pinned.

## I-2: finding case `corsRuleInvalid`
- `RemoteFSFinding.corsRuleInvalid`, payload-free, added to the case list, `Name`, `name`, `messageKey`, `message`, `logSentence`, `readsAsConnectionFailure` (false), and the sample table in RemoteFSFindingTests.swift. Four catalogue sentences (en, de, fr, pl), key `core.finding.corsRuleInvalid`; the German sentence uses no address form. `setCORS` throws `RemoteFSError.finding(.corsRuleInvalid)` for any failing rule, before a request exists; the three English-prose `protocolError` reasons are gone.
- Tests updated to assert the finding for `FETCH` and for a bad rule among good ones, both with the request count unchanged. The existing parity and `noFindingCarriesForeignText` guards cover the new case (full suite green).

## I-3: raw document kept
- New `public struct BucketCORS: Sendable, Equatable { rules: [CORSRule]; rawBody: Data }`. `cors(ofBucket:)` now returns `BucketCORS?` (`nil` still means none configured). `parseCORSResponse` is unchanged and returns `[CORSRule]?`; the conformance wraps it with the body as received.
- Tests: `readingIsAGetOnTheCORSSubresourceOfTheNamedBucket` also asserts `rawBody == answer`; `theRawDocumentKeepsWhatTheParsedRulesDropped` feeds a rule with a `FutureThing` element and asserts the rules lack it while the raw body still contains it. No Task 9 detection is built.

## Minors
- M-1: chose to drop the trim for text values; only `MaxAgeSeconds` is trimmed. The "round-trips any rule" claim is softened: values are kept as written, spaces at either end included. Pinned by `spacesAroundAValueSurviveTheRoundTrip` (id, origin, header with a tab, expose header) and `whitespaceAroundTheNumberIsFormattingAndIsTrimmed`. I made no claim about a literal carriage return, which XML parsers normalise; not measured.
- M-3: `validate()` returns `.noOrigin` for any origin that is empty or only whitespace. `anOriginThatNamesNothingIsNoOrigin` covers `[""]`, `["  "]`, `["https://a.example.com", ""]`, `["\t\n"]`; `realOriginsAreStillAccepted` keeps real origins `.ok`.
- M-2: `corsBody`'s comment now cites section 4 of `docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md` (it lists `ID`, several `AllowedOrigin`, several `AllowedMethod`, `AllowedHeader`, several `ExposeHeader`, `MaxAgeSeconds`) and says the store does not hold it to that order. The AWS page was not fetched in this task and the comment no longer implies it was.
- M-4: corrections to the first report. "24 test cases counting arguments" was wrong: `git show fd025c88:Tests/macSCPCoreTests/S3CORSTests.swift | grep -o '@Test' | wc -l` prints 24, i.e. 24 `@Test` functions, and Swift Testing's own line said "24 tests". Counting parameterized arguments (5 methods + 6 refused methods) gives 22 + 11 = 33 cases, the reviewer's figure. Concern 1 said `setCORS([])` "sends `<CORSConfiguration/>`"; `corsBody` actually emits the XML declaration plus `<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></CORSConfiguration>`. Both are moot now: `setCORS([])` sends a DELETE. Current count: `grep -o '@Test' Tests/macSCPCoreTests/S3CORSTests.swift | wc -l` prints 31 functions, and `swift test --filter S3CORSTests` prints "Test run with 31 tests in 1 suite".
- M-7 disclosure: in the migration onto `S3SettingsFake` (fd025c88), `httpResponse(status:)`'s URL changed from `http://127.0.0.1:9000/other?versioning` (Task 2's private copy) to `http://127.0.0.1:9000/other`. Nothing reads `response.url`, so no test outcome changed, but it is a change to Task 2's fixtures that the first report did not state. I left it as is.

## Tests after the round
- `swift test --filter "S3CORSTests|S3BucketSettingsTests|RemoteFSFinding|LocalizationParity|GermanAddressForm|S3ErrorCode"` -> `Test run with 70 tests in 6 suites passed`.
- `MACSCP_ITEST=1 swift test --filter "S3CORSGatedTests|S3BucketSettingsGatedTests"` -> `Test run with 2 tests in 2 suites passed`, including write-`[]`-then-read-`nil`.
- Full `swift test`: `Test run with 4998 tests in 401 suites passed` for the first run block, and `Test run with 2556 tests in 230 suites failed after 25.992 seconds with 1 issue` for the second. The one failure is `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (ViewTestabilitySpike.swift:202, `off == on`), the known unrelated one. Nothing else failed.

## I-4: the mutation probes, with commands and the harness's own output
All run on the clean tree at e463802c as `scripts/mutation-probe --filter 'S3CORSTests' --label <label> --apply <command>`; `git status --short` was empty after each. Probes 1 to 3 are the earlier probes re-run; their plants are updated only where the code changed (the gate is now a `where` clause). I was not given the reviewer's expectations, so "expected" below is my own, written for each plant from the test I meant to catch it.

1. `--apply "perl -0pi -e 's/for rule in rules where rule\.validate\(\) != \.ok \{/for rule in rules where false {/' Sources/macSCPCore/S3/S3FileSystem.swift"`
   `RESULT: RED — 31 test(s) ran, and the plant was caught by:` aFetchRuleIsRefusedBeforeAnyRequestReachesTheTransport(), oneBadRuleAmongGoodOnesSendsNothing(). Expected both: match.
2. `--apply "perl -0pi -e 's/inRule && depth == 3/inRule && depth >= 3/' Sources/macSCPCore/S3/S3SettingsXML.swift"`
   RED, caught by onlyAFieldDirectlyUnderARuleCounts(). Expected: match.
3. `--apply "perl -0pi -e 's/            extraHeaders: \[\"Content-MD5\": Self\.contentMD5\(of: body\)\],\n            body: body, payloadHash: SigV4Signer\.hexSHA256\(body\), config: config\)\n        try await sendExpectingSuccess\(request, path: \"\/\" \+ bucket\)\n    \}\n\}/            body: body, payloadHash: SigV4Signer.hexSHA256(body), config: config)\n        try await sendExpectingSuccess(request, path: \"\/\" + bucket)\n    }\n}/' Sources/macSCPCore/S3/S3FileSystem.swift"`
   RED, caught by writingIsAPutOfTheRulesWithTheBodysHashAndASignedContentMD5(). Expected: match. (The pattern anchors on the end of the extension, so it hits `setCORS`'s PUT and not `setVersioning`'s.)
4. New, for I-1: `--apply "perl -0pi -e 's/if rules\.isEmpty \{/if false {/' Sources/macSCPCore/S3/S3FileSystem.swift"`
   RED, caught by writingNoRulesIsADeleteOfTheConfigurationAndNotAPut(). Expected: match.
5. New, for M-1: `--apply "perl -0pi -e 's/case \"ID\": id = currentText\n/case \"ID\": id = currentText.trimmingCharacters(in: .whitespacesAndNewlines)\n/' Sources/macSCPCore/S3/S3SettingsXML.swift"`
   RED, caught by spacesAroundAValueSurviveTheRoundTrip(). Expected: match.
6. New, for I-3: `--apply "perl -0pi -e 's/BucketCORS\(rules: rules, rawBody: data\)/BucketCORS(rules: rules, rawBody: Data())/' Sources/macSCPCore/S3/S3FileSystem.swift"`
   RED, caught by readingIsAGetOnTheCORSSubresourceOfTheNamedBucket() and theRawDocumentKeepsWhatTheParsedRulesDropped(). Expected both: match.
7. New, for M-3: `--apply "perl -0pi -e 's/where origin\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\.isEmpty \{/where false {/' Sources/macSCPCore/RemoteFS/S3BucketSettings.swift"`
   RED, caught by anOriginThatNamesNothingIsNoOrigin(origins:). Expected: match.

Every probe printed RED (caught) and none printed CONTROL NOT ESTABLISHED, PLANT CHANGED NOTHING, BUILD FAILED, NO TESTS RAN, RUN INCOMPLETE or GREEN, and every one named the test I intended, so I found no mismatch. Raw harness logs: /private/tmp/claude-501/-Users-noidee-macSCP/c68e1585-ea4f-4194-a037-c8f1c3a96a0d/scratchpad/p1.log to p7.log (p1 to p3 are probes 1 to 3 above; the earlier-round probes before this one were not logged).

## Caveat on process
No red was taken before editing for this round's new tests (stated in the commit message); the probes above are the sensitivity evidence instead, and each plant is the inverse of the change the test pins.
