import Foundation
import Testing

@testable import macSCPCore

/// Runs only with MACSCP_ITEST=1 and the Docker S3 rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`, started from the
/// main checkout and never from a worktree).
///
/// **What this file is.** The measurements the version-history work had to
/// ASSUME while it was built, taken against a real store. Each case names the
/// decision in shipped source that depends on its answer. The rig is RustFS,
/// not AWS, and has measured more permissive than AWS before: every answer
/// below is a statement about THAT store at that version, and a result that
/// differs from AWS's documentation is a finding about the rig.
///
/// Creates and deletes its OWN throwaway buckets (`macscp-vg-<purpose>-<hex>`);
/// the rig's `macscp-seed`, `macscp-second` and `macscp-probe-lock` are never
/// named by a request. **No retention of any kind is ever set here**, and
/// COMPLIANCE least of all: a bucket this suite means to delete must stay
/// deletable. The cleanup removes every version and delete marker before the
/// bucket, and refuses a bucket whose name this suite did not mint.
///
/// **Figures go to standard output** as `[S3VersionsGated] ...` lines, beside
/// the assertion that does not depend on them. No case asserts a wall-clock
/// ceiling: a duration is printed, never bounded.
@Suite(
    "S3 version history against the Docker S3 rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(5))
)
struct S3VersionsGatedTests {

    // MARK: Measurement 1, the unsafe direction

    /// Spec 4.4, and the one carried measurement whose failure direction is
    /// UNSAFE: `S3FileSystem.restore` is a copy onto the same key naming a
    /// non-current version. A store that ignored `?versionId=` in the copy
    /// source would copy the CURRENT content onto the key, and on the weak
    /// confirmation path (next case) report that as done.
    ///
    /// The raw copy is sent first so the answer is the STORE's and not
    /// `restore`'s read-back; the capability is then run on the same bucket.
    /// The content is compared by bytes, never by ETag, since the ETag is the
    /// evidence that is in question.
    @Test func aCopySourceNamingAVersionCopiesThatVersionAndNotTheCurrentContent() async throws {
        let rig = try await RigBucket.make(purpose: "copy")
        guard let rig else { return }
        let first = Data("first-content".utf8)
        let second = Data("second-content-which-is-longer".utf8)

        var failure: (any Error)?
        var rawStatus: Int?
        var rawBodyIsCopyResult: Bool?
        var afterRawCopy: Data?
        var secondStillReadable: Data?
        var versionsAfterRawCopy: [ObjectVersion] = []
        var newVersionIsLatest: Bool?
        var afterRestore: Data?
        do {
            let v1 = try await rig.put("doc.txt", first)
            let v2 = try await rig.put("doc.txt", second)
            let (data, response) = try await rig.copy(
                "doc.txt", from: "doc.txt", sourceVersionId: v1)
            rawStatus = response.statusCode
            rawBodyIsCopyResult = String(decoding: data, as: UTF8.self).contains("<CopyObjectResult")
            afterRawCopy = try await rig.get("doc.txt").1
            secondStillReadable = try await rig.get("doc.txt", versionId: v2).1
            versionsAfterRawCopy = try await rig.fs.versions(ofKey: "doc.txt", inBucket: rig.bucket)
            newVersionIsLatest =
                versionsAfterRawCopy.first(where: \.isLatest).map { $0.versionId != v1 && $0.versionId != v2 }

            // The capability, from a state where the current content is the
            // LATER version again (so a store that ignored the id would copy
            // `second` and the comparison below would see it).
            _ = try await rig.put("doc.txt", second)
            try await rig.fs.restore(key: "doc.txt", inBucket: rig.bucket, toVersionId: v1)
            afterRestore = try await rig.get("doc.txt").1
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3VersionsGated] m1 raw copy naming v1: status=\(rawStatus.map(String.init) ?? "-")"
                + " bytesNowCurrent=\(afterRawCopy.map { String(decoding: $0, as: UTF8.self) } ?? "-")"
                + " versionsAfter=\(versionsAfterRawCopy.count)")
        #expect(failure == nil)
        #expect(rawStatus == 200)
        #expect(rawBodyIsCopyResult == true)
        // The measurement itself: the version's content, not the current's.
        #expect(afterRawCopy == first, "a copy naming a version copied some other content")
        #expect(secondStillReadable == second)
        // Restoring adds; it does not erase (spec 4.4): v1, v2, the copy.
        #expect(versionsAfterRawCopy.count == 3)
        #expect(newVersionIsLatest == true)
        #expect(afterRestore == first, "restore reported done with some other content on the key")
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// The WEAK confirmation path: a source whose ETag is a multipart
    /// composite, which `restoredContent(of:matches:)` does not compare. There
    /// the only evidence that a restore wrote the right bytes is the store
    /// honouring the version id, so this is the case that would read a store
    /// ignoring it as DONE. The control that this IS the weak path is the
    /// source's own ETag, interpreted as `restore` interprets it.
    @Test func aRestoreOfAMultipartSourceWritesTheSourceBytes() async throws {
        let rig = try await RigBucket.make(purpose: "weak")
        guard let rig else { return }
        let partA = Data(repeating: 0x41, count: 5 * 1024 * 1024)
        let partB = Data(repeating: 0x42, count: 1024)
        let source = partA + partB
        let current = Data("a short current content".utf8)

        var failure: (any Error)?
        var sourceTag: String?
        var interpretation: ETagInterpretation?
        var restoreError: (any Error)?
        var afterRestore: Data?
        var latestIsNew: Bool?
        do {
            let v1 = try await rig.multipart("big.bin", parts: [partA, partB])
            let v2 = try await rig.put("big.bin", current)
            let before = try await rig.fs.versions(ofKey: "big.bin", inBucket: rig.bucket)
            sourceTag = before.first(where: { $0.versionId == v1 })?.entityTag
            interpretation = sourceTag.map(ObjectStorageETag.interpret)
            do {
                try await rig.fs.restore(key: "big.bin", inBucket: rig.bucket, toVersionId: v1)
            } catch {
                restoreError = error
            }
            afterRestore = try await rig.get("big.bin").1
            let after = try await rig.fs.versions(ofKey: "big.bin", inBucket: rig.bucket)
            latestIsNew = after.first(where: \.isLatest).map { $0.versionId != v1 && $0.versionId != v2 }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        let isComposite: Bool
        if case .multipartComposite = interpretation { isComposite = true } else { isComposite = false }
        print(
            "[S3VersionsGated] m1 weak path: sourceEtagComposite=\(isComposite)"
                + " restoreThrew=\(restoreError != nil) bytesMatchSource=\(afterRestore == source)"
                + " bytesMatchCurrent=\(afterRestore == current)")
        #expect(failure == nil)
        // The control: without it a green result could be the strong path.
        #expect(isComposite, "the source's ETag was not a multipart composite: this was not the weak path")
        #expect(restoreError == nil)
        #expect(afterRestore == source, "restore on the weak path left some other content on the key")
        #expect(latestIsNew == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Measurement 2

    /// `restore` is a self-copy naming a source version, which Task 4 assumed
    /// legal. AWS refuses a self-copy that changes nothing; this records what
    /// the rig does with BOTH spellings. Only the first is asserted: the
    /// second (no source version, no metadata directive) is printed because
    /// nothing in macSCP sends it.
    @Test func aSelfCopyNamingASourceVersionIsAccepted() async throws {
        let rig = try await RigBucket.make(purpose: "self")
        guard let rig else { return }
        var failure: (any Error)?
        var withVersion: Int?
        var withoutVersion: Int?
        var withoutVersionCode: String?
        do {
            let v1 = try await rig.put("self.txt", Data("one".utf8))
            _ = try await rig.put("self.txt", Data("two".utf8))
            withVersion = try await rig.copy("self.txt", from: "self.txt", sourceVersionId: v1).1.statusCode
            let plain = try await rig.copy("self.txt", from: "self.txt", sourceVersionId: nil)
            withoutVersion = plain.1.statusCode
            withoutVersionCode = Self.element("Code", in: String(decoding: plain.0, as: UTF8.self))
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3VersionsGated] m2 self-copy naming a version: status=\(withVersion.map(String.init) ?? "-");"
                + " self-copy naming none: status=\(withoutVersion.map(String.init) ?? "-")"
                + " code=\(withoutVersionCode ?? "-")")
        #expect(failure == nil)
        #expect(withVersion == 200)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Measurement 3

    /// `deleteVersion` and `liftDeleteMarker` confirm by ABSENCE: a store whose
    /// delete is not yet visible to the next read would report a successful
    /// delete as failed. One success shows nothing about a race, so each
    /// confirms twenty times in a row with nothing between request and read.
    @Test func aVersionDeleteIsVisibleToTheReadThatFollowsIt() async throws {
        let rig = try await RigBucket.make(purpose: "delete")
        guard let rig else { return }
        let rounds = 20
        var failure: (any Error)?
        var rawStillListed = 0
        var versionDeleteUnconfirmed = 0
        var markerLiftUnconfirmed = 0
        var markerLiftBrokeTheKey = 0
        do {
            for round in 0..<rounds {
                // A raw delete, read back at once.
                let key = "raw-\(round).txt"
                let old = try await rig.put(key, Data("old".utf8))
                _ = try await rig.put(key, Data("new".utf8))
                let status = try await rig.deleteVersion(key, old).statusCode
                #expect((200..<300).contains(status))
                let listed = try await rig.fs.versions(ofKey: key, inBucket: rig.bucket)
                if listed.contains(where: { $0.versionId == old }) { rawStillListed += 1 }

                // The capability's own confirmation.
                let key2 = "cap-\(round).txt"
                let old2 = try await rig.put(key2, Data("old".utf8))
                _ = try await rig.put(key2, Data("new".utf8))
                do {
                    try await rig.fs.deleteVersion(ofKey: key2, inBucket: rig.bucket, versionId: old2)
                } catch RemoteFSError.protocolError(let reason)
                    where reason == S3FileSystem.deleteVersionUnconfirmedReason
                {
                    versionDeleteUnconfirmed += 1
                }

                // A delete marker, lifted.
                let key3 = "marker-\(round).txt"
                _ = try await rig.put(key3, Data("kept".utf8))
                let deleted = try await rig.delete(key3)
                let markerId = deleted.value(forHTTPHeaderField: "x-amz-version-id") ?? ""
                do {
                    try await rig.fs.liftDeleteMarker(
                        ofKey: key3, inBucket: rig.bucket, markerVersionId: markerId)
                } catch RemoteFSError.protocolError(let reason)
                    where reason == S3FileSystem.liftDeleteMarkerUnconfirmedReason
                {
                    markerLiftUnconfirmed += 1
                }
                if try await rig.get(key3).1 != Data("kept".utf8) { markerLiftBrokeTheKey += 1 }
            }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3VersionsGated] m3 over \(rounds) rounds: raw delete still listed on the next read=\(rawStillListed);"
                + " deleteVersion unconfirmed=\(versionDeleteUnconfirmed);"
                + " liftDeleteMarker unconfirmed=\(markerLiftUnconfirmed); key unreadable after lift=\(markerLiftBrokeTheKey)")
        #expect(failure == nil)
        #expect(rawStillListed == 0)
        #expect(versionDeleteUnconfirmed == 0)
        #expect(markerLiftUnconfirmed == 0)
        #expect(markerLiftBrokeTheKey == 0)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Measurement 4

    /// `deletedEntries` sends `delimiter=/` on `?versions` and does not read
    /// `CommonPrefixes`. Spec 4.8 measured that the delimiter is honoured;
    /// this measures what it BUYS for the call that sends it: the same
    /// listing with and without it, counted element by element. The answer of
    /// `deletedEntries` is asserted either way, because `oneLevelBelow`
    /// decides it and not the store.
    @Test func theDelimiterOnTheVersionListingRollsUpWhatDeletedEntriesIgnores() async throws {
        let rig = try await RigBucket.make(purpose: "delim")
        guard let rig else { return }
        var failure: (any Error)?
        var withDelimiter = ""
        var without = ""
        var entries: [DeletedEntry] = []
        do {
            for key in ["d/top.txt", "d/sub/deep.txt", "d/sub/deeper/x.txt", "d/live.txt", "root.txt"] {
                _ = try await rig.put(key, Data(key.utf8))
            }
            for key in ["d/top.txt", "d/sub/deep.txt", "d/sub/deeper/x.txt"] {
                _ = try await rig.delete(key)
            }
            withDelimiter = try await rig.rawVersions(prefix: "d/", delimiter: "/")
            without = try await rig.rawVersions(prefix: "d/", delimiter: nil)
            entries = try await rig.fs.deletedEntries(inBucket: rig.bucket, prefix: "d/")
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        let withCounts = Self.counts(withDelimiter)
        let withoutCounts = Self.counts(without)
        print(
            "[S3VersionsGated] m4 ?versions&prefix=d/ with delimiter: versions=\(withCounts.versions)"
                + " markers=\(withCounts.markers) commonPrefixes=\(withCounts.prefixes);"
                + " without: versions=\(withoutCounts.versions) markers=\(withoutCounts.markers)"
                + " commonPrefixes=\(withoutCounts.prefixes)")
        #expect(failure == nil)
        // Positive controls first: the fixture produced what it was meant to.
        #expect(withoutCounts.markers == 3, "the fixture did not produce three markers")
        #expect(withoutCounts.prefixes == 0)
        // What the delimiter does here.
        #expect(withCounts.prefixes >= 1, "the store did not roll anything up under a delimiter")
        #expect(withCounts.markers == 1)
        // What deletedEntries answers, whatever the store did.
        #expect(entries.map(\.key) == ["d/top.txt"])
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Measurement 5

    /// The paging loop FOLLOWS a `NextKeyMarker` beside `IsTruncated=false`,
    /// at the price of one extra request per listing. Measured two ways: the
    /// last page of a paged listing, and the only page of an unpaged one,
    /// counted in requests through `versions(ofKey:)` itself.
    @Test func aLastPageCarriesNoMarkerAndAListingCostsOneRequest() async throws {
        let counting = CountingTransport()
        let rig = try await RigBucket.make(purpose: "pages", transport: counting)
        guard let rig else { return }
        var failure: (any Error)?
        var pages: [String] = []
        var requestsForListing = 0
        var listed: [ObjectVersion] = []
        do {
            for key in ["p1.txt", "p2.txt", "p3.txt"] { _ = try await rig.put(key, Data(key.utf8)) }
            for _ in 0..<3 { _ = try await rig.put("many.txt", Data("m".utf8)) }
            // Follow the markers with max-keys=1 by hand, as spec 4.9 did.
            var keyMarker: String?
            var versionMarker: String?
            for _ in 0..<10 {
                let page = try await rig.rawVersions(
                    prefix: "p", delimiter: nil, maxKeys: 1, keyMarker: keyMarker,
                    versionIdMarker: versionMarker)
                pages.append(page)
                guard Self.element("IsTruncated", in: page) == "true" else { break }
                keyMarker = Self.element("NextKeyMarker", in: page)
                versionMarker = Self.element("NextVersionIdMarker", in: page)
            }
            await counting.reset()
            listed = try await rig.fs.versions(ofKey: "many.txt", inBucket: rig.bucket)
            requestsForListing = await counting.count(where: { $0.contains("versions") })
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        let last = pages.last ?? ""
        let lastTruncated = Self.element("IsTruncated", in: last) ?? "-"
        let lastMarkerPresent = last.contains("<NextKeyMarker>")
        let lastMarkerEmpty = lastMarkerPresent && (Self.element("NextKeyMarker", in: last) ?? "").isEmpty
        print(
            "[S3VersionsGated] m5 pages=\(pages.count) last page: IsTruncated=\(lastTruncated)"
                + " NextKeyMarkerElement=\(lastMarkerPresent) emptyElement=\(lastMarkerEmpty);"
                + " versions(ofKey:) of a 3-entry key took \(requestsForListing) version-listing request(s)")
        #expect(failure == nil)
        #expect(pages.count == 3, "the paged walk did not take one page per key")
        #expect(lastTruncated == "false")
        #expect(listed.count == 3)
        // The extra request is needed only when the last page names a marker.
        #expect(
            requestsForListing == (lastMarkerPresent && !lastMarkerEmpty ? 2 : 1),
            "the request count disagrees with what the last page carried")
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Measurement 6

    /// `VersionDownloadSource.stat` reads the history to size the transfer, so
    /// every version download pays one listing before a byte moves. Counted in
    /// requests and timed (printed, never bounded) at one entry and at two
    /// hundred, against the read of the content it precedes.
    @Test func aVersionDownloadPaysOneListingBeforeTheFirstByte() async throws {
        let counting = CountingTransport()
        let rig = try await RigBucket.make(purpose: "dl", transport: counting)
        guard let rig else { return }
        let content = Data(repeating: 0x5A, count: 1024 * 1024)
        let longHistory = 200
        var failure: (any Error)?
        var statRequests: [Int] = []
        var statMillis: [Int] = []
        var statSize: [UInt64?] = []
        var readRequests = 0
        var readMillis = 0
        var received = 0
        var listingBytes: [Int] = []
        do {
            let short = try await rig.put("short.bin", content)
            var oldest = ""
            for index in 0..<longHistory {
                let id = try await rig.put("long.bin", index == 0 ? content : Data("v\(index)".utf8))
                if index == 0 { oldest = id }
            }
            for (key, id) in [("short.bin", short), ("long.bin", oldest)] {
                let source = VersionDownloadSource(
                    source: rig.fs, bucket: rig.bucket, key: key, versionId: id)
                await counting.reset()
                let clock = ContinuousClock()
                let started = clock.now
                let item = try await source.stat(path: "/")
                statMillis.append(Self.milliseconds(started.duration(to: clock.now)))
                statRequests.append(await counting.count(where: { _ in true }))
                statSize.append(item.size)
                listingBytes.append(try await rig.rawVersions(prefix: key, delimiter: nil).utf8.count)

                await counting.reset()
                let readStarted = clock.now
                for try await chunk in try await source.readStream(path: "/", fromOffset: 0) {
                    received += chunk.count
                }
                readMillis = Self.milliseconds(readStarted.duration(to: clock.now))
                readRequests = await counting.count(where: { _ in true })
            }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()

        print(
            "[S3VersionsGated] m6 stat of a version: 1-entry history \(statRequests.first ?? -1) request(s)"
                + " \(statMillis.first ?? -1) ms \(listingBytes.first ?? -1) response bytes;"
                + " \(longHistory)-entry history \(statRequests.last ?? -1) request(s)"
                + " \(statMillis.last ?? -1) ms \(listingBytes.last ?? -1) response bytes;"
                + " the 1 MiB read after it: \(readRequests) request(s) \(readMillis) ms")
        #expect(failure == nil)
        #expect(statRequests == [1, 1], "a version's size cost something other than one listing")
        #expect(statSize == [UInt64(content.count), UInt64(content.count)])
        #expect(readRequests == 1)
        #expect(received == content.count * 2)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Measurement 7

    /// With `showDeletedFiles` on and a versioned bucket, the silent refresh
    /// makes TWO listings per tick where it made one, and
    /// `autoRefreshIntervalSeconds` defaults to 5. This counts a tick in
    /// requests and prints what it costs in time and bytes as the bucket
    /// grows; then the other two states the switch can meet: a bucket that
    /// never kept versions, and a versioning read that fails.
    @Test func aDeletedRowsTickCostsTwoListingsAndTheSwitchOnAnUnconfirmedBucketOneFailingRequest() async throws {
        let counting = CountingTransport()
        let rig = try await RigBucket.make(purpose: "tick", transport: counting)
        let plain = try await RigBucket.make(purpose: "plain", versioned: false)
        guard let rig, let plain else {
            if let rig { _ = await rig.teardown() }
            if let plain { _ = await plain.teardown() }
            return
        }
        let keys = 100
        var failure: (any Error)?
        var tickRequests: [String] = []
        var warmVersioningRequests = -1
        var tickMillis: [Int] = []
        var deletedSeen = 0
        var listBytes = 0
        var versionsBytes = 0
        var cacheHeaders: [String] = ["unread"]
        var unversionedState: BucketVersioning?
        var unversionedProbeStatus: Int?
        var unversionedProbeEntries = -1
        var failingRequests = -1
        var failingError: (any Error)?
        var failingMillis = -1
        do {
            for index in 0..<keys { _ = try await rig.put("k\(index).txt", Data("x".utf8)) }
            for index in 0..<20 { _ = try await rig.delete("k\(index).txt") }
            // A client on the throwaway bucket itself: what a pane's refresh uses.
            let paneConfig = RigBucket.config(bucket: rig.bucket)
            let counted = CountingTransport()
            let pane = try await S3FileSystem.connect(paneConfig, transport: counted)
            do {
                await counted.reset()
                _ = try await pane.versioning(ofBucket: rig.bucket)
                warmVersioningRequests = await counted.count(where: { _ in true })

                let clock = ContinuousClock()
                for tick in 0..<10 {
                    await counted.reset()
                    let started = clock.now
                    let listed = try await pane.list(path: "/")
                    let deleted = try await pane.deletedEntries(inBucket: rig.bucket, prefix: "")
                    tickMillis.append(Self.milliseconds(started.duration(to: clock.now)))
                    if tick == 0 {
                        tickRequests = await counted.kinds()
                        deletedSeen = deleted.count
                        #expect(listed.count == keys - 20, "the plain listing is not the live keys")
                    }
                }
                cacheHeaders = try await rig.cacheHeadersOfTheTickListings()
                listBytes = try await rig.rawList().utf8.count
                versionsBytes = try await rig.rawVersions(prefix: "", delimiter: "/").utf8.count
            } catch {
                failure = error
            }
            await pane.disconnect()

            // A bucket that never kept versions.
            unversionedState = try await plain.fs.versioning(ofBucket: plain.bucket)
            _ = try await plain.put("only.txt", Data("only".utf8))
            let probe = try await plain.rawVersionsAnswer(prefix: "", delimiter: "/")
            unversionedProbeStatus = probe.0
            unversionedProbeEntries = Self.counts(probe.1).versions + Self.counts(probe.1).markers

            // A versioning read that fails: a bucket that is not there.
            let missing = S3SettingsRig.throwawayBucketName(purpose: "vg-absent")
            let failCounter = CountingTransport()
            let failing = try await S3FileSystem.connect(S3SettingsRig.config, transport: failCounter)
            await failCounter.reset()
            let clock = ContinuousClock()
            let started = clock.now
            do { _ = try await failing.versioning(ofBucket: missing) } catch { failingError = error }
            failingMillis = Self.milliseconds(started.duration(to: clock.now))
            failingRequests = await failCounter.count(where: { _ in true })
            await failing.disconnect()
        } catch {
            failure = failure ?? error
        }
        let cleaned = await rig.teardown()
        let cleanedPlain = await plain.teardown()

        let sorted = tickMillis.sorted()
        print(
            "[S3VersionsGated] m7 one tick over \(keys) keys (20 deleted): requests=\(tickRequests)"
                + " rows deleted=\(deletedSeen); 10 ticks ms min/median/max="
                + "\(sorted.first ?? -1)/\(sorted.isEmpty ? -1 : sorted[sorted.count / 2])/\(sorted.last ?? -1);"
                + " listing response bytes=\(listBytes) versions response bytes=\(versionsBytes);"
                + " the versioning read: \(warmVersioningRequests) request(s);"
                + " cache headers on the two listings: \(cacheHeaders)")
        print(
            "[S3VersionsGated] m7 never-versioned bucket: ?versioning reads \(unversionedState.map { "\($0)" } ?? "-");"
                + " a ?versions probe on it would answer status \(unversionedProbeStatus.map(String.init) ?? "-")"
                + " with \(unversionedProbeEntries) entr(ies); a failing versioning read: \(failingRequests)"
                + " request(s) \(failingMillis) ms, threw=\(failingError != nil)")
        #expect(failure == nil)
        #expect(tickRequests.count == 2, "a tick was not two requests")
        #expect(tickRequests.first?.contains("list-type") == true)
        #expect(tickRequests.last?.contains("versions") == true)
        #expect(deletedSeen == 20)
        #expect(cacheHeaders.isEmpty, "a listing carries a cache header, so a tick may not reach the store")
        #expect(warmVersioningRequests == 1)
        #expect(unversionedState == BucketVersioning.never)
        #expect(failingError != nil)
        #expect(failingRequests == 1)
        #expect(cleaned == true, "the throwaway bucket was left behind")
        #expect(cleanedPlain == true, "the throwaway bucket was left behind")
    }

    // MARK: The session cache

    /// A finding of the first run of this file. A `DELETE` naming a version
    /// whose content a buffered `GET` had just fetched, on a session that
    /// keeps the default cache, came back `200` with the object and removed
    /// nothing. The control is the same sequence on the connection's own
    /// session (`S3FileSystem.connect` with no transport), which the store
    /// answers `204` and executes. **Not a statement about the product's
    /// reads**: its only object `GET` streams.
    ///
    /// **Withdrawn, verbatim:** this case was first named
    /// `theDefaultSessionAnswersADeleteFromItsCacheAfterAGetOfTheSameUrl` and
    /// read "was answered from the session's cache" and "the DELETE never
    /// reached the store". Not so: the DELETE reached the store carrying the
    /// cache's validators, which the ungated `S3StateChangeNeverFromCacheTests`
    /// reads off the request head, and each repeated DELETE came back with its
    /// own `x-request-id`. What the RIG does with a DELETE that carries
    /// `If-None-Match` is to answer it as a read; another store may do
    /// otherwise, which is unmeasured. The outcome asserted below is the rig's.
    @Test func aDeleteOnASessionWithTheDefaultCacheIsAnsweredWithTheObjectAndDeletesNothing() async throws {
        let cached = try await S3FileSystem.connect(
            S3SettingsRig.config,
            transport: URLSessionHTTPTransport(session: URLSession(configuration: .ephemeral)))
        let production = try await S3FileSystem.connect(S3SettingsRig.config)
        let setUp = try await RigBucket.make(purpose: "cache")
        guard let rig = setUp else { return }
        var failure: (any Error)?
        var cachedStatus: Int?
        var cachedBodyBytes: Int?
        var stillListedAfterCached: Bool?
        var freshStatus: Int?
        var goneAfterFresh: Bool?
        do {
            let keep = try await rig.put("c.txt", Data("keep".utf8))
            _ = keep
            let victim = try await rig.put("c.txt", Data("victim".utf8))
            _ = try await rig.put("c.txt", Data("newest".utf8))
            let other = try await rig.put("c2.txt", Data("other".utf8))
            _ = try await rig.put("c2.txt", Data("other-newest".utf8))
            // Cached session: GET the version, then DELETE the same url.
            _ = try await S3SettingsRig.objectRequest(
                "GET", bucket: rig.bucket, key: "c.txt", query: [(name: "versionId", value: victim)], in: cached)
            let answer = try await S3SettingsRig.objectRequest(
                "DELETE", bucket: rig.bucket, key: "c.txt", query: [(name: "versionId", value: victim)],
                in: cached)
            cachedStatus = answer.1.statusCode
            cachedBodyBytes = answer.0.count
            stillListedAfterCached = try await rig.fs.versions(ofKey: "c.txt", inBucket: rig.bucket)
                .contains { $0.versionId == victim }
            // The control: the connection's own session.
            _ = try await S3SettingsRig.objectRequest(
                "GET", bucket: rig.bucket, key: "c2.txt", query: [(name: "versionId", value: other)],
                in: production)
            freshStatus = try await S3SettingsRig.objectRequest(
                "DELETE", bucket: rig.bucket, key: "c2.txt", query: [(name: "versionId", value: other)],
                in: production
            ).1.statusCode
            goneAfterFresh = try await !rig.fs.versions(ofKey: "c2.txt", inBucket: rig.bucket)
                .contains { $0.versionId == other }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()
        await cached.disconnect()
        await production.disconnect()

        print(
            "[S3VersionsGated] cache: DELETE after GET of the same url, default-cache session: status="
                + "\(cachedStatus.map(String.init) ?? "-") bodyBytes=\(cachedBodyBytes.map(String.init) ?? "-")"
                + " versionStillListed=\(stillListedAfterCached.map(String.init) ?? "-");"
                + " the connection's own session: status=\(freshStatus.map(String.init) ?? "-")"
                + " versionGone=\(goneAfterFresh.map(String.init) ?? "-")")
        #expect(failure == nil)
        // The control first: the connection's own session deletes.
        #expect(freshStatus == 204)
        #expect(goneAfterFresh == true)
        // The measurement.
        #expect(cachedStatus == 200, "the rig no longer answers that DELETE with the object")
        #expect(cachedBodyBytes != 0)
        #expect(stillListedAfterCached == true)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    /// The reach of the finding above, on the connection's own session: the
    /// streamed download is the only way production reads an object's content,
    /// and deleting that version afterwards must work. (Measured the same way
    /// before the connection's session lost its cache, 2026-11-03, when it was
    /// the case that showed production was not exposed.)
    @Test func aStreamedVersionDownloadDoesNotStandInTheWayOfDeletingThatVersion() async throws {
        let fs = try await S3FileSystem.connect(S3SettingsRig.config)
        let setUp = try await RigBucket.make(purpose: "stream")
        guard let rig = setUp else { return }
        var failure: (any Error)?
        var received = 0
        var deleteError: (any Error)?
        var stillListed: Bool?
        do {
            let victim = try await rig.put("s.txt", Data("victim".utf8))
            _ = try await rig.put("s.txt", Data("newest".utf8))
            for try await chunk in try await fs.readStream(
                ofKey: "s.txt", inBucket: rig.bucket, versionId: victim)
            {
                received += chunk.count
            }
            do {
                try await fs.deleteVersion(ofKey: "s.txt", inBucket: rig.bucket, versionId: victim)
            } catch {
                deleteError = error
            }
            stillListed = try await rig.fs.versions(ofKey: "s.txt", inBucket: rig.bucket)
                .contains { $0.versionId == victim }
        } catch {
            failure = error
        }
        let cleaned = await rig.teardown()
        await fs.disconnect()

        print(
            "[S3VersionsGated] cache: streamed download of a version then deleteVersion:"
                + " bytes=\(received) deleteThrew=\(deleteError != nil) versionStillListed=\(stillListed.map(String.init) ?? "-")")
        #expect(failure == nil)
        #expect(received == 6)
        #expect(deleteError == nil)
        #expect(stillListed == false)
        #expect(cleaned == true, "the throwaway bucket was left behind")
    }

    // MARK: Helpers

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// The text of the first `<name>...</name>`, or nil.
    static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
            let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    static func counts(_ xml: String) -> (versions: Int, markers: Int, prefixes: Int) {
        (
            occurrences(of: "<Version>", in: xml), occurrences(of: "<DeleteMarker>", in: xml),
            occurrences(of: "<CommonPrefixes>", in: xml)
        )
    }
}

// MARK: - The rig's bucket

/// A throwaway versioned bucket and the raw requests this suite sends it.
/// Minted names only (`macscp-vg-...`): `teardown()` refuses any other, so a
/// slip in a test cannot reach `macscp-seed`, `macscp-second` or
/// `macscp-probe-lock`.
private struct RigBucket {
    static let namePrefix = "macscp-vg-"
    static let reserved: Set<String> = ["macscp-seed", "macscp-second", "macscp-probe-lock"]

    let fs: S3FileSystem
    let bucket: String

    static func config(bucket: String) -> S3ConnectionConfig {
        var config = S3SettingsRig.config
        config.bucket = bucket
        return config
    }

    /// A new bucket with versioning ON (unless `versioned` is false), or nil
    /// after recording an issue when the rig would not make one.
    static func make(
        purpose: String, versioned: Bool = true, transport: (any HTTPTransport)? = nil
    ) async throws -> RigBucket? {
        let fs = try await S3FileSystem.connect(
            S3SettingsRig.config, transport: transport)
        let bucket = S3SettingsRig.throwawayBucketName(purpose: "vg-" + purpose)
        precondition(bucket.hasPrefix(namePrefix) && !reserved.contains(bucket))
        let created = try await S3SettingsRig.bucketRequest("PUT", bucket, in: fs)
        #expect((200..<300).contains(created), "the rig would not create a throwaway bucket")
        guard (200..<300).contains(created) else {
            await fs.disconnect()
            return nil
        }
        if versioned {
            try await fs.setVersioning(.enabled, ofBucket: bucket)
            // The control: versioning really is on, read back from the store.
            let state = try await fs.versioning(ofBucket: bucket)
            #expect(state == .enabled)
        }
        return RigBucket(fs: fs, bucket: bucket)
    }

    /// Every version and delete marker, then the bucket. `true` when the
    /// bucket is gone. Never touches a bucket this suite did not mint.
    func teardown() async -> Bool {
        guard bucket.hasPrefix(Self.namePrefix), !Self.reserved.contains(bucket) else { return false }
        // Up to three passes: a listing that is still non-empty after a pass
        // is reported by the bucket delete failing, which is the check.
        for _ in 0..<3 {
            guard let entries = try? await fs.versionEntries(inBucket: bucket, prefix: "", delimiter: nil),
                !entries.isEmpty
            else { break }
            for entry in entries {
                _ = try? await S3SettingsRig.objectRequest(
                    "DELETE", bucket: bucket, key: entry.key,
                    query: [(name: "versionId", value: entry.versionId)], in: fs)
            }
        }
        let status = try? await S3SettingsRig.bucketRequest("DELETE", bucket, in: fs)
        await fs.disconnect()
        return status.map { (200..<300).contains($0) } ?? false
    }

    /// A PUT; the new version's id.
    func put(_ key: String, _ body: Data) async throws -> String {
        let (_, response) = try await S3SettingsRig.objectRequest(
            "PUT", bucket: bucket, key: key, body: body, in: fs)
        #expect(response.statusCode == 200)
        return response.value(forHTTPHeaderField: "x-amz-version-id") ?? ""
    }

    func get(_ key: String, versionId: String? = nil) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await S3SettingsRig.objectRequest(
            "GET", bucket: bucket, key: key,
            query: versionId.map { [(name: "versionId", value: $0)] } ?? [], in: fs)
        return (response, data)
    }

    /// A plain `DELETE`: it leaves a marker, whose id is in the response.
    func delete(_ key: String) async throws -> HTTPURLResponse {
        try await S3SettingsRig.objectRequest("DELETE", bucket: bucket, key: key, in: fs).1
    }

    func deleteVersion(_ key: String, _ versionId: String) async throws -> HTTPURLResponse {
        try await S3SettingsRig.objectRequest(
            "DELETE", bucket: bucket, key: key,
            query: [(name: "versionId", value: versionId)], in: fs
        ).1
    }

    /// A raw server-side copy within the bucket. The header value is built
    /// the way a person following the store's documentation would write it,
    /// NOT through `S3FileSystem`, so the answer is the store's alone.
    func copy(_ key: String, from source: String, sourceVersionId: String?) async throws
        -> (Data, HTTPURLResponse)
    {
        var header = "/\(bucket)/\(source)"
        if let sourceVersionId { header += "?versionId=\(sourceVersionId)" }
        return try await S3SettingsRig.objectRequest(
            "PUT", bucket: bucket, key: key, extraHeaders: ["x-amz-copy-source": header],
            body: Data(), in: fs)
    }

    /// A multipart upload of `parts` (every part but the last must be at least
    /// 5 MiB); the resulting version id.
    func multipart(_ key: String, parts: [Data]) async throws -> String {
        let started = try await S3SettingsRig.objectRequest(
            "POST", bucket: bucket, key: key, query: [(name: "uploads", value: "")], in: fs)
        #expect(started.1.statusCode == 200)
        let uploadId = S3VersionsGatedTests.element("UploadId", in: String(decoding: started.0, as: UTF8.self)) ?? ""
        var completion = "<CompleteMultipartUpload>"
        for (index, part) in parts.enumerated() {
            let number = index + 1
            let (_, response) = try await S3SettingsRig.objectRequest(
                "PUT", bucket: bucket, key: key,
                query: [(name: "partNumber", value: String(number)), (name: "uploadId", value: uploadId)],
                body: part, in: fs)
            #expect(response.statusCode == 200)
            let tag = response.value(forHTTPHeaderField: "ETag") ?? ""
            completion += "<Part><PartNumber>\(number)</PartNumber><ETag>\(tag)</ETag></Part>"
        }
        completion += "</CompleteMultipartUpload>"
        let (_, done) = try await S3SettingsRig.objectRequest(
            "POST", bucket: bucket, key: key, query: [(name: "uploadId", value: uploadId)],
            body: Data(completion.utf8), in: fs)
        #expect(done.statusCode == 200)
        return done.value(forHTTPHeaderField: "x-amz-version-id") ?? ""
    }

    func rawVersionsAnswer(
        prefix: String, delimiter: String?, maxKeys: Int? = nil, keyMarker: String? = nil,
        versionIdMarker: String? = nil
    ) async throws -> (Int, String) {
        var query: [(name: String, value: String)] = [
            (name: "versions", value: ""), (name: "prefix", value: prefix),
        ]
        if let delimiter { query.append((name: "delimiter", value: delimiter)) }
        if let maxKeys { query.append((name: "max-keys", value: String(maxKeys))) }
        if let keyMarker { query.append((name: "key-marker", value: keyMarker)) }
        if let versionIdMarker { query.append((name: "version-id-marker", value: versionIdMarker)) }
        let request = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: "GET", query: query, config: S3SettingsRig.config)
        let (data, response) = try await fs.perform(request)
        return (response.statusCode, String(decoding: data, as: UTF8.self))
    }

    func rawVersions(
        prefix: String, delimiter: String?, maxKeys: Int? = nil, keyMarker: String? = nil,
        versionIdMarker: String? = nil
    ) async throws -> String {
        let answer = try await rawVersionsAnswer(
            prefix: prefix, delimiter: delimiter, maxKeys: maxKeys, keyMarker: keyMarker,
            versionIdMarker: versionIdMarker)
        #expect(answer.0 == 200)
        return answer.1
    }

    /// Which cache-related headers the two listings a tick sends come back
    /// with. A response with none of them is not cacheable by heuristic, so
    /// each tick reaches the store whatever cache the session keeps.
    func cacheHeadersOfTheTickListings() async throws -> [String] {
        let list = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: "GET",
            query: [(name: "list-type", value: "2"), (name: "delimiter", value: "/")],
            config: S3SettingsRig.config)
        let versions = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: "GET",
            query: [(name: "versions", value: ""), (name: "delimiter", value: "/")],
            config: S3SettingsRig.config)
        var found: [String] = []
        for request in [list, versions] {
            let response = try await fs.perform(request).1
            for name in ["Cache-Control", "Expires", "Last-Modified", "ETag", "Age"]
            where response.value(forHTTPHeaderField: name) != nil {
                found.append(name)
            }
        }
        return found
    }

    func rawList() async throws -> String {
        let request = try S3FileSystem.signedRequest(
            .bucketRoot(bucket: bucket), method: "GET",
            query: [(name: "list-type", value: "2"), (name: "delimiter", value: "/")],
            config: S3SettingsRig.config)
        let (data, _) = try await fs.perform(request)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Transports

/// A session with NO response cache, for the one place this suite needs a
/// transport of its own: `CountingTransport` has to wrap something, to see
/// what is sent. It is a second copy of what `S3HTTPChannel.ownSession` builds
/// (no `URLCache`, `reloadIgnoringLocalCacheData`) and exists for the count
/// alone; the requests that need no count run on the connection's own session
/// (`RigBucket.make` with no transport), which is what the product uses.
/// **Why that session has no cache, measured 2026-11-03**: on one that kept
/// the default, a write to a url an earlier buffered `GET` had left an entry
/// for was sent with that entry's validators and, on the rig, answered as a
/// read (`aDeleteOnASessionWithTheDefaultCacheIsAnswered...` below;
/// `S3StateChangeNeverFromCacheTests` holds the behaviour).
private enum UncachedTransport {
    static func make() -> URLSessionHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionHTTPTransport(session: URLSession(configuration: configuration))
    }
}

// MARK: - A transport that counts

/// The real transport, with a record of what was sent: the names of each
/// request's query items, joined with `&`, and nothing else (no host, no
/// value, no header). `list-type` marks a plain listing, `versions` a history
/// listing, `versioning` the versioning read.
private actor CountingTransport: HTTPTransport {
    private let inner = UncachedTransport.make()
    private var sent: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        return try await inner.send(request)
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        record(request)
        return try await inner.sendStreaming(request)
    }

    private func record(_ request: URLRequest) {
        let names = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.map(\.name).joined(separator: "&")
        sent.append((request.httpMethod ?? "?") + " " + (names ?? ""))
    }

    func reset() { sent = [] }
    func kinds() -> [String] { sent }
    func count(where matches: (String) -> Bool) -> Int { sent.filter(matches).count }
}
