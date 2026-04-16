import Foundation

/// Classifies failures from `ModelDownloader`. Shaped for UI consumption —
/// each case corresponds to a message the Setup Wizard can surface without
/// additional interpretation.
public enum ModelDownloadError: Error, LocalizedError, Sendable {
    case networkUnreachable
    case diskFull
    case corrupted
    case canceled
    case unknown(any Error)

    public var errorDescription: String? {
        switch self {
        case .networkUnreachable:
            return "Can't reach the model host. Check your network connection and try again."
        case .diskFull:
            return "Not enough disk space to download the transcription model."
        case .corrupted:
            return "The downloaded model files are corrupted. Try again."
        case .canceled:
            return "Model download was canceled."
        case .unknown(let error):
            return "Model download failed: \(error.localizedDescription)"
        }
    }

    /// Map a thrown error from the network / filesystem layer into a
    /// ModelDownloadError case.
    static func classify(_ error: any Error) -> ModelDownloadError {
        if let existing = error as? ModelDownloadError {
            return existing
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut:
                return .networkUnreachable
            case NSURLErrorCancelled:
                return .canceled
            default:
                return .unknown(error)
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

        if error is CancellationError {
            return .canceled
        }

        return .unknown(error)
    }
}
