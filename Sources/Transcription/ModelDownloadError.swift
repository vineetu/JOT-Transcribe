import Foundation

/// Classifies failures from `ModelDownloader`. Shaped for UI consumption —
/// each case corresponds to a message a download surface (Setup Wizard,
/// Settings, the switch banner) can show WITHOUT additional interpretation.
///
/// Design note (2026-07-16): a HuggingFace outage (HTTP 504 / timeouts) used to
/// collapse into a single "check your network connection" message — actively
/// wrong on a working connection — and the `unknown` case interpolated the raw
/// underlying error, which leaked HuggingFace's HTML error page into the UI.
/// So the taxonomy now distinguishes `offline` (the user must act) from
/// `serverUnavailable` (the host is down; auto-retry, keep the current model),
/// and NO case ever renders a raw response body. The underlying error is kept
/// on `unknown` for LOGGING only — never for display.
public enum ModelDownloadError: Error, LocalizedError, Sendable {
    /// The device has no working internet connection. The user must reconnect.
    case offline
    /// The model host answered with a server-side failure or didn't answer at
    /// all (5xx / 429 / timeout / connection dropped). This is on the host's
    /// end, not the user's connection — callers should keep the current model
    /// and auto-retry with backoff.
    case serverUnavailable
    case diskFull
    case corrupted
    case canceled
    /// Anything unclassified. Carries the underlying error for LOGGING ONLY —
    /// `errorDescription` deliberately never renders it, so a stray HTML body
    /// or stack text can't reach the user.
    case unknown(any Error)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "You're offline. Connect to the internet and Jot will finish the download."
        case .serverUnavailable:
            return "The model server is temporarily unavailable. Jot will retry when it's back."
        case .diskFull:
            return "Not enough disk space to download the transcription model. Free up some space and try again."
        case .corrupted:
            return "The downloaded model files were incomplete. Jot will retry from the start."
        case .canceled:
            return "Model download was canceled."
        case .unknown:
            // Intentionally generic: never interpolate the underlying error —
            // it may contain an HTML error page or other unshowable text.
            return "The model download didn't complete. Please try again."
        }
    }

    /// A short, log-safe tag for telemetry-free structured logging. The
    /// underlying error text (if any) is logged separately by the caller via
    /// the redaction helpers — never surfaced to the user.
    public var logTag: String {
        switch self {
        case .offline: return "offline"
        case .serverUnavailable: return "server_unavailable"
        case .diskFull: return "disk_full"
        case .corrupted: return "corrupted"
        case .canceled: return "canceled"
        case .unknown: return "unknown"
        }
    }

    /// True when the right response is to keep the current model and retry
    /// automatically (with backoff) rather than surface a dead-end. A host
    /// outage or a transient corrupt fetch self-heals; offline/diskFull need
    /// the user to act; canceled was intentional.
    public var isRetriable: Bool {
        switch self {
        case .serverUnavailable, .corrupted: return true
        case .offline, .diskFull, .canceled, .unknown: return false
        }
    }

    /// Map a thrown error from the network / filesystem layer into a
    /// ModelDownloadError case.
    static func classify(_ error: any Error) -> ModelDownloadError {
        if let existing = error as? ModelDownloadError {
            return existing
        }

        if error is CancellationError {
            return .canceled
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorInternationalRoamingOff:
                // Genuinely no local connectivity — the user must reconnect.
                return .offline
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorBadServerResponse,
                 NSURLErrorHTTPTooManyRedirects,
                 NSURLErrorResourceUnavailable:
                // The connection works but the host didn't respond usefully —
                // treat as a host-side outage (auto-retry), not the user's Wi-Fi.
                return .serverUnavailable
            case NSURLErrorCancelled:
                return .canceled
            default:
                break
            }
        }

        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return .diskFull
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError:
                return .diskFull
            case NSUserCancelledError:
                return .canceled
            default:
                break
            }
        }

        // The SDK (FluidAudio) surfaces HTTP failures as its own error types
        // whose text carries the status code (e.g. "Unexpected response
        // (status 504)…", "rate limited", "429"). We can't import those types,
        // so match the well-known server-outage markers in the error text and
        // route them to serverUnavailable (auto-retry) rather than letting them
        // fall through to `unknown`. This also stops a HuggingFace HTML 504 from
        // ever being the classification of record. Matching is deliberately
        // specific to avoid false positives from byte counts, etc.
        if mentionsServerOutage(String(describing: error)) {
            return .serverUnavailable
        }

        return .unknown(error)
    }

    /// Heuristic: does this error text describe a server-side outage / throttle?
    /// Specific phrases only — never bare "5xx-looking" numbers, which collide
    /// with byte counts and IDs.
    private static func mentionsServerOutage(_ text: String) -> Bool {
        let t = text.lowercased()
        let markers = [
            "status 500", "status 502", "status 503", "status 504", "status 429",
            "status: 500", "status: 502", "status: 503", "status: 504", "status: 429",
            "(status 5", "statuscode: 5", "statuscode: 429",
            "rate limit", "ratelimited", "too many requests",
            "service unavailable", "gateway timeout", "bad gateway",
            "internal server error", "server is down", "temporarily unavailable",
        ]
        return markers.contains { t.contains($0) }
    }
}
