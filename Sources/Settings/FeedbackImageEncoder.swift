import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Off-MainActor pipeline that turns picked image files into the
/// base64 `data:image/jpeg;base64,…` strings the feedback service
/// expects. The service's combined-images cap is 5 MB of base64-
/// encoded body, so the encoder iteratively lowers JPEG quality
/// (0.8 → 0.65 → 0.5 → 0.4) until the total fits — or throws
/// `.tooLarge` if even the floor doesn't fit, in which case the
/// composer surfaces the inline error and asks the user to remove
/// one.
///
/// Decoding goes through `CGImageSourceCreateThumbnailAtIndex` with
/// `kCGImageSourceThumbnailMaxPixelSize = 2048` so a 4K screenshot
/// is downsampled in one shot during decode rather than after.
/// EXIF orientation is honored via
/// `kCGImageSourceCreateThumbnailWithTransform` so a phone
/// screenshot pasted in rotated 90° comes out correctly oriented.
enum FeedbackImageEncoder {

    /// Longer-edge ceiling (in pixels). Screenshots are typically
    /// captured at 2× / 3× backing scale; a 2048-pixel longer edge
    /// gives ~1024pt of visible detail even on a Retina display,
    /// which is plenty for bug reports.
    static let maxLongerEdgePixels: Int = 2048

    /// Server-side combined-images cap. Matches the OpenAPI
    /// contract: counted against the sum of base64-encoded lengths,
    /// not the underlying JPEG bytes (data URIs add ~33%
    /// transport overhead, so the encoder must do its accounting
    /// against the base64 length).
    static let maxCombinedBase64Bytes: Int = 5 * 1024 * 1024

    /// Quality steps walked in order until the combined size fits.
    /// Below 0.4 the artifacts start to obscure UI text in
    /// screenshots — past that we'd rather ask the user to remove
    /// an image than ship illegible bug-report material.
    static let qualityLadder: [Double] = [0.8, 0.65, 0.5, 0.4]

    /// Decode → downsample → iteratively encode. Plain
    /// non-isolated `async` (not `Task.detached`) so cancellation
    /// from the caller's task propagates here via Swift's
    /// task-local cancellation: when the composer cancels its
    /// `encodeTask` because the user picked a fresh set of
    /// screenshots, the in-flight encode notices on its next
    /// `Task.checkCancellation()` and bails without spending
    /// further CPU. The actual CPU work runs off the main thread
    /// because this enum is not `@MainActor` isolated — the
    /// MainActor caller awaits, suspends, and the cooperative
    /// thread pool runs the body.
    static func encode(urls: [URL]) async throws -> [String] {
        try Task.checkCancellation()

        // Decode + downsample once per image. The downsample
        // happens inside CGImageSourceCreateThumbnailAtIndex so
        // we never hold the full-resolution CGImage in memory
        // for a 4K-or-larger source.
        var images: [CGImage] = []
        images.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw FeedbackImageEncoderError.unreadable(url.lastPathComponent)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongerEdgePixels,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw FeedbackImageEncoderError.unreadable(url.lastPathComponent)
            }
            images.append(cg)
        }

        // Walk the quality ladder. The first level whose
        // combined base64 length fits under the cap wins.
        for quality in qualityLadder {
            try Task.checkCancellation()
            var encoded: [String] = []
            encoded.reserveCapacity(images.count)
            var totalBase64Bytes = 0
            for cg in images {
                let dataURI = try jpegDataURI(cgImage: cg, quality: quality)
                totalBase64Bytes += dataURI.utf8.count
                encoded.append(dataURI)
            }
            if totalBase64Bytes <= maxCombinedBase64Bytes {
                return encoded
            }
        }

        throw FeedbackImageEncoderError.tooLarge
    }

    /// JPEG-encode a single CGImage at the requested quality and
    /// return the `data:image/jpeg;base64,…` URI the server
    /// expects. Throws `.encodeFailed` if ImageIO can't produce a
    /// JPEG (e.g. a CGImage in a colorspace it refuses to
    /// transcode) — caller surfaces a generic error to the user.
    private static func jpegDataURI(cgImage: CGImage, quality: Double) throws -> String {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FeedbackImageEncoderError.encodeFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FeedbackImageEncoderError.encodeFailed
        }
        let base64 = (buffer as Data).base64EncodedString()
        return "data:image/jpeg;base64,\(base64)"
    }
}

/// User-facing encoder errors. The composer's inline error row
/// surfaces `localizedDescription` verbatim so wording lives here
/// rather than in the view.
enum FeedbackImageEncoderError: LocalizedError {
    case unreadable(String)
    case tooLarge
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Couldn't read \"\(name)\". The file may be corrupted or in an unsupported format."
        case .tooLarge:
            return "Screenshots are too large to upload (limit 5 MB total). Try fewer or smaller images."
        case .encodeFailed:
            return "Couldn't encode one of the selected screenshots."
        }
    }
}
