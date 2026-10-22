# Task 11, fix round 3 (N5)

BASE `0ef4e3f5`. Two commits, none amended, no rebase:

- `bb6f197a` test(app): the sweep reads the project's own blanker, not a quote toggler beside it
- `eff615ef` test(app): the probes of fix round 3, N5 measured both ways (empty commit; its message is the record)

Full `swift test` at `eff615ef` (code identical to `bb6f197a`): Core 5075 passed;
App 2815 tests, one red, the pre-existing `ViewTestabilitySpike` isRegex test.

## N5 was real, and measured before it was fixed

Against `0ef4e3f5`, `--filter CreateBucketSheetTests`, control 50 tests, 0
pre-existing failures:

- **N5a**, a view member named only inside a string literal at the end of the
  file: **GREEN**. The silent hole existed: a member counted as named without
  being tested.
- **N5b**, a view member named only in code at the end of the file: **RED**,
  caught by `everyMemberTheViewReadsIsNamedByATest`. A false red: the member is
  named, in code, and the inverted blanker dropped it.

(N5b's first run was BUILD FAILED, my plant's helper lacked `@MainActor`, and
measured nothing; fixed and re-run. The commit message says so.)

## The fix

`withoutStringLiterals` and its test are deleted. The sweep reads
`Self.code("Tests/macSCPAppKitTests/CreateBucketSheetTests.swift")`, which is
`SourceCorpus.code(of:)` already used in the same file. The removal is recorded
in place with the old behaviour quoted. Two fixtures at the very end of the file,
after the regex literal that caused the inversion, hold the property:
`theSweepSeesCodeAndNotStringsAtTheEndOfThisFile` (a name in code must be a token;
a name inside a string must not).

Against `bb6f197a`, through `scripts/mutation-probe` (commands in `eff615ef`'s
message, filter `CreateBucketSheetTests|ConnectionActionRouteTests`, control 63,
0 pre-existing failures):

- N5a: **RED**, caught by `everyMemberTheViewReadsIsNamedByATest`
- N5b: **GREEN** (correctly: the member is named)
- RP1, RP2 (the sweep's earlier probes): still **RED**, same catcher

An observation, not a finding: in fix round 1 my first attempt at this sweep
used `Self.code` and came out with names "unnamed" that plainly were named; I
then blamed a `\b` regex I never explained. This round's measurement suggests
the cause may have been the same regex-literal quotes (I did not re-test that
older draft, so it is a hypothesis, not a result).

## Recorded, not fixed (as instructed)

- M4's English pin is a **word** pin, not a meaning pin: "it cannot be chosen
  once a bucket is created" would pass it.
- The height comparison (`aTakenNameAddsNoLineBeside...`) asserts equality within
  0.01 pt between two measurements taken in the same run, with no ceiling. It is
  **unmeasured on other hardware**; the shape (an equality inside one run, not an
  absolute or wall-clock bound) is the one the project's rules prefer.

M1, M3, M7 untouched. Nothing I could not do.
