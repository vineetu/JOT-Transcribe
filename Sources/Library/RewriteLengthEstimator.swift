import Foundation
import SwiftData

/// Estimates how long a rewrite's OUTPUT will be, so the pill can show real
/// progress instead of an indeterminate spinner.
///
/// Self-calibrating: every rewrite is already persisted as a `RewriteSession`
/// with both its selection and its output, so the ratio is measured from the
/// user's own history per prompt rather than hard-coded. It gets more accurate
/// the more a given prompt is used, and needs no model.
///
/// Measured on one real 280-session corpus:
///
///     instruction          n   median   p10    p90   spread
///     Rewrite            101    1.00   0.90   1.12    1.2x   <- estimable
///     Rewrite this        58    1.00   0.87   1.07    1.2x   <- estimable
///     Improve writing      8    0.94   0.79   0.99    1.3x   <- estimable
///     Extract key points  33    0.92   0.16   1.24    7.6x   <- NOT estimable
///
/// "Extract key points" is why this returns an optional. Compression-style
/// prompts have no usable length prior, and a bar driven by one would race to
/// full and stall. Better to admit ignorance and stay indeterminate.
enum RewriteLengthEstimator {

    /// Minimum samples before trusting a per-prompt ratio. Below this the
    /// median is noise — "Make formal" at n=4 showed a 2.0x spread.
    static let minimumSamples = 8

    /// Reject a prompt whose p90/p10 exceeds this. 7.6x (extraction) is out;
    /// 1.2x (rewrite) is comfortably in.
    static let maximumSpread = 2.0

    /// Expected output length in characters, or nil when this prompt's history
    /// does not support an estimate.
    @MainActor
    static func expectedOutputCharacters(
        selectionLength: Int,
        instruction: String,
        context: ModelContext?
    ) -> Int? {
        guard selectionLength > 0, let context else { return nil }
        let key = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        var descriptor = FetchDescriptor<RewriteSession>(
            predicate: #Predicate { $0.instructionText == key },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Recent history only: a prompt's behaviour changes when its body is
        // edited, and stale samples would keep dragging the estimate back.
        descriptor.fetchLimit = 80
        guard let rows = try? context.fetch(descriptor) else { return nil }

        let ratios = rows
            .filter { $0.selectionText.count >= 20 && !$0.output.isEmpty }
            .map { Double($0.output.count) / Double($0.selectionText.count) }
            .sorted()
        guard ratios.count >= minimumSamples else { return nil }

        let p10 = ratios[Int(Double(ratios.count) * 0.10)]
        let p90 = ratios[min(ratios.count - 1, Int(Double(ratios.count) * 0.90))]
        guard p10 > 0, p90 / p10 <= maximumSpread else { return nil }

        let median = ratios[ratios.count / 2]
        guard median > 0 else { return nil }
        return Int(Double(selectionLength) * median)
    }
}
