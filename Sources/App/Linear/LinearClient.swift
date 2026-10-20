import Foundation

/// GraphQL transport for `api.linear.app`.
///
/// Ported from Inbox & Chill's `LinearConnector.execute`, which separates
/// network, HTTP, GraphQL and decode failures into distinct cases — worth
/// keeping, because "Linear isn't working" is four different bugs and the
/// panel has to say which one.
///
/// **One deliberate divergence from I&C:** variables are `[String: JSONValue]`,
/// not `[String: String]`. See `JSONValue`.
actor LinearClient {
    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

    private let session: URLSession
    /// Reads the key each call rather than caching it, so pasting a new key in
    /// Settings takes effect on the next poll with no restart and no wiring.
    private let keyProvider: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        keyProvider: @escaping @Sendable () -> String? = { Keychain.get(Keychain.apiKeyAccount) }
    ) {
        self.session = session
        self.keyProvider = keyProvider
    }

    // MARK: Errors

    enum Failure: Error, LocalizedError, CustomStringConvertible, Sendable {
        case missingAPIKey
        case transport(String)
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case httpError(status: Int, body: String)
        case graphQLErrors([String])
        case decodingFailed(String)

        var description: String { errorDescription ?? "Linear request failed" }

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "No Linear API key. Add a personal API key in Settings — Linear → Settings → Security & access → Personal API keys."
            case .transport(let detail):
                "Couldn't reach Linear: \(detail)"
            case .unauthorized:
                "Linear rejected the API key. Check it in Settings — it may have been revoked."
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    "Linear is rate-limiting. Retrying in \(Int(retryAfter))s."
                } else {
                    "Linear is rate-limiting. Backing off."
                }
            case .httpError(let status, let body):
                "Linear returned HTTP \(status): \(body.prefix(200))"
            case .graphQLErrors(let messages):
                "Linear rejected the request: \(messages.joined(separator: "; "))"
            case .decodingFailed(let detail):
                "Couldn't read Linear's response: \(detail)"
            }
        }

        /// Whether retrying the same request could plausibly succeed. A bad key
        /// is not worth hammering; a dropped connection is.
        var isTransient: Bool {
            switch self {
            case .transport, .rateLimited: true
            case .httpError(let status, _): status >= 500
            case .missingAPIKey, .unauthorized, .graphQLErrors, .decodingFailed: false
            }
        }
    }

    // MARK: Execute

    func execute<T: Decodable & Sendable>(
        _ document: String,
        variables: [String: JSONValue]? = nil,
        as _: T.Type = T.self
    ) async throws -> T {
        guard let key = keyProvider(), !key.isEmpty else { throw Failure.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // A personal API key is sent raw, with no `Bearer` prefix. That is
        // Linear's documented shape and it is easy to "fix" into a 401.
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Lineado", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            GraphQLRequestBody(query: document, variables: variables))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `String(describing:)` on a URLError includes the failing URL. That
            // is safe here — the key rides in a header, never the query string —
            // but it is the reason the key must never move into the URL.
            throw Failure.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw Failure.unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw Failure.rateLimited(retryAfter: retryAfter)
        default:
            throw Failure.httpError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        let decoded: GraphQLResponse<T>
        do {
            decoded = try JSONDecoder.linear.decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw Failure.decodingFailed(String(describing: error))
        }

        // A GraphQL 200 can still be a failure, and a partial success carries
        // both `data` and `errors`. Errors win: a half-decoded issue list that
        // silently drops rows is the worst outcome available here.
        if let errors = decoded.errors, !errors.isEmpty {
            throw Failure.graphQLErrors(errors.map(\.message))
        }
        guard let payload = decoded.data else {
            throw Failure.decodingFailed("response carried neither data nor errors")
        }
        return payload
    }
}

// MARK: - Envelopes

struct GraphQLRequestBody: Encodable, Sendable {
    var query: String
    var variables: [String: JSONValue]?
}

struct GraphQLResponse<T: Decodable & Sendable>: Decodable, Sendable {
    var data: T?
    var errors: [GraphQLErrorMessage]?
}

struct GraphQLErrorMessage: Decodable, Sendable {
    var message: String
}

// MARK: - JSONValue

/// A GraphQL variable value.
///
/// **Why this exists, and why copying I&C here would be a bug.** Inbox & Chill
/// types its variables `[String: String]`, with a comment explaining that every
/// argument it sends is an id or an ISO8601 timestamp. True there. Not true
/// here, for two reasons:
///
/// 1. `issueUpdate(input: { priority: })` takes an `Int`. A quoted `"2"` is a
///    type error, not a coercion.
/// 2. **Clearing a due date requires sending an explicit JSON `null`.** A
///    `[String: String]` map cannot express that at all — it can only omit the
///    key, and an omitted key in `issueUpdate` means "leave unchanged". So on
///    that map, "clear the due date" and "do nothing" are the same request.
enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// `nil` becomes an explicit JSON null rather than an absent key.
    init(_ value: String?) {
        self = value.map(JSONValue.string) ?? .null
    }
}

// MARK: - Decoding

extension JSONDecoder {
    /// Linear sends ISO8601 with fractional seconds (`2026-10-20T13:50:52.039Z`).
    /// `.iso8601` alone rejects the fraction, which fails the whole poll.
    static let linear: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) ?? plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unparseable date \(raw)"))
        }
        return decoder
    }()
}
