/// How long `SSHKeyGenerator`, `SSHKeyImporter` and `SSHKeyConverter` let
/// one `ssh-keygen` run last before `SubprocessRunner` ends it (all three
/// read it, counted 2026-09-19; the converter since Task 3 of the
/// small-follow-ups plan).
///
/// There was no bound before these waits went through the runner: a stuck
/// `ssh-keygen` held its caller forever. The runner requires one, so this is
/// the widest value that still ends a stuck child, not a performance claim.
///
/// What it has to leave room for is the bcrypt KDF an encrypted
/// `openssh-key-v1` key runs on every open, which scales with the key's
/// `-a` rounds and which macSCP does not choose for an imported key.
/// Measured 2026-09-19 on the maintainer's machine (10 cores, idle), one
/// `ssh-keygen -y -P <passphrase> -f <ed25519 key>` each: 0.13 s at `-a 16`
/// (the default), 0.84 s at `-a 100`, 7.97 s at `-a 1000` — about 8 ms per
/// round. Ten minutes is therefore some 75 000 rounds on that machine;
/// a slower or busier one gets fewer. A key past that fails as timed out
/// instead of opening, which it would have done before, eventually.
///
/// One place reads a timeout as something else. `EmbeddedKeyPorter`'s
/// `identity(of:declaredBy:)` tries its `ssh-keygen` runs with `try?`, so a
/// run stopped here counts as "this key does not open" and the import moves
/// on to the next attempt: `-y` with no passphrase, `-y` with the carried
/// one, then `-l`. One key can therefore hold a login-set import for up to
/// three bounds, and a carried passphrase whose `-y` timed out is dropped,
/// not stored. That last branch still checks the file's own cleartext public
/// key, so it is no weaker. It only matters past the rounds above.
enum KeyToolBound {
    static let keygen: Duration = .seconds(600)
}
