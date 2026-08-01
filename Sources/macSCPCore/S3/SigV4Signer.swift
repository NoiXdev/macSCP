import Crypto
import Foundation

/// AWS Signature Version 4 request signer, built entirely over swift-crypto
/// (`HMAC<SHA256>`, `SHA256`) — no networking, no I/O, deterministic.
///
/// Implements the standard SigV4 steps: canonical request, string-to-sign,
/// the HMAC-SHA256 signing-key chain, and the final `Authorization` header.
/// See the AWS SigV4 reference: https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
public struct SigV4Signer: Sendable {
    /// SHA256 hex digest of the empty string — the canonical "no body" payload hash.
    public static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private let accessKeyID: String
    private let secretAccessKey: String
    private let region: String
    private let service: String
    private let sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, region: String,
                service: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.service = service
        self.sessionToken = sessionToken
    }

    /// Compute the `Authorization` header value and the companion headers
    /// (`x-amz-date`, `x-amz-content-sha256`, and — when a session token is
    /// present — `x-amz-security-token`) for a single request.
    ///
    /// - Parameters:
    ///   - query: Query parameters as `(name, value)` pairs; order does not
    ///     matter, they are sorted for canonicalization.
    ///   - headers: Additional headers to include in the signature (besides
    ///     the always-signed `host` and `x-amz-date`, and — when present —
    ///     `x-amz-security-token`). Keys are case-insensitive.
    public func authorizationHeader(
        method: String, host: String, path: String,
        query: [(name: String, value: String)], headers: [String: String],
        payloadHash: String, date: Date
    ) -> (authorization: String, extraHeaders: [String: String]) {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)

        // Merge caller headers with the always-signed ones (host, x-amz-date,
        // and x-amz-security-token when a session token is present). Keys are
        // lowercased and last-write-wins so the mandatory values are authoritative.
        var mergedHeaders: [String: String] = [:]
        for (key, value) in headers {
            mergedHeaders[key.lowercased()] = value
        }
        mergedHeaders["host"] = host
        mergedHeaders["x-amz-date"] = amzDate
        if let sessionToken {
            mergedHeaders["x-amz-security-token"] = sessionToken
        }

        let sortedKeys = mergedHeaders.keys.sorted()
        let canonicalHeadersBlock = sortedKeys
            .map { key -> String in
                let trimmedValue = mergedHeaders[key]!.trimmingCharacters(in: .whitespaces)
                return "\(key):\(trimmedValue)\n"
            }
            .joined()
        let signedHeaders = sortedKeys.joined(separator: ";")

        let canonicalURI = Self.canonicalURI(path: path)
        let canonicalQueryString = Self.canonicalQueryString(query: query)

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeadersBlock,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let canonicalRequestHash = Self.hexSHA256(Data(canonicalRequest.utf8))
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            canonicalRequestHash,
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp,
                                          region: region, service: service)
        let signature = Self.hexHMAC(key: signingKey, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var extraHeaders: [String: String] = [
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
        ]
        if let sessionToken {
            extraHeaders["x-amz-security-token"] = sessionToken
        }

        return (authorization, extraHeaders)
    }

    // MARK: - Signing key chain

    private static func signingKey(secretAccessKey: String, dateStamp: String,
                                    region: String, service: String) -> Data {
        let kSecret = Data(("AWS4" + secretAccessKey).utf8)
        let kDate = hmac(key: kSecret, data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = hmac(key: kService, data: Data("aws4_request".utf8))
        return kSigning
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func hexHMAC(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Widened to `internal` so `S3Uploader` can compute the REAL content
    /// SHA-256 for a PUT body's `x-amz-content-sha256` (M13/T5) using the
    /// exact same digest implementation the signer itself uses to hash the
    /// canonical request — one SHA-256 implementation, not two.
    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Canonicalization

    /// Widened to `internal` (like `canonicalQueryString`) so `S3FileSystem`
    /// can percent-encode an OBJECT KEY path segment-by-segment with the
    /// EXACT same RFC-3986 rules the signer uses to canonicalize the path it
    /// signs — reusing this instead of re-implementing the encoding keeps
    /// the signed and wire paths byte-identical by construction (same
    /// reasoning as M12 review I-1's query fix).
    static func canonicalURI(path: String) -> String {
        if path.isEmpty { return "/" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { rfc3986Encode(String($0)) }
        return encoded.joined(separator: "/")
    }

    /// Widened to `internal` so `S3FileSystem` can build the WIRE query
    /// with this exact same RFC-3986 encoding + sort order, keeping the
    /// signed and sent queries byte-identical (see M12 review I-1: a
    /// `URLComponents`-encoded wire query left `+` un-escaped, so it
    /// diverged from what was signed here whenever a value — e.g. a
    /// base64 `continuation-token` — contained one).
    static func canonicalQueryString(query: [(name: String, value: String)]) -> String {
        guard !query.isEmpty else { return "" }
        let encodedPairs = query.map { (rfc3986Encode($0.name), rfc3986Encode($0.value)) }
        let sorted = encodedPairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// RFC 3986 percent-encoding: unreserved characters (`A-Za-z0-9-._~`) are
    /// left literal; everything else becomes an uppercase-hex `%XX` escape.
    private static func rfc3986Encode(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            if isUnreserved(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    // MARK: - Date formatting (UTC, POSIX locale — never the device locale/timezone)

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
