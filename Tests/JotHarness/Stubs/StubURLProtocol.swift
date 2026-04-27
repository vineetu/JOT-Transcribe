import Foundation
@testable import Jot

/// Harness conformer for the URLSession seam. Subclasses `URLProtocol`
/// and matches request URLs against a class-level registry of canned
/// responses, so the harness can intercept every cloud HTTP call (LLM
/// providers, Flavor1) without reaching the network.
///
/// **Registration:** flow methods install the stub on a per-test
/// `URLSessionConfiguration` via `URLProtocol.registerClass(...)`, then
/// call `enqueue(host:response:)` to seed responses keyed by host (or
/// any URL substring). Lookups are first-match-by-substring against
/// `request.url?.absoluteString`, with the matched response consumed
/// from the queue.
///
/// **`Sendable` discipline:** `URLProtocol` is `@objc`, so we can't
/// annotate the subclass `Sendable` directly. The shared registry is
/// guarded by an `NSLock`; `enqueue(...)` / `dequeue(...)` are
/// thread-safe.
final class StubURLProtocol: URLProtocol {
    // MARK: - Canned response shape

    struct CannedResponse: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
        /// Optional artificial delay before the response starts. Used
        /// by `OpenAISeed.timesOut(after:)` to drive
        /// `firstByteOrTimeout` flows.
        let delay: Duration

        init(
            statusCode: Int,
            body: Data,
            headers: [String: String] = ["Content-Type": "application/json"],
            delay: Duration = .zero
        ) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
            self.delay = delay
        }
    }

    // MARK: - Class-level registry

    private static let lock = NSLock()
    private static var pending: [(matcher: String, response: CannedResponse)] = []

    /// Enqueue a canned response. `matcher` is a substring tested
    /// against `request.url?.absoluteString` (typically a host or a
    /// path fragment like "/v1/chat/completions").
    static func enqueue(matcher: String, response: CannedResponse) {
        lock.lock()
        defer { lock.unlock() }
        pending.append((matcher, response))
    }

    /// Drop every queued response. Flow methods call this in
    /// `tearDown` to keep tests independent.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }

    /// Drop only the queued responses whose `matcher` contains
    /// `substring`. Lets a flow method reset its own bucket
    /// (`"chat/completions"` for articulate / askJot, etc.) without
    /// wiping a sibling test's distinct enqueue (e.g. the
    /// `stubURLProtocol_servesCannedResponse` smoke test, which
    /// uses `"example.com"` as its matcher).
    static func removeMatching(_ substring: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll { $0.matcher.contains(substring) }
    }

    private static func dequeue(for url: URL) -> CannedResponse? {
        lock.lock()
        defer { lock.unlock() }
        let absolute = url.absoluteString
        // Empty matcher means "match anything" — `String.contains("")`
        // returns `false` in Swift, so `""` would never match without
        // this special case. The harness uses `""` as a wildcard in
        // tests where every URL through the stub session belongs to
        // the test.
        guard let index = pending.firstIndex(where: { match in
            match.matcher.isEmpty || absolute.contains(match.matcher)
        }) else {
            return nil
        }
        return pending.remove(at: index).response
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        guard let canned = Self.dequeue(for: url) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        Task {
            if canned.delay != .zero {
                try? await Task.sleep(for: canned.delay)
            }

            guard !Task.isCancelled else {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }

            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: canned.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: canned.headers
            )!
            client?.urlProtocol(
                self,
                didReceive: httpResponse,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: canned.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        // No-op — the response Task respects `Task.isCancelled`.
    }
}
