import Foundation
import Testing
@testable import macSCPCore

@Suite("S3FieldSchema")
struct S3FieldSchemaTests {
    private func filledValues() -> FieldValues {
        var values = FieldValues()
        values[S3Field.endpoint] = "https://minio.local:9000"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "backups"
        values[S3Field.accessKeyID] = "AKIA"
        values[bool: S3Field.usePathStyle] = true
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .s3), fields: S3Field.self).isEmpty)
    }

    /// The credential schema is what the login-set editor renders. Access key
    /// and secret belong to the login; endpoint and bucket belong to the
    /// connection.
    @Test func credentialSchemaCarriesOnlyTheLoginFields() {
        let ids = Set(BackendDescriptor.descriptor(for: .s3).credentialSchema.fields.map(\.id))
        #expect(ids == [S3Field.accessKeyID.rawValue, S3Field.secretAccessKey.rawValue])
    }

    @Test func makeConfigBuildsAnS3Config() throws {
        let config = try S3FieldSchema.makeConfig(filledValues(), "topsecret")
        guard case .s3(let s3) = config else {
            Issue.record("expected .s3, got \(config)")
            return
        }
        #expect(s3.endpoint == "https://minio.local:9000")
        #expect(s3.bucket == "backups")
        #expect(s3.usePathStyle == true)
        #expect(s3.secretAccessKey == "topsecret")
    }

    @Test func makeConfigRejectsAnEmptyBucket() {
        var values = filledValues()
        values[S3Field.bucket] = ""
        #expect(throws: (any Error).self) { _ = try S3FieldSchema.makeConfig(values, "s") }
    }

    /// The round trip the persistence adapter must satisfy: what the form
    /// collected survives being written to disk and read back.
    @Test func valuesRoundTripThroughTheStoredConfig() {
        let stored = S3FieldSchema.stored(from: filledValues())
        let back = S3FieldSchema.values(from: stored)
        #expect(back[S3Field.endpoint] == "https://minio.local:9000")
        #expect(back[S3Field.region] == "us-east-1")
        #expect(back[S3Field.bucket] == "backups")
        #expect(back[S3Field.accessKeyID] == "AKIA")
        #expect(back[bool: S3Field.usePathStyle] == true)
    }

    /// The stored config has no secret field at all, so the round trip must
    /// not carry one either.
    @Test func theRoundTripDropsTheSecret() {
        var values = filledValues()
        values[S3Field.secretAccessKey] = "topsecret"
        let back = S3FieldSchema.values(from: S3FieldSchema.stored(from: values))
        #expect(back[S3Field.secretAccessKey] == "")
    }

    /// Trimming on write (M23/T7 fix round 1), for the same reason as
    /// `SSHFieldSchema.apply`: the App's S3 save branch trimmed all four of
    /// these before building the config, and collapsing it onto the adapter
    /// moved that responsibility here. `makeConfig` already trims for the
    /// CONNECT direction, so leaving `stored(from:)` raw meant the same value
    /// connected fine and persisted with whitespace.
    @Test func theStoredConfigTrimsEveryTextField() {
        var values = filledValues()
        values[S3Field.endpoint] = "  https://minio.local:9000 "
        values[S3Field.region] = " us-east-1 "
        values[S3Field.bucket] = " backups\n"
        values[S3Field.accessKeyID] = "\tAKIA "
        let stored = S3FieldSchema.stored(from: values)
        #expect(stored.endpoint == "https://minio.local:9000")
        #expect(stored.region == "us-east-1")
        #expect(stored.bucket == "backups")
        #expect(stored.accessKeyID == "AKIA")
    }

    /// The PORT is part of the summary (review 2026-09-04): two sessions on
    /// one host that differ only in the port — a MinIO on 9000 and one on
    /// 9001 — read as the same connection in the sidebar and in every audit
    /// line without it. Suppressed when the endpoint names none, where there
    /// is nothing to tell apart.
    @Test func displaySummaryNamesTheBucketAndEndpointHostWithItsPort() {
        #expect(S3FieldSchema.displaySummary(filledValues()) == "backups @ minio.local:9000")
    }

    @Test func displaySummaryOmitsAPortTheEndpointDoesNotName() {
        var values = filledValues()
        values[S3Field.endpoint] = "https://s3.example.test"
        #expect(S3FieldSchema.displaySummary(values) == "backups @ s3.example.test")
    }

    /// A schemeless endpoint keeps its port here too — the summary reads the
    /// same one parse the connect path does, so the sidebar cannot describe a
    /// session the app dials differently.
    @Test func displaySummaryKeepsThePortOfASchemelessEndpoint() {
        var values = filledValues()
        values[S3Field.endpoint] = "minio.local:9000"
        #expect(S3FieldSchema.displaySummary(values) == "backups @ minio.local:9000")
    }

    // MARK: - An IP literal is addressed path-style (review 2026-09-04, I-3)

    /// Virtual-hosted addressing puts the bucket in front of the host, and
    /// `backups.192.0.2.10` is a name no resolver answers. So an IP-literal
    /// endpoint is addressed path-style whatever the toggle says, and the
    /// config the connect path receives carries that.
    @Test func anIPLiteralEndpointForcesPathStyleInTheConfig() throws {
        var values = filledValues()
        values[S3Field.endpoint] = "192.0.2.10:9000"
        values[bool: S3Field.usePathStyle] = false
        let config = try S3FieldSchema.makeConfig(values, "topsecret")
        guard case .s3(let s3) = config else {
            Issue.record("expected .s3, got \(config)")
            return
        }
        #expect(s3.usePathStyle)
    }

    @Test func anIPLiteralEndpointForcesPathStyleInTheStoredSession() {
        var values = filledValues()
        values[S3Field.endpoint] = "[::1]:9000"
        values[bool: S3Field.usePathStyle] = false
        #expect(S3FieldSchema.stored(from: values).usePathStyle)
    }

    /// A named host keeps the user's own choice — the rule is about what a
    /// resolver can answer, not about what is convenient.
    @Test func aNamedHostKeepsTheToggleTheUserChose() {
        var values = filledValues()
        values[S3Field.endpoint] = "https://minio.local:9000"
        values[bool: S3Field.usePathStyle] = false
        #expect(S3FieldSchema.stored(from: values).usePathStyle == false)
        #expect(S3FieldSchema.pathStyleIsForced(values) == false)
    }

    // MARK: - `startsAtBucketList`: the form's toggle (2026-09-02)

    /// With the toggle on there is no bucket to put in front of the host,
    /// and "` @ host`" is not a summary of anything. The host keeps its port
    /// here like everywhere else (review 2026-09-04) — what the toggle
    /// removes is the bucket, not the endpoint.
    @Test func theSummaryOfABucketListConnectionIsJustTheHost() {
        var values = filledValues()
        values[S3Field.bucket] = ""
        values[bool: S3Field.startsAtBucketList] = true
        let summary = S3FieldSchema.displaySummary(values)
        #expect(summary == "minio.local:9000")
        #expect(!summary.contains("@"))
    }


    /// The toggle's own namespaced key, derived rather than spelled — the
    /// only way to ask whether a value bag carries it AT ALL, which
    /// `values[bool:]` cannot answer (absent and "false" read alike).
    private var toggleKey: String {
        "\(S3Field.namespace).\(S3Field.startsAtBucketList.rawValue)"
    }

    /// With the toggle ON the bucket field is not on screen at all — and a
    /// field that is not on screen has no say in `firstViolation`, so a
    /// blank bucket is not a violation either.
    ///
    /// The `!contains` here is a NEGATIVE check, so the two positive checks
    /// beside it are load-bearing: the toggle itself must be visible (the
    /// schema really was walked), and the bucket must be visible with the
    /// toggle off (the test below) — otherwise a condition that hides
    /// everything would read exactly like this passing.
    @Test func theBucketFieldDisappearsWhenTheConnectionStartsAtTheBucketList() {
        var values = filledValues()
        values[S3Field.bucket] = ""
        values[bool: S3Field.startsAtBucketList] = true

        let visible = S3FieldSchema.connection
            .visibleFields(in: values, namespace: S3Field.namespace).map(\.id)

        #expect(!visible.contains(S3Field.bucket.rawValue))
        #expect(visible.contains(S3Field.startsAtBucketList.rawValue))
        #expect(S3FieldSchema.connection.firstViolation(
            in: values, namespace: S3Field.namespace, requireSecrets: false) == nil)
    }

    /// …and with the toggle OFF nothing changed: the bucket is shown, and a
    /// blank one is still the same refusal, naming the same message key and
    /// the same field.
    @Test func withTheToggleOffTheBucketIsShownAndStillRequired() {
        var values = filledValues()
        values[S3Field.bucket] = ""
        values[bool: S3Field.startsAtBucketList] = false

        let visible = S3FieldSchema.connection
            .visibleFields(in: values, namespace: S3Field.namespace).map(\.id)
        #expect(visible.contains(S3Field.bucket.rawValue))

        let violation = S3FieldSchema.connection.firstViolation(
            in: values, namespace: S3Field.namespace, requireSecrets: false)
        #expect(violation?.messageKey == "core.connect.s3BucketRequired")
        #expect(violation?.fieldKey == "\(S3Field.namespace).\(S3Field.bucket.rawValue)")
    }

    /// The factory carries the toggle into the runtime config, both ways.
    @Test func makeConfigCarriesTheToggleBothWays() throws {
        var on = filledValues()
        on[S3Field.bucket] = ""
        on[bool: S3Field.startsAtBucketList] = true
        guard case .s3(let listMode) = try S3FieldSchema.makeConfig(on, "s") else {
            Issue.record("expected .s3")
            return
        }
        #expect(listMode.startsAtBucketList == true)

        var off = filledValues()
        off[bool: S3Field.startsAtBucketList] = false
        guard case .s3(let bucketMode) = try S3FieldSchema.makeConfig(off, "s") else {
            Issue.record("expected .s3")
            return
        }
        #expect(bucketMode.startsAtBucketList == false)
        #expect(bucketMode.bucket == "backups")
    }

    /// The blank bucket the toggle makes legal reaches the factory too:
    /// `firstViolation` never sees a hidden field, so this guard is the
    /// second half of the same rule and must move with it.
    @Test func makeConfigAcceptsABlankBucketOnlyWhileStartingAtTheBucketList() throws {
        var values = filledValues()
        values[S3Field.bucket] = ""
        values[bool: S3Field.startsAtBucketList] = true
        _ = try S3FieldSchema.makeConfig(values, "s")

        values[bool: S3Field.startsAtBucketList] = false
        #expect(throws: (any Error).self) { _ = try S3FieldSchema.makeConfig(values, "s") }
    }

    /// A value bag written before this field existed carries no such key —
    /// and absent must mean OFF, i.e. today's behaviour byte for byte.
    @Test func aValueBagWithoutTheKeyStartsAtOneBucket() throws {
        let values = filledValues()
        #expect(values.raw[toggleKey] == nil, "the fixture already carries the key — nothing to prove")

        guard case .s3(let s3) = try S3FieldSchema.makeConfig(values, "s") else {
            Issue.record("expected .s3")
            return
        }
        #expect(s3.startsAtBucketList == false)
    }

    /// Both baselines write the toggle OUT rather than leaving it absent,
    /// for the reason `defaults`' own comment gives about `usePathStyle`:
    /// the checkbox must read "off" from a real value. It is also what
    /// keeps the bucket field's visibility condition — which compares
    /// against the string "false" — answering correctly on a fresh form.
    @Test func bothBaselinesWriteTheToggleOutAsOff() {
        #expect(S3FieldSchema.defaults.raw[toggleKey] == "false")
        #expect(S3FieldSchema.editBaseline.raw[toggleKey] == "false")
    }

    /// The persistence adapter round-trips it in both directions.
    @Test func theToggleRoundTripsThroughTheStoredConfig() {
        var values = filledValues()
        values[bool: S3Field.startsAtBucketList] = true
        let stored = S3FieldSchema.stored(from: values)
        #expect(stored.startsAtBucketList == true)
        #expect(S3FieldSchema.values(from: stored)[bool: S3Field.startsAtBucketList] == true)

        values[bool: S3Field.startsAtBucketList] = false
        let off = S3FieldSchema.stored(from: values)
        #expect(off.startsAtBucketList == false)
        #expect(S3FieldSchema.values(from: off).raw[toggleKey] == "false")
    }

    // MARK: - In list mode there is no bucket (Task 3 review, I-4)

    /// Hiding a field does not clear its value — `SchemaFormView` only
    /// filters what it RENDERS. So a user who types a bucket, then turns
    /// the toggle on, then saves, would otherwise persist a bucket the
    /// connection never reads, and that stale value enters the import
    /// identity key.
    ///
    /// Both boundaries out of the value bag therefore write `""` for the
    /// bucket while the toggle is on. The bag itself is left alone, which
    /// is what keeps a toggle flipped on and back off again inside one
    /// unsaved form from losing what the user typed.
    @Test func listModeCarriesNoBucketOutOfTheForm() throws {
        var values = filledValues()
        values[bool: S3Field.startsAtBucketList] = true
        #expect(values[S3Field.bucket] == "backups", "the fixture lost its stale bucket")

        guard case .s3(let config) = try S3FieldSchema.makeConfig(values, "s") else {
            Issue.record("expected .s3")
            return
        }
        #expect(config.bucket == "")
        #expect(config.startsAtBucketList == true)

        let stored = S3FieldSchema.stored(from: values)
        #expect(stored.bucket == "")
        #expect(stored.startsAtBucketList == true)
        #expect(S3FieldSchema.values(from: stored)[S3Field.bucket] == "")

        // The bag the form still holds is untouched: turning the toggle back
        // off before saving must not have cost the user their typing.
        #expect(values[S3Field.bucket] == "backups")
    }

    /// …and with the toggle off both boundaries carry the bucket exactly as
    /// they did before — the positive check beside the blanking above.
    @Test func bucketModeStillCarriesTheBucketOutOfTheForm() throws {
        var values = filledValues()
        values[bool: S3Field.startsAtBucketList] = false

        guard case .s3(let config) = try S3FieldSchema.makeConfig(values, "s") else {
            Issue.record("expected .s3")
            return
        }
        #expect(config.bucket == "backups")
        #expect(S3FieldSchema.stored(from: values).bucket == "backups")
    }

    /// Every `sessions.json` already on disk was written without this key.
    /// It must decode — as OFF — rather than throwing `keyNotFound`, which
    /// would take the whole session file down with it.
    ///
    /// The fixture is spelled out as JSON rather than produced by encoding
    /// a value, because what is being measured is exactly what an OLDER
    /// writer produced: a value built here would carry the new key and
    /// prove nothing.
    @Test func aStoredConfigWrittenBeforeThisFieldDecodesWithTheToggleOff() throws {
        let json = Data("""
            {"accessKeyID":"AKIA","region":"us-east-1","endpoint":"https://minio.local:9000",\
            "bucket":"backups","usePathStyle":true}
            """.utf8)

        let stored = try JSONDecoder().decode(StoredS3Config.self, from: json)

        #expect(stored.startsAtBucketList == false)
        // The positive check beside it: the rest of the block really was
        // read, so the default above is a default and not an empty decode.
        #expect(stored.bucket == "backups")
        #expect(stored.usePathStyle == true)
    }

    /// …and a config in which EVERY field carries a non-default value
    /// survives the round trip.
    ///
    /// "Non-default" is the whole point (Task 3 review, I-3): a field left
    /// at its default on both sides compares equal after a round trip that
    /// never carried it, so a value built with defaults would stay green
    /// while the field silently never reached disk.
    @Test func aFullyPopulatedStoredConfigSurvivesTheRoundTrip() throws {
        let stored = fullyPopulatedStoredConfig()

        let back = try JSONDecoder().decode(
            StoredS3Config.self, from: try JSONEncoder().encode(stored))

        #expect(back == stored)
        #expect(back.startsAtBucketList == true)
    }

    /// The pin that equality cannot give (Task 3 review, I-3). With an
    /// explicit `CodingKeys`, a property left OUT of that enum is neither
    /// encoded nor decoded — and if it was declared with a default, the
    /// hand-written `init(from:)` still compiles and the round trip above
    /// still passes. Nothing would be red while the field is lost on every
    /// save.
    ///
    /// So: count the keys the encoder actually wrote and compare against
    /// the number of stored properties, taken from `Mirror` rather than
    /// from a literal. Adding a property without adding a coding key fails
    /// here, in the same commit that adds it.
    @Test func everyStoredPropertyReachesTheEncodedForm() throws {
        let stored = fullyPopulatedStoredConfig()

        let data = try JSONEncoder().encode(stored)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the encoded form is not a JSON object")

        let properties = Mirror(reflecting: stored).children.count
        #expect(properties > 0, "Mirror found no stored properties — this check scanned nothing")
        #expect(object.count == properties, """
            \(properties) stored propert(ies) but \(object.count) encoded key(s): \
            \(object.keys.sorted()) — a property is missing from `CodingKeys`, and it is \
            neither written nor read.
            """)
    }

    /// Every field away from the value a fresh `StoredS3Config` would carry
    /// — `usePathStyle` and `startsAtBucketList` `true`, and no empty
    /// string among the four text fields.
    private func fullyPopulatedStoredConfig() -> StoredS3Config {
        StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://minio.local:9000", bucket: "backups",
            usePathStyle: true, startsAtBucketList: true)
    }

    // MARK: - A preset per Hetzner Object Storage location (maintainer request 2026-09-03)

    /// Every preset naming a `your-objectstorage.com` host — Hetzner's own —
    /// found by ENDPOINT rather than by id, so a differently-spelled id could
    /// not slip past this check unnoticed.
    private func hetznerPresets() -> [ConnectionPreset] {
        S3FieldSchema.connection.presets.filter {
            $0.values[S3Field.endpoint.rawValue]?.contains("your-objectstorage.com") == true
        }
    }

    /// Three locations are measured against Hetzner's own documentation
    /// (`docs.hetzner.com/storage/object-storage/overview/`, read
    /// 2026-09-04): fsn1 (Falkenstein), hel1 (Helsinki), nbg1 (Nuremberg). A
    /// positive count beside the loop below, per CLAUDE.md's guard rule — a
    /// filter that matched nothing would otherwise pass this test vacuously.
    @Test func everyHetznerPresetParsesToAYourObjectstorageComHostWithPathStyle() throws {
        let presets = hetznerPresets()
        #expect(presets.count == 3, "expected 3 Hetzner presets, found \(presets.count)")

        for preset in presets {
            let endpoint = try #require(
                preset.values[S3Field.endpoint.rawValue],
                "\(preset.id) declares no endpoint")
            let components = try #require(
                S3FieldSchema.endpointComponents(endpoint),
                "\(preset.id)'s endpoint \(endpoint) does not parse")
            let host = try #require(components.host, "\(preset.id)'s endpoint names no host")
            #expect(host.hasSuffix(".your-objectstorage.com"),
                    "\(preset.id)'s host \(host) is not a your-objectstorage.com host")
            #expect(preset.values[S3Field.usePathStyle.rawValue] == "true",
                    "\(preset.id) does not use path-style addressing")
        }
    }

    @Test func everyS3PresetIDIsUnique() {
        let ids = S3FieldSchema.connection.presets.map(\.id)
        #expect(ids.count == Set(ids).count, "duplicate preset id among \(ids)")
    }

    /// `hetzner` keeps naming Falkenstein — stored sessions and the
    /// Cyberduck importer's preset-by-id lookup reference it by this exact
    /// id (see `ImportPreviewPlanner.awsPresetID`'s sibling use for AWS).
    @Test func theHetznerPresetIsStillFalkenstein() throws {
        let preset = try #require(
            S3FieldSchema.connection.presets.first { $0.id == "hetzner" },
            "no preset with id \"hetzner\" — the existing id was renamed out from under stored sessions")
        #expect(preset.values[S3Field.endpoint.rawValue] == "https://fsn1.your-objectstorage.com")
    }
}
