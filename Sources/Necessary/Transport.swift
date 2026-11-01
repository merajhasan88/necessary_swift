import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How the SDK's messages reach your backend: it sends one request and answers your backend's JSON
/// object. A refusal is thrown as an `APIError` with the backend's `code`, `message` and `details`
/// (the integration guide, section 4, Errors).
@MainActor
public protocol DeviceTrustTransport: AnyObject {
    /// `encodedBody` is sent exactly as given: it is what a request proof hashes. A GET sends no
    /// body. `path` is the path under the backend, with its query.
    func send(_ method: String, _ path: String, encodedBody: String?, bearerToken: String?,
              headers: [String: String]) async throws -> JSONObject

    func close()
}

/// JSON over HTTPS under `baseURL`, the SDK's default transport. A release build refuses any other
/// scheme, so a mistyped endpoint fails loudly instead of sending tokens in the clear. Each call has
/// `timeout` seconds, 15 unless you say otherwise, from its start to its answer.
@MainActor
public final class HTTPTransport: DeviceTrustTransport {
    public let baseURL: String
    public let timeout: TimeInterval
    private let session: URLSession
    private var closed = false

    /// `session` replaces the transport's own: one whose delegate evaluates the server's
    /// certificate, say. The transport's own keeps no cookies and caches nothing.
    public init(baseURL: String, session: URLSession? = nil, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.session = session ?? URLSession(configuration: HTTPTransport.configuration(timeout))
    }

    private static func configuration(_ timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    /// The base URL with no `/` at its end, or why it cannot be used.
    func base() throws -> String {
        if baseURL.isEmpty {
            throw APIError("No API base URL was set for the backend.", code: "api_base_url_missing")
        }
        #if !DEBUG
        if !baseURL.lowercased().hasPrefix("https://") {
            throw APIError("The API base URL must be an https:// URL in a release build.",
                           code: "api_base_url_insecure")
        }
        #endif
        return baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    public func send(_ method: String, _ path: String, encodedBody: String?, bearerToken: String?,
                     headers: [String: String]) async throws -> JSONObject {
        let address = try base() + RequestTarget(path).pathAndQuery
        guard let url = URL(string: address) else {
            throw UsageError.invalidArgument("\(address) is not a URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if method != "GET" {
            request.httpBody = Data((encodedBody ?? "{}").utf8)
        }
        guard !closed else {
            throw APIError("HTTP connection failed: the transport is closed.")
        }

        let (data, status) = try await perform(request)

        var decoded = JSONObject()
        let text = String(decoding: data, as: UTF8.self)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                decoded = try JSONObject(parsing: data)
            } catch {
                throw APIError("The server returned a non-JSON response.", statusCode: status)
            }
        }
        if status < 200 || status >= 300 {
            let refusal = decoded["error"]?.objectValue
            throw APIError(
                refusal?["message"]?.stringValue ?? "The server rejected the request (\(status)).",
                statusCode: status,
                code: refusal?["code"]?.stringValue,
                details: refusal?["details"]?.objectValue)
        }
        return decoded
    }

    /// The request's answer, or the failure on the way -- within `timeout` from its start.
    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let session = self.session
        let limit = timeout
        do {
            return try await withThrowingTaskGroup(of: (Data, Int)?.self) { group in
                group.addTask {
                    try await HTTPTransport.load(request, with: session)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let answer = first else {
                    throw URLError(.timedOut)
                }
                return answer
            }
        } catch let error as URLError where error.code == .timedOut {
            throw APIError("The server did not respond before the timeout.")
        } catch let error as URLError where error.code == .cancelled {
            throw APIError("HTTP connection failed: \(error.localizedDescription)")
        } catch let error as URLError {
            throw APIError("Network connection failed: \(error.localizedDescription)")
        } catch is CancellationError {
            throw APIError("HTTP connection failed: the call was cancelled.")
        }
    }

    private nonisolated static func load(_ request: URLRequest, with session: URLSession) async throws -> (Data, Int) {
        final class Box: @unchecked Sendable { var task: URLSessionDataTask? }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), response.statusCode))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    public func close() {
        closed = true
        session.invalidateAndCancel()
    }
}
