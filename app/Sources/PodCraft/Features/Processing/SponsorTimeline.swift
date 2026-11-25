import Foundation

/// The original recording is immutable. This value translates its time coordinates into
/// the shorter, contiguous playback timeline displayed by the player.
struct SponsorTimeline: Equatable {
    let sourceDuration: Double
    let skipped: [Range<Double>]
    let duration: Double

    init(sourceDuration: Double, cuts: [CutSegment]) {
        let sourceDuration = sourceDuration.isFinite ? max(0, sourceDuration) : 0
        self.sourceDuration = sourceDuration
        let candidates = cuts.compactMap { cut -> Range<Double>? in
            guard cut.start.isFinite, cut.end.isFinite else { return nil }
            let start = min(sourceDuration, max(0, cut.start))
            let end = min(sourceDuration, max(0, cut.end))
            return end > start ? start..<end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Double>] = []
        for range in candidates {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.01 {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        skipped = merged
        duration = max(0, sourceDuration - merged.reduce(0) { $0 + $1.upperBound - $1.lowerBound })
    }

    /// Source time -> visible time. Everything inside a removed span maps to its seam.
    func visibleTime(forSource value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let t = min(sourceDuration, max(0, value))
        var removed = 0.0
        for range in skipped {
            if t >= range.upperBound {
                removed += range.upperBound - range.lowerBound
            } else if t >= range.lowerBound {
                return max(0, range.lowerBound - removed)
            } else { break }
        }
        return min(duration, max(0, t - removed))
    }

    /// Visible time -> original media time. At the exact seam, choose the END of the
    /// excluded stretch so seeking never briefly plays an advert.
    func sourceTime(forVisible value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let t = min(duration, max(0, value))
        var removed = 0.0
        for range in skipped {
            let seam = range.lowerBound - removed
            if t < seam - 0.0001 { break }
            removed += range.upperBound - range.lowerBound
        }
        return min(sourceDuration, max(0, t + removed))
    }

    /// Non-nil when playback has entered a segment that should never be audible.
    func endOfSkippedRange(atSource value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return skipped.first { value >= $0.lowerBound && value < $0.upperBound - 0.001 }?.upperBound
    }

    func containsSource(_ time: Double) -> Bool { endOfSkippedRange(atSource: time) != nil }

    /// Exposed for transcript and chapter displays; intersects are deliberately hidden.
    func visibleSourceRange(_ start: Double, _ end: Double) -> Bool {
        guard start.isFinite, end.isFinite, end > start else { return false }
        return visibleTime(forSource: end) - visibleTime(forSource: start) > 0.02
    }
}
