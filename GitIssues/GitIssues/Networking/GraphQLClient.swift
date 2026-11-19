//
//  GraphQLClient.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

enum GraphQLError: LocalizedError {
    case noAccessToken
    case invalidURL
    case networkError(Error)
    case serverError(String)
    case decodingError(Error)
    case graphQLErrors([String])
    case unauthorized
    case rateLimited(reset: Date?)
    /// GitHub reported the requested object does not exist (e.g. an issue deleted elsewhere).
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "This item no longer exists on GitHub."
        case .noAccessToken:
            return "No access token available. Please sign in."
        case .invalidURL:
            return "Invalid API URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .graphQLErrors(let errors):
            return "GraphQL errors: \(errors.joined(separator: ", "))"

        case .unauthorized:
            return "Your GitHub session has expired or was revoked. Please reconnect to GitHub."
        case .rateLimited(let reset):
            if let reset {
                let df = DateFormatter()
                df.dateStyle = .none
                df.timeStyle = .short
                return "GitHub rate limit exceeded. Try again after \(df.string(from: reset))."
            }
            return "GitHub rate limit exceeded. Please try again later."
        }
    }
}

struct GraphQLRequest<T: Codable>: Codable {
    let query: String
    let variables: [String: AnyCodable]?

    init(query: String, variables: [String: Any]? = nil) {
        self.query = query
        self.variables = variables?.mapValues { AnyCodable($0) }
    }
}

struct GraphQLResponse<T: Codable>: Codable {
    let data: T?
    let errors: [GraphQLResponseError]?
}

struct GraphQLResponseError: Codable {
    let message: String
    /// GitHub's machine-readable error class, e.g. `NOT_FOUND`, `FORBIDDEN`.
    let type: String?

    var isNotFound: Bool { type == "NOT_FOUND" }

    let path: [String]?
    let locations: [Location]?

    struct Location: Codable {
        let line: Int
        let column: Int
    }
}

// Helper to encode Any values
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

class GraphQLClient {
    private static let userAgent: String = {
        let bid = Bundle.main.bundleIdentifier ?? "GitIssues"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "GitIssues/\(ver) (\(bid); build \(build))"
    }()

    private let endpoint = "https://api.github.com/graphql"
    private let accessToken: String

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    /// The operation name in a GraphQL document (e.g. `AllIssues`), for logging. Documents that
    /// contain several operations (aliased mutations) report the first one.
    private static func operationName(in query: String) -> String {
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == "{" })
        for (index, token) in tokens.enumerated() where token == "query" || token == "mutation" {
            if index + 1 < tokens.count { return String(tokens[index + 1]) }
        }
        return "anonymous"
    }

    /// Executes a GraphQL query and decodes `data`.
    /// - Parameter tolerateErrors: When `true`, a response that carries both `errors` and usable
    ///   `data` (GitHub reports e.g. an unreadable cross-referenced repository this way) is
    ///   returned with the errors logged, instead of failing the whole request.
    func execute<T: Codable>(
        query: String,
        variables: [String: Any]? = nil,
        tolerateErrors: Bool = false
    ) async throws -> T {
        guard let url = URL(string: endpoint) else {
            throw GraphQLError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let graphQLRequest = GraphQLRequest<T>(query: query, variables: variables)
        request.httpBody = try JSONEncoder().encode(graphQLRequest)

        // Perf instrumentation (issue #109): one line per call with network, size and decode time.
        let operation = Self.operationName(in: query)
        let networkTimer = PerfTimer()
        var networkMs = 0.0
        var decodeMs = 0.0
        var bytes = 0
        var status = 0
        defer {
            PerfTimer.log(
                "graphql \(operation)",
                networkTimer,
                "net=\(PerfTimer.format(networkMs))ms decode=\(PerfTimer.format(decodeMs))ms bytes=\(bytes) http=\(status)"
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        networkMs = networkTimer.elapsedMs
        bytes = data.count

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphQLError.serverError("Invalid response")
        }
        status = httpResponse.statusCode

        // Handle common HTTP errors
        if httpResponse.statusCode == 401 {
            AppLogger.shared.error("GraphQL request unauthorized (HTTP 401)")
            throw GraphQLError.unauthorized
        }
        if httpResponse.statusCode == 403 {
            let remaining = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if remaining == "0" {
                let resetStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset")
                let resetDate = resetStr.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
                AppLogger.shared.warning("GraphQL request rate limited (resets \(resetDate.map { "\($0)" } ?? "unknown"))")
                throw GraphQLError.rateLimited(reset: resetDate)
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            AppLogger.shared.error("GraphQL request failed with HTTP \(httpResponse.statusCode)")
            throw GraphQLError.serverError("HTTP \(httpResponse.statusCode)")
        }

        // Configure decoder for ISO8601 dates
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decodeTimer = PerfTimer()
        defer { decodeMs = decodeTimer.elapsedMs }

        do {
            let graphQLResponse = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = graphQLResponse.errors, !errors.isEmpty {
                let errorMessages = errors.map { $0.message }
                if tolerateErrors, let partial = graphQLResponse.data {
                    AppLogger.shared.warning("GraphQL partial errors (using partial data): \(errorMessages.joined(separator: "; "))")
                    return partial
                }
                AppLogger.shared.error("GraphQL errors: \(errorMessages.joined(separator: "; "))")
                if errors.contains(where: { $0.isNotFound }) {
                    throw GraphQLError.notFound
                }
                throw GraphQLError.graphQLErrors(errorMessages)
            }

            guard let data = graphQLResponse.data else {
                throw GraphQLError.serverError("No data in response")
            }

            return data
        } catch let error as DecodingError {
            // Log detailed decoding error to help diagnose schema/response mismatches.
            let json = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            AppLogger.shared.error("GraphQL decoding error: \(error)")
            AppLogger.shared.debug("GraphQL response JSON: \(json)")
            throw GraphQLError.decodingError(error)
        }
    }
}
