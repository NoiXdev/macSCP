<!--
Short is fine. The four headings below are what a reviewer needs; everything
else you want to say is welcome underneath them.
-->

## What this changes

<!-- One or two sentences. What behaviour is different after this than before? -->

## Why

<!--
The situation that made it necessary. If it fixes a reported problem, link the
issue. If you measured something, put the number here rather than "it was
slow" — a number is checkable and an adjective is not.
-->

## How it was verified

<!--
Not "tests pass" — which command, and what it printed. The suite is:

    swift test

If `swift test` fails on `Shaders.metal` with
`cannot execute tool 'metal' due to missing Metal Toolchain`, the Metal
toolchain component is missing rather than the build broken: run
`xcodebuild -downloadComponent MetalToolchain` once. Do not add
`--build-system native` — it is deprecated, and CI runs `swift test`
without it.

The gated suites do not run by default and are not required for most changes:
`MACSCP_ITEST=1` needs the Docker rig
(`docker compose -f docker/test-server/compose.yml up -d`, started from the
main checkout), and `MACSCP_KEYCHAIN=1` writes to your real keychain.

If a change cannot be covered by a test, say so and say why — that is a
finding, not an omission.
-->

## Checklist

- [ ] New behaviour comes with a test, and I saw that test fail before the change.
- [ ] `swift test` is green, and the build produces no new warnings (CI's budget is zero).
- [ ] No password, passphrase, private key, host fingerprint, or real server address appears in the diff — including in test fixtures and in expectation messages, which are printed when a test fails.
- [ ] User-visible strings go through the localization helpers rather than being written into the code, and every catalogue has the new key.
- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/) — the changelog is generated from them.
- [ ] Anything a user would notice is written into the user documentation, or the PR says why it is not.
