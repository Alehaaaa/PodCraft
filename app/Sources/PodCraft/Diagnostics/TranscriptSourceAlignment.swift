import Foundation

/// Maps the spoken passage under the playhead between two *different* podcast
/// recordings. RSS feeds may contain regional adverts not present in the
/// channel-verified YouTube upload, so subtracting durations or assuming equal
/// source timestamps is unsafe. This matcher requires multiple ordered,
/// locally consistent speech phrases. If they cannot be found, playback stays
/// on its current AVPlayer rather than jumping to an approximate offset.
enum TranscriptSourceAlignment {
    struct Match: Sendable {
        let sourceTime: Double
        let targetTime: Double
        let supportingPhrases: Int
        let confidence: Double
    }

    private struct Word {
        let token: String
        let time: Double
    }

    private struct Anchor {
        let sourceIndex: Int
        let sourceTime: Double
        let targetTime: Double
        var offset: Double { targetTime - sourceTime }
    }

    private static func words(in lines: [TranscriptLine], range: ClosedRange<Double>? = nil) -> [Word] {
        var result: [Word] = []
        for line in lines {
            guard line.start.isFinite, line.end.isFinite, line.end > line.start,
                  range == nil || (line.end >= range!.lowerBound && line.start <= range!.upperBound) else { continue }
            let normalized = line.text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                               locale: Locale(identifier: "en_US_POSIX"))
            let tokens = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count <= 48 }
            guard !tokens.isEmpty else { continue }
            for (i, token) in tokens.enumerated() {
                let relative = (Double(i) + 0.5) / Double(tokens.count)
                result.append(Word(token: token, time: line.start + (line.end - line.start) * relative))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func key(_ words: [Word], _ i: Int) -> String {
        words[i].token + "\u{001f}" + words[i + 1].token + "\u{001f}" + words[i + 2].token
    }

    /// The returned time is in the TARGET recording's original, uncut source
    /// clock. Caller must convert it through the target SponsorTimeline.
    /// The operation is bounded (a short ~40-second context window, capped
    /// at 12,000 destination words) so repeated checks cannot stall SwiftUI.
    static func align(from source: [TranscriptLine], to target: [TranscriptLine],
                      atSource second: Double, targetDuration: Double) -> Match? {
        guard second.isFinite, second >= 0, targetDuration.isFinite, targetDuration > 0 else { return nil }
        let old = words(in: source, range: max(0, second - 24)...(second + 12))
        let new = words(in: target)
        guard old.count >= 16, new.count >= 16, new.count <= 12_000 else { return nil }

        // A phrase repeated in many sections ("thank you very much", etc.) is
        // not an alignment anchor; retain only fairly distinctive trigrams.
        var index: [String: [Int]] = [:]
        for i in 0..<(new.count - 2) {
            let k = key(new, i)
            if (new[i].token.count + new[i + 1].token.count + new[i + 2].token.count) < 12 { continue }
            if index[k, default: []].count <= 8 { index[k, default: []].append(i) }
        }
        var anchors: [Anchor] = []
        for i in 0..<(old.count - 2) {
            let k = key(old, i)
            guard let matches = index[k], matches.count <= 8 else { continue }
            for j in matches {
                anchors.append(Anchor(sourceIndex: i + 1, sourceTime: old[i + 1].time,
                                      targetTime: new[j + 1].time))
            }
        }
        guard anchors.count >= 5 else { return nil }

        // Cluster by media-time delta, rather than by the absolute time in
        // either recording. All phrases of one uninterrupted spoken passage
        // should imply approximately the same time delta. Inserted advertising
        // changes that delta, and thus starts a different context cluster.
        let sorted = anchors.sorted { $0.offset < $1.offset }
        struct Candidate {
            let offset: Double
            let votes: Int
            let score: Double
            let nearestSourceAnchor: Double
            let span: Double
        }
        var candidates: [Candidate] = []
        for center in sorted {
            let same = sorted.filter { abs($0.offset - center.offset) <= 2.8 }
            let unique = Dictionary(grouping: same, by: \.sourceIndex).compactMap { _, grouped in
                grouped.min(by: { abs($0.offset - center.offset) < abs($1.offset - center.offset) })
            }
            guard unique.count >= 5 else { continue }
            let sourceTimes = unique.map(\.sourceTime).sorted()
            let span = sourceTimes.last! - sourceTimes.first!
            guard span >= 4.0 else { continue }
            let nearest = sourceTimes.map { abs($0 - second) }.min() ?? .infinity
            // Never jump when currently inside a long advertisement that is
            // absent in the target: words must be close to the playhead.
            guard nearest <= 8.0 else { continue }
            let offset = unique.map(\.offset).sorted()[unique.count / 2]
            let residual = unique.map { abs($0.offset - offset) }.sorted()[unique.count / 2]
            guard residual <= 2.1 else { continue }
            let mapping = second + offset
            guard mapping >= 0, mapping <= targetDuration - 0.5 else { continue }
            let score = Double(unique.count) / (1 + residual) + min(4.0, span / 12)
            candidates.append(Candidate(offset: offset, votes: unique.count,
                                        score: score, nearestSourceAnchor: nearest, span: span))
        }
        guard let best = candidates.max(by: { $0.score < $1.score }), best.votes >= 5 else { return nil }
        // Two similarly plausible, distant passages cannot be resolved safely
        // using a duration heuristic; defer instead of guessing.
        if let rival = candidates.filter({ abs($0.offset - best.offset) > 9 })
            .max(by: { $0.score < $1.score }), rival.score > best.score * 0.72 { return nil }

        let mapped = second + best.offset
        let confidence = min(1.0, (Double(best.votes) / 10) *
                             (best.nearestSourceAnchor <= 3 ? 1 : 0.85) *
                             min(1, best.span / 8))
        guard confidence >= 0.48 else { return nil }
        return Match(sourceTime: second, targetTime: mapped,
                     supportingPhrases: best.votes, confidence: confidence)
    }
}
