import Foundation
import AVFoundation
import Speech
import FoundationModels
import Security

/// On-device transcription (Apple's SpeechAnalyzer) and chapter + sponsor finding with either
/// Apple Intelligence on this Mac or Gemini with the person's own API key — the original offers
/// both an on-device engine and Gemini (generativelanguage.googleapis.com, 0x10081a05c).
enum AIService {
    enum Failure: LocalizedError {
        case unavailable(String)
        case noKey
        case badAnswer
        var errorDescription: String? {
            switch self {
            case .unavailable(let why): "Chapter generation isn’t working right now: \(why)"
            case .noKey: "Add your Gemini API key in Settings."
            case .badAnswer: "The AI answer couldn’t be read."
            }
        }
    }

    // MARK: Transcription

    /// Transcribes in `language` (a code like "es-ES" or "es") when the speech recogniser supports it,
    /// otherwise in this Mac's language. The recogniser's model for that language is downloaded on first use.
    static func transcribe(file: URL, duration: Double, language: String? = nil,
                           partialTranscript: @escaping @Sendable ([TranscriptLine]) -> Void = { _ in },
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptLine] {
        var chosen: Locale? = nil
        if let language, !language.isEmpty {
            chosen = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
            trace("TRANSCRIBE language=\(language) supported=\(chosen?.identifier ?? "no")")
        }
        if chosen == nil { chosen = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) }
        let locale = chosen ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let audioFile = try AVAudioFile(forReading: file)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscriptLine] in
            var lines: [TranscriptLine] = []
            var lastPublishedPercent = -1
            var lastPublishedWords = 0
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds, end = result.range.end.seconds
                let s = start.isFinite ? start : 0, e = end.isFinite ? end : s
                // Word-level pieces with their own times, so long results can be split into sentences
                // (fast conversation, e.g. in Spanish, comes back as several sentences in one result).
                var words: [TranscriptLine] = []
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else {
                        if let last = words.indices.last { words[last].text += piece }
                        continue
                    }
                    if let tr = run.audioTimeRange, tr.start.seconds.isFinite {
                        words.append(TranscriptLine(start: tr.start.seconds, end: tr.end.seconds.isFinite ? tr.end.seconds : tr.start.seconds, text: piece))
                    } else {
                        words.append(TranscriptLine(start: words.last?.end ?? s, end: words.last?.end ?? s, text: piece))
                    }
                }
                if words.isEmpty { words = [TranscriptLine(start: s, end: e, text: text)] }
                lines += words
                if duration > 0, end.isFinite {
                    let fraction = min(0.99, max(0, end / duration))
                    progress(fraction)
                    // Publish sentence paragraphs incrementally, never every ASR word:
                    // this limits SwiftUI list churn and keeps transcript reading live.
                    let percent = Int(fraction * 100)
                    if percent > lastPublishedPercent || lines.count - lastPublishedWords >= 80 {
                        partialTranscript(sentences(lines))
                        lastPublishedPercent = percent
                        lastPublishedWords = lines.count
                    }
                }
            }
            if !lines.isEmpty { partialTranscript(sentences(lines)) }
            return lines
        }
        defer { collector.cancel() }
        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return sentences(try await collector.value)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Turns the recogniser's pieces (words with times, or whole phrases) into short readable paragraphs.
    /// Not every full stop starts a new line: a paragraph ends at a natural pause (over 1.2 s), or once it has
    /// grown past about 160 characters and reaches the end of a sentence; very long run-ons break at a comma
    /// after 300 characters and at the latest at 420, so fast speech never becomes one huge block.
    static func sentences(_ parts: [TranscriptLine]) -> [TranscriptLine] {
        // Only very long phrases without word times are cut into words, sharing the time by length.
        var pieces: [TranscriptLine] = []
        for p in parts {
            let words = p.text.split(separator: " ", omittingEmptySubsequences: true)
            if words.count <= 1 || p.end <= p.start || p.text.count <= 420 {
                pieces.append(p)
                continue
            }
            let total = Double(max(1, p.text.count))
            var offset = 0
            for w in words {
                let t0 = p.start + (p.end - p.start) * Double(offset) / total
                offset += w.count + 1
                let t1 = p.start + (p.end - p.start) * Double(min(offset, Int(total))) / total
                pieces.append(TranscriptLine(start: t0, end: t1, text: String(w) + " "))
            }
        }
        var out: [TranscriptLine] = []
        var cur: TranscriptLine? = nil
        func flush() {
            if var c = cur {
                c.text = tidy(c.text)
                if !c.text.isEmpty { out.append(c) }
            }
            cur = nil
        }
        for p in pieces {
            if let c = cur, p.start - c.end > 1.2 { flush() }
            if var c = cur {
                let joiner = c.text.hasSuffix(" ") || p.text.hasPrefix(" ") ? "" : " "
                c.text += joiner + p.text
                c.end = max(c.end, p.end)
                cur = c
            } else {
                cur = p
            }
            guard let c = cur else { continue }
            let trimmed = c.text.trimmingCharacters(in: .whitespaces)
            let length = trimmed.count
            if length >= 160, let last = trimmed.last, ".?!…".contains(last) { flush() }
            else if length > 300, let last = trimmed.last, ",;:".contains(last) { flush() }
            else if length > 420 { flush() }
        }
        flush()
        return out
    }

    /// Small clean-ups of recogniser output: "imagen.." → "imagen.", "Sí ." → "Sí.", doubled spaces.
    static func tidy(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"(?<!\.)\.\.(?!\.)"#, with: ".", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([.,;:?!])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t
    }

    // MARK: Chapters and sponsors

    struct Found {
        var chapters: [Chapter]
        var sponsors: [CutSegment]
    }

    static func fingerprint(lines: [TranscriptLine], duration: Double, provider: AIProvider, findSponsors: Bool) -> String {
        let last = Int(lines.last?.end ?? duration)
        return "chapters-v7:\(provider.rawValue):\(findSponsors ? 1 : 0):\(lines.count):\(last)"
    }

    /// Transcript lines grouped into numbered blocks the AI can point at.
    struct Block { var number: Int; var start: Double; var end: Double; var text: String }

    static func blocks(_ lines: [TranscriptLine]) -> [Block] {
        var out: [Block] = []
        var cur: Block? = nil
        for l in lines {
            // An ad after a long pause must not merge with the host's final short line.
            if var c = cur, c.end - c.start < Mechanics.transcriptBlockSeconds,
               l.start - c.end < 2.5 {
                c.text += " " + l.text; c.end = l.end; cur = c
            } else {
                if let c = cur { out.append(c) }
                cur = Block(number: out.count, start: l.start, end: l.end, text: l.text)
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    static func instructions(findSponsors: Bool) -> String {
        var s = """
        You divide podcast transcripts into chapters. Each transcript line begins with its line number. \
        A new chapter begins wherever the conversation moves to a genuinely new topic. Report each chapter by \
        the number of its first line; the first chapter begins at line 0. Titles are short (two to six words) \
        and in the language the hosts speak. Create a separate chapter for each distinct topic,
        even when it lasts only 10–20 seconds. NEVER combine two topics in one title with a
        pipe (|), slash or list: report two separate chapter entries, each anchored to the
        transcript line where the respective subject starts. Do not invent boundaries.
        """
        if findSponsors {
            s += """
             Advertisements get chapters of their own, marked as sponsor and titled "Sponsor: " followed by what is \
            advertised. Count paid reads, promotions of other shows and the show's own membership, merchandise or \
            donation pitches; ignore brief passing mentions. When an ad finishes, start a fresh chapter for the \
            hosts' talk, reusing the earlier title if they return to the same topic.
            """
        } else {
            s += " Treat advertisements like any other content."
        }
        return s
    }

    static func chapters(lines: [TranscriptLine], duration: Double, provider: AIProvider, model: String,
                         findSponsors: Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Found {
        let bl = blocks(lines)
        guard !bl.isEmpty else { return Found(chapters: [], sponsors: []) }
        trace("START provider=\(provider.rawValue) lines=\(lines.count) blocks=\(bl.count) duration=\(Int(duration)) sponsors=\(findSponsors)")
        var drafts: [(line: Int, title: String, sponsor: Bool)] = []
        switch provider {
        case .off:
            return Found(chapters: [], sponsors: [])
        case .onDevice:
            drafts = try await onDevice(bl, findSponsors: findSponsors, progress: progress)
        case .gemini:
            progress(0.1)
            drafts = try await gemini(bl, model: model, findSponsors: findSponsors)
            progress(1)
        }
        var found = assemble(drafts, blocks: bl, duration: duration, findSponsors: findSponsors)
        if findSponsors {
            // Independently of provider, recognize only boundary-anchored commercials with
            // concrete spoken sales/URL evidence. A model may omit introductory/outro ads,
            // especially when the recording switches languages or ends during the ad.
            let verified = verifiedEdgeAds(lines: lines, duration: duration)
            for cut in verified {
                // Individual transcript utterances have more precise timestamps than the
                // combined AI prompt blocks. Prefer their bounds if a model cut overlaps.
                found.sponsors.removeAll {
                    max($0.start, cut.start) < min($0.end, cut.end)
                }
                found.sponsors.append(cut)
            }
            found.sponsors.sort { $0.start < $1.start }
        }
        trace("DONE chapters=\(found.chapters.count) sponsors=\(found.sponsors.count)")
        return found
    }

    /// Chapters that are only an ad label ("Ad", "Ads", "Sponsor", "Sponsor: …", "Commercial Break") are folded
    /// into the chapter before them; the first chapter still starts at 0.
    static func withoutAdChapters(_ chapters: [Chapter]) -> [Chapter] {
        let pattern = #"^((ad|ads|advert|adverts|advertisement|advertisements|sponsor|sponsors|sponsored|sponsorship|commercial|commercials|promo|promotion|anuncio|anuncios|publicidad|patrocinio|patrocinado|patrocinada)( break| read| segment| spot| comercial| publicitario)?|(sponsor|ad|advertisement|anuncio|publicidad|patrocinio|patrocinado)\s*:.*)$"#
        let sorted = chapters.sorted { $0.start < $1.start }
        var kept = sorted.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .range(of: pattern, options: .regularExpression) == nil && !isBoundaryTitle($0.title)
        }
        // Two neighbours with the same title (the topic either side of a removed ad) become one.
        kept = kept.enumerated().filter { i, c in i == 0 || kept[i - 1].title != c.title }.map(\.element)
        if !kept.isEmpty { kept[0].start = 0 }
        return kept
    }

    /// Titles that only mark the end of an ad or a return to the conversation.
    static func isBoundaryTitle(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pattern = #"^((the )?(ad|ads|advert|advertisement|sponsor|sponsors|sponsorship|commercial|promo|break)( break| read| segment)? (ends?|ended|over|done|finished)|end of (the )?(ad|ads|break|sponsor\w*|commercial)|back to (the )?(show|episode|conversation|podcast)|(we'?re )?back|return(ing)? to (the )?(show|conversation)|fin (de|del) (anuncio|publicidad|patrocinio)|volvemos (al|a la) (programa|podcast|conversacion)|regresamos (al|a la) (programa|podcast|conversacion))$"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Foundation Models sometimes responds to a *title-only* request with a serialized
    /// chapter row. Strip the row framing, including recursively nested rows such as
    /// `C|74|topic|C|74|productos De Cuidado Personal`, at every AI ingestion point.
    /// Do not fold diacritics here: this text is user-facing and can be in any language.
    static func sanitizeChapterTitle(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<8 {
            let before = value
            value = value.replacingOccurrences(of: #"^\s*(?:`{3}(?:\w+)?|[-*•]\s+|#{1,6}\s+)"#,
                                               with: "", options: .regularExpression)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”‘’`")))
            value = value.replacingOccurrences(
                of: #"(?i)^\s*(?:(?:C|CHAPTER)\s*\|\s*\d+\s*\|\s*|(?:topic|ad|sponsor|advert|publicidad|anuncio|patrocinio)\s*\|\s*)"#,
                with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"(?i)^\s*(?:title|t[ií]tulo)\s*:\s*"#,
                                               with: "", options: .regularExpression)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”‘’`")))
            if value == before { break }
        }
        value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // Some model responses append a protocol category after the display
        // title (e.g. "Clothing Budget|ad"). The verified sponsor decision is
        // handled independently, so never expose these row markers as headings.
        value = value.replacingOccurrences(
            of: #"(?i)\s*\|\s*(?:topic|ad|ads|sponsor|advert|advertisement|publicidad|anuncio|patrocinio)\s*$"#,
            with: "", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "|")))
        if value.caseInsensitiveCompare("none") == .orderedSame { return "" }
        return value
    }

    /// The shared formatter handles English joining words. Add the common Spanish
    /// connectors without discarding accented letters or recasing mixed-case names.
    static func formattedChapterTitle(_ raw: String) -> String {
        let words = Fmt.titleCase(sanitizeChapterTitle(raw))
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let spanishConnectors: Set<String> = ["de", "del", "y", "e"]
        return words.enumerated().map { index, word in
            let core = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if index > 0, index < words.count - 1, spanishConnectors.contains(core),
               !words[index - 1].hasSuffix(":") {
                return word.lowercased()
            }
            return word
        }.joined(separator: " ")
    }

    /// A model sometimes combines two genuinely different topics into one title
    /// ("Travel | Astronomy"). Recover a second boundary ONLY at a real ASR
    /// block: require lexical evidence that the second topic begins there, not
    /// a made-up midpoint. This is independent of chapter spacing heuristics.
    static func splitCombinedTitleDrafts(
        _ drafts: [(line: Int, title: String, sponsor: Bool)], blocks bl: [Block]
    ) -> [(line: Int, title: String, sponsor: Bool)] {
        guard !bl.isEmpty else { return drafts }
        let ordered = drafts.sorted { $0.line < $1.line }
        var expanded: [(line: Int, title: String, sponsor: Bool)] = []
        for d in ordered {
            let title = sanitizeChapterTitle(d.title)
            let parts = title.split(separator: "|", omittingEmptySubsequences: true)
                .map { sanitizeChapterTitle(String($0)) }
                .filter { !$0.isEmpty }
            guard !d.sponsor, parts.count == 2, (0..<bl.count).contains(d.line) else {
                expanded.append(d)
                continue
            }
            let firstTerms = Set(words(parts[0]))
            let secondTerms = Set(words(parts[1]))
            // Some on-device model titles use "|" to paraphrase the SAME
            // subject, not to identify a second timed topic. When no actual
            // boundary can be established, keep the better single-topic label
            // instead of displaying two joined headings as one chapter.
            let context = Set(words(bl[d.line..<min(bl.count, d.line + 2)]
                .map(\.text).joined(separator: " ")))
            let firstEvidence = context.intersection(firstTerms).count
            let secondEvidence = context.intersection(secondTerms).count
            let fallbackTitle = firstEvidence != secondEvidence
                ? (firstEvidence > secondEvidence ? parts[0] : parts[1])
                : (parts[0].count >= parts[1].count ? parts[0] : parts[1])
            guard !firstTerms.isEmpty, !secondTerms.isEmpty,
                  !firstTerms.isSubset(of: secondTerms), !secondTerms.isSubset(of: firstTerms)
            else { expanded.append((d.line, fallbackTitle, false)); continue }
            let next = ordered.first(where: { $0.line > d.line })?.line ?? bl.count
            let start = bl[d.line].start
            let limit = next < bl.count ? bl[next].start : bl.last!.end
            guard d.line + 1 < next else {
                expanded.append((d.line, fallbackTitle, false))
                continue
            }
            let originalEvidence = Set(words(bl[d.line].text)).intersection(firstTerms).count
            var best: (line: Int, score: Double)?
            for index in (d.line + 1)..<next {
                let time = bl[index].start
                guard time - start >= 8, limit - time >= 5 else { continue }
                let preceding = bl[max(d.line, index - 2)..<index].map(\.text).joined(separator: " ")
                let following = bl[index..<min(next, index + 3)].map(\.text).joined(separator: " ")
                let before = Set(words(preceding))
                let after = Set(words(following))
                let secondMatches = after.intersection(secondTerms).count
                let firstAfter = after.intersection(firstTerms).count
                let secondBefore = before.intersection(secondTerms).count
                guard secondMatches > 0, secondMatches >= firstAfter,
                      secondMatches > secondBefore,
                      originalEvidence > 0 || before.intersection(firstTerms).count > 0
                else { continue }
                let pause = max(0, bl[index].start - bl[index - 1].end)
                let novelty = 1 - cosine(wordCounts(preceding), wordCounts(following))
                let score = Double(secondMatches * 3 - firstAfter - secondBefore) +
                    novelty + min(0.5, pause / 8)
                if best == nil || score > best!.score { best = (index, score) }
            }
            if let boundary = best {
                expanded.append((d.line, parts[0], false))
                expanded.append((boundary.line, parts[1], false))
            } else {
                // Never fabricate a timestamp just to eliminate a pipe.
                expanded.append((d.line, fallbackTitle, false))
            }
        }
        return expanded
    }

    static func assemble(_ drafts: [(line: Int, title: String, sponsor: Bool)], blocks bl: [Block],
                         duration: Double, findSponsors: Bool = true) -> Found {
        let sorted = splitCombinedTitleDrafts(drafts, blocks: bl)
            .filter { $0.line >= 0 && $0.line < bl.count }
            .sorted { $0.line != $1.line ? $0.line < $1.line : ($0.sponsor && !$1.sponsor) }
        var chapters: [Chapter] = []
        var sponsors: [CutSegment] = []
        var lastLine = -1
        for (i, d) in sorted.enumerated() where d.line != lastLine {
            lastLine = d.line
            let start = d.line == 0 ? 0 : bl[d.line].start
            let nextLine = sorted[(i + 1)...].first(where: { $0.line > d.line })?.line ?? bl.count
            let end = nextLine < bl.count ? bl[nextLine].start : max(duration, bl.last!.end)
            var title = sanitizeChapterTitle(d.title)
            let sponsor = findSponsors && d.sponsor && sponsorEvidence(around: d.line, blocks: bl)
            if sponsor && !title.lowercased().hasPrefix("sponsor:") { title = "Sponsor: " + title }
            if !sponsor && title.lowercased().hasPrefix("sponsor:") {
                title = String(title.dropFirst("sponsor:".count)).trimmingCharacters(in: .whitespaces)
            }
            // "ad ends", "back to the show"… mark where an ad stops, not a topic: resume the last real topic.
            if !sponsor, isBoundaryTitle(title) {
                guard let resume = chapters.last(where: { !$0.title.lowercased().hasPrefix("sponsor") && !isBoundaryTitle($0.title) })?.title
                else { continue }
                title = resume
            }
            title = formattedChapterTitle(title)
            if let prev = chapters.last, prev.title == title { continue }
            chapters.append(Chapter(start: start.rounded(), title: title.isEmpty ? "Chapter \(chapters.count + 1)" : title))
            if sponsor && end - start <= 480 {
                sponsors.append(CutSegment(start: start, end: end, category: "sponsor", source: "AI"))
            }
        }
        if chapters.first?.start != 0, !chapters.isEmpty { chapters[0].start = 0 }
        return Found(chapters: chapters, sponsors: sponsors)
    }

    // On-device: Apple's Foundation Models, using tolerant line-oriented output. Constrained arrays
    // repeatedly failed to parse in real episodes, discarding otherwise useful model responses.

    static func onDevice(_ bl: [Block], findSponsors: Bool,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> [(line: Int, title: String, sponsor: Bool)] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            if case .unavailable(let why) = model.availability { throw Failure.unavailable("\(why)") }
            throw Failure.unavailable("Apple Intelligence is off")
        }
        var modelDrafts: [(line: Int, title: String, sponsor: Bool)] = []
        var index = 0
        let windowSize = Mechanics.onDeviceBlocksPerRequest
        let overlap = 4
        let stride = max(1, windowSize - overlap)
        let totalWindows = max(1, Int(ceil(Double(max(1, bl.count - overlap)) / Double(stride))))
        var completedWindows = 0
        while index < bl.count {
            try Task.checkCancellation()
            let window = bl[index..<min(bl.count, index + windowSize)]
            let text = window.map { "\($0.number): \($0.text)" }.joined(separator: "\n")
            do {
                let first = window.first!.number
                let last = window.last!.number
                let session = LanguageModelSession(instructions: """
                    Find genuine topic changes in podcast transcript excerpts. Do not create a chapter merely because an excerpt starts. \
                    Output a separate row for EACH distinct topic change, up to four rows per excerpt. A genuine topic can last \
                    only 10 seconds; do not enforce a minimum of several minutes. NEVER join topics in one title with a pipe or slash. \
                    Each row uses this exact format: \
                    C|line number|topic|short title. Use ad instead of topic only for an explicit \
                    paid read, discount code, membership pitch, merchandise pitch, or promotion of another show. If you mark an ad, also \
                    emit a topic chapter where the ad ends. Titles use the speakers' language and contain two to six words. Output NONE \
                    when there is no clear boundary. Never classify profanity, products mentioned in conversation, silence, music, or \
                    garbled transcription as an ad.
                    """)
                session.prewarm(promptPrefix: Prompt("Transcript excerpt"))
                let response = try await session.respond(to: "Lines \(first)–\(last). The first \(overlap) lines may overlap the previous excerpt; report them only if they are a real boundary.\n\(text)",
                                                         options: GenerationOptions.greedy(maximumResponseTokens: 350))
                let generated = parseChapterText(response.content, window: window, blocks: bl,
                                                 findSponsors: findSponsors)
                // Foundation Models can occasionally echo a classification for every input line.
                // That is not a chapter plan, so discard the entire pathological response.
                let accepted = generated.count <= 4 ? generated : []
                modelDrafts += accepted
                trace("WINDOW \(first)-\(last) model=ok parsed=\(generated.count) accepted=\(accepted.count)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                trace("WINDOW \(window.first!.number)-\(window.last!.number) model=failed error=\(error.localizedDescription)")
            }
            index += stride
            completedWindows += 1
            progress(Double(completedWindows) / Double(totalWindows) * 0.9)
        }
        try Task.checkCancellation()
        let topicDrafts = topicBoundaryDrafts(bl)
        let evidenceSponsors = findSponsors ? sponsorBoundaryDrafts(bl) : []
        var cleanModel = modelDrafts
        if evidenceSponsors.count >= 2 {
            for pairStart in Swift.stride(from: 0, to: evidenceSponsors.count - 1, by: 2) {
                let lower = evidenceSponsors[pairStart].line, upper = evidenceSponsors[pairStart + 1].line
                cleanModel.removeAll { $0.line > lower && $0.line < upper }
            }
        }
        let merged = merge(model: cleanModel + evidenceSponsors, topics: topicDrafts, blocks: bl)
        trace("MERGE model=\(modelDrafts.count) sponsorEvidence=\(evidenceSponsors.filter(\.sponsor).count) topic=\(topicDrafts.count) result=\(merged.count)")
        // Chapters the model didn't name carry a placeholder made of frequent words ("Bobby Drag Know Back").
        // Ask the model to name just that passage, so every chapter gets a real title.
        let placeholders = Set(topicDrafts.map(\.title) + evidenceSponsors.filter { !$0.sponsor }.map(\.title))
        progress(0.92)
        return try await nameUnnamedChapters(merged, placeholders: placeholders, blocks: bl) { completed, total in
            progress(0.92 + 0.08 * Double(completed) / Double(max(1, total)))
        }
    }

    @Generable
    struct PassageTitle {
        @Guide(description: "A natural chapter title of two to five words saying what this passage is about, in the language spoken")
        var title: String
    }

    static func nameUnnamedChapters(_ drafts: [(line: Int, title: String, sponsor: Bool)], placeholders: Set<String>,
                                    blocks bl: [Block],
                                    progress: @escaping @Sendable (Int, Int) -> Void) async throws
                                    -> [(line: Int, title: String, sponsor: Bool)] {
        guard SystemLanguageModel.default.isAvailable else { return drafts }
        var out = drafts
        let pending = drafts.indices.filter { !drafts[$0].sponsor && placeholders.contains(drafts[$0].title) }
        for (offset, i) in pending.enumerated() {
            try Task.checkCancellation()
            let start = drafts[i].line
            let next = i + 1 < drafts.count ? drafts[i + 1].line : bl.count
            guard start >= 0, start < bl.count else { continue }
            let passage = bl[start..<min(next, start + 14, bl.count)].map(\.text).joined(separator: " ")
            let session = LanguageModelSession(instructions: """
            You name chapters of a podcast. Read the passage and give it a short, natural title (two to five words) \
            that says what the hosts talk about, in the language they speak. No quotation marks, no numbering, \
            not the word "Chapter". Never join two topics with a pipe (|), slash or list; name only the topic that starts here.
            """)
            do {
                let r = try await session.respond(to: String(passage.prefix(2400)), generating: PassageTitle.self,
                                                  options: GenerationOptions.greedy(maximumResponseTokens: 30))
            let t = sanitizeChapterTitle(r.content.title)
                let words = t.split(separator: " ").count
                if (1...8).contains(words), !t.lowercased().hasPrefix("chapter") { out[i].title = t }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A title failure leaves the deterministic placeholder intact.
            }
            progress(offset + 1, pending.count)
        }
        trace("NAMED \(zip(drafts, out).filter { $0.0.title != $0.1.title }.count) placeholder chapters")
        return out
    }

    static func parseChapterText(_ answer: String, window: ArraySlice<Block>, blocks: [Block],
                                 findSponsors: Bool) -> [(line: Int, title: String, sponsor: Bool)] {
        answer.split(whereSeparator: \.isNewline).compactMap { raw in
            let row = String(raw)
            guard let header = row.range(of: #"(?i)C\s*\|\s*\d+\s*\|"#, options: .regularExpression) else { return nil }
            let fields = row[header.lowerBound...].split(separator: "|", maxSplits: 3,
                                                        omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count >= 3, fields[0].uppercased() == "C", let line = Int(fields[1]),
                  window.contains(where: { $0.number == line }) else { return nil }
            let category = fields[2].lowercased()
            let recognizedCategory = ["topic", "ad", "sponsor", "advert", "publicidad", "anuncio", "patrocinio"]
                .contains(category)
            let rawTitle = recognizedCategory && fields.count == 4 ? fields[3] :
                fields[2...].joined(separator: "|")
            let cleaned = sanitizeChapterTitle(rawTitle)
            guard !cleaned.isEmpty else { return nil }
            let requestedSponsor = ["ad", "sponsor", "advert", "publicidad", "anuncio", "patrocinio"]
                .contains(category)
            let sponsor = findSponsors && requestedSponsor && sponsorEvidence(around: line, blocks: blocks)
            let title = sponsor && !cleaned.lowercased().hasPrefix("sponsor:") ? "Sponsor: \(cleaned)" : cleaned
            return (line, title, sponsor)
        }
    }

    /// Deterministic whole-transcript fallback based on lexical novelty and pauses. It supplies
    /// boundaries only where the topic changes, never at request-window intervals.
    static func topicBoundaryDrafts(_ bl: [Block]) -> [(line: Int, title: String, sponsor: Bool)] {
        guard !bl.isEmpty else { return [] }
        var scored: [(index: Int, score: Double)] = []
        if bl.count > 5 {
            for i in 3..<(bl.count - 2) {
                let before = wordCounts(bl[max(0, i - 5)..<i].map(\.text).joined(separator: " "))
                let after = wordCounts(bl[i..<min(bl.count, i + 5)].map(\.text).joined(separator: " "))
                let pause = max(0, bl[i].start - bl[i - 1].end)
                let score = 1 - cosine(before, after) + min(0.35, pause / 12)
                if score >= 0.72 || pause >= 4 { scored.append((i, score)) }
            }
        }
        var chosen = [0]
        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            let time = bl[candidate.index].start
            // Weak lexical novelty is common in conversational speech; allowing
            // every 24-second shift created 28 noisy chapters in a real 17-minute
            // sample. Require more context for uncertain fallbacks, but permit a
            // strong observed change (including natural pauses) after only 24s.
            // An explicit model-identified chapter has no such heuristic floor.
            let spacing = candidate.score >= 1.05 ? 24.0 : 72.0
            if chosen.allSatisfy({ abs(bl[$0].start - time) >= spacing }) { chosen.append(candidate.index) }
        }
        chosen.sort()
        // Avoid unhelpfully long chapters even when the transcript is repetitive: choose the
        // strongest observed change in each long gap, not the first sentence at a fixed interval.
        var filled = [chosen[0]]
        for end in chosen.dropFirst() {
            var cursor = filled.last!
            while bl[end].start - bl[cursor].start > 600 {
                let candidates = scored.filter { bl[$0.index].start > bl[cursor].start + 24 && bl[$0.index].start < bl[cursor].start + 600 }
                guard let best = candidates.max(by: { $0.score < $1.score }) else { break }
                filled.append(best.index); cursor = best.index
            }
            filled.append(end)
        }
        return Array(Set(filled)).sorted().map { index in
            (bl[index].number, topicTitle(at: index, blocks: bl), false)
        }
    }

    /// Explicit sponsorship language is more trustworthy than a model classification. Pair a
    /// start cue with a nearby spoken end cue and add both boundaries so cuts stay tightly bounded.
    static func sponsorBoundaryDrafts(_ blocks: [Block]) -> [(line: Int, title: String, sponsor: Bool)] {
        let starts = ["this episode is sponsored", "today s episode is sponsored", "sponsored by",
                      "brought to you by", "paid partnership", "patrocinado por", "patrocinada por",
                      "episodio patrocinado", "capitulo patrocinado", "presentado por",
                      "mensaje de nuestros patrocinadores", "a word from our sponsor"]
        let returns = ["now back", "back to the show", "back to the episode",
                       "let s get back", "volvemos al programa", "volvemos con",
                       "regresamos al programa", "seguimos con el programa",
                       "continuamos con el episodio", "de vuelta al podcast"]
        let adClosings = ["terms apply", "se aplican condiciones", "consulta las condiciones",
                          "gracias a nuestro patrocinador", "thanks to our sponsor"]
        var result: [(line: Int, title: String, sponsor: Bool)] = []
        var coveredUntil = -1
        for i in blocks.indices where i > coveredUntil {
            let text = normalizedAdText(blocks[i].text)
            guard starts.contains(where: { text.contains($0) }) else { continue }
            let limit = min(blocks.count - 1, i + 50)
            var endIndex: Int?
            if i + 1 <= limit {
                for j in (i + 1)...limit where blocks[j].start - blocks[i].start >= 15 {
                    guard blocks[j].start - blocks[i].start <= 480 else { break }
                    let candidate = normalizedAdText(blocks[j].text)
                    if returns.contains(where: { candidate.contains($0) }) {
                        endIndex = j; break
                    }
                    if adClosings.contains(where: { candidate.contains($0) }) {
                        endIndex = min(blocks.count - 1, j + 1); break
                    }
                }
            }
            guard let endIndex, blocks[endIndex].start - blocks[i].start <= 480 else { continue }
            result.append((blocks[i].number, "Sponsor", true))
            result.append((blocks[endIndex].number, topicTitle(at: endIndex, blocks: blocks), false))
            coveredUntil = endIndex
        }
        return result
    }

    /// Normalize only for matching spoken advertising evidence, never for display text.
    /// Keeps Spanish diacritics in chapters/transcripts; matches their ASR variants here.
    static func normalizedAdText(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "es_ES"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}.%]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// A named product alone is not an advertisement. Require a spoken sponsorship disclosure,
    /// a concrete discount/code, or a shopping invitation paired with a website/destination.
    /// This deliberately does not treat merely speaking Spanish or mentioning a brand as proof.
    static func commercialEvidenceScore(_ raw: String) -> Int {
        let text = normalizedAdText(raw)
        func any(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }
        let explicit = [
            "this episode is sponsored", "today s episode is sponsored", "sponsored by",
            "brought to you by", "paid partnership", "word from our sponsor",
            "patrocinado por", "patrocinada por", "episodio patrocinado",
            "publicidad pagada", "colaboracion comercial", "mensaje de nuestros patrocinadores",
            "use code ", "use promo code", "promo code ", "discount code ",
            "codigo de descuento", "usa el codigo", "utiliza el codigo",
            "cupon de descuento", "codigo promocional"
        ]
        let negated = any(["not sponsored", "isnt sponsored", "isn t sponsored",
                           "no esta patrocinado", "no es patrocinado", "no me patrocinan"])
        if any(explicit) && !negated { return 5 }
        let destination = any([" punto com", " punto es", " dot com", " dot es",
                               ".com", ".es", "www.", "visita nuestra web", "visit our website"])
        let salesAction = any([
            "empieza gratis", "empieta gratis", "empieta grat", "en pieta grat",
            "prueba gratis", "probar gratis", "comienza gratis", "inicia gratis",
            "start for free", "try it free", "shop now", "visit now", "sign up today",
            "visit us", "get started", "descubre todos", "descubre nuestra",
            "visita", "aprovecha", "compra ahora", "haz tu pedido",
            "crea una tienda", "abre tu tienda", "crea tu tienda", "lanza tu tienda",
            "suscribete hoy", "obten un descuento"
        ])
        let commerce = any([
            "tu tienda", "tu pagina web", "tu negocio", "shopify", "shopifay",
            "black friday", "descuentos", "oferta exclusiva", "promocion",
            "envio gratis", "free trial", "special offer", "save money",
            "coupon", "subscribe today", "sale ends", "para vender",
            "modelos de la gama", "todos los modelos"
        ])
        if destination && (salesAction || commerce) { return 4 }
        if salesAction && commerce { return 3 }
        return salesAction || commerce || destination ? 1 : 0
    }

    /// Evidence-anchored commercials at the first/last portion of the recording need no
    /// spoken "sponsored by" and no imaginary outro boundary at EOF. The first ad ends
    /// before the first non-commercial utterance; a trailing ad begins after a genuine
    /// sign-off or noticeable break and extends only to the recording's real end.
    /// The returned cuts are analysis metadata, not edits to any media file.
    static func verifiedEdgeAds(lines: [TranscriptLine], duration: Double) -> [CutSegment] {
        let utterances = lines.enumerated().map { index, line in
            Block(number: index, start: line.start, end: line.end, text: line.text)
        }
        return verifiedEdgeAds(blocks: utterances, duration: duration)
    }

    /// Also accepts prebuilt blocks for deterministic fixtures. Production calls the
    /// utterance overload, because a block can merge host speech and an adjacent ad.
    static func verifiedEdgeAds(blocks: [Block], duration: Double) -> [CutSegment] {
        guard !blocks.isEmpty, duration > 0 else { return [] }
        var found: [CutSegment] = []
        let cues = blocks.map { commercialEvidenceScore($0.text) }
        let hostIntro = ["hello everyone", "welcome back", "welcome to the podcast",
                         "bienvenidos al podcast", "hola a todos", "comenzamos el programa",
                         "lets begin", "let s begin"]
        let hostOutro = ["that ll do it", "thanks for listening", "see y all next week",
                         "see you next week", "hasta la proxima", "nos vemos la semana que viene",
                         "gracias por escuchar", "nos vemos en el proximo episodio"]
        if let hit = blocks.indices.first(where: { blocks[$0].start <= 60 && cues[$0] >= 3 }) {
            var first = hit
            while first > 0 && blocks[hit].start - blocks[first - 1].start < 50 {
                let previous = normalizedAdText(blocks[first - 1].text)
                if hostIntro.contains(where: { previous.contains($0) }) { break }
                // An earlier intro cannot be swallowed just because a later ad has a URL.
                guard cues[first - 1] > 0 else { break }
                first -= 1
            }
            var last = hit
            while last + 1 < blocks.count && blocks[last + 1].start <= 150 {
                let next = normalizedAdText(blocks[last + 1].text)
                if hostIntro.contains(where: { next.contains($0) }) { break }
                guard cues[last + 1] >= 1, blocks[last + 1].start - blocks[last].end < 8 else { break }
                last += 1
            }
            let start = blocks[first].start <= 4 ? 0 : blocks[first].start
            let end = min(duration, blocks[last].end)
            if end - start >= 10 {
                found.append(CutSegment(start: start, end: end,
                                        category: "sponsor", source: "Transcript evidence"))
            }
        }

        // A terminal ad has no "back to the show" line. Demand at least two independent
        // commercial utterances in the suffix, plus a real sign-off or audible transition.
        for i in blocks.indices where blocks[i].start >= duration - 190 && cues[i] >= 3 {
            let prefix = blocks[max(0, i - 9)..<i]
            let signedOff = prefix.contains { block in
                let text = normalizedAdText(block.text)
                return hostOutro.contains { text.contains($0) }
            }
            let gap = i > 0 ? blocks[i].start - blocks[i - 1].end : 0
            guard signedOff || gap >= 5 else { continue }
            let suffix = blocks[i...]
            guard suffix.filter({ commercialEvidenceScore($0.text) >= 3 }).count >= 2,
                  suffix.last!.end >= duration - 15,
                  !suffix.contains(where: { block in
                      hostIntro.contains { normalizedAdText(block.text).contains($0) }
                  }) else { continue }
            found.append(CutSegment(start: blocks[i].start, end: duration,
                                    category: "sponsor", source: "Transcript evidence"))
            break
        }
        return found
    }

    static func merge(model: [(line: Int, title: String, sponsor: Bool)],
                      topics: [(line: Int, title: String, sponsor: Bool)], blocks: [Block]) -> [(line: Int, title: String, sponsor: Bool)] {
        var result = model.filter { $0.line >= 0 && $0.line < blocks.count }
        let explicitLines = Set(result.map(\.line))
        for topic in topics {
            let time = blocks[topic.line].start
            if !result.contains(where: { abs(blocks[$0.line].start - time) < 18 }) { result.append(topic) }
        }
        if !result.contains(where: { $0.line == 0 }) { result.append(topics.first ?? (0, "Conversation", false)) }
        return result.sorted { $0.line < $1.line }.reduce(into: []) { out, draft in
            guard let previous = out.last else { out.append(draft); return }
            if draft.line == previous.line {
                if draft.sponsor && !previous.sponsor { out[out.count - 1] = draft }
                return
            }
            let gap = blocks[draft.line].start - blocks[previous.line].start
            if draft.sponsor { out.append(draft) }
            else if previous.sponsor && gap >= 5 { out.append(draft) }
            else if gap >= (explicitLines.contains(draft.line) ? 8 : 24) { out.append(draft) }
        }
    }

    static let stopWords: Set<String> = ["about","after","again","also","because","been","before","being","could","does","from","have","into","just","like","more","really","that","their","there","these","they","this","those","through","very","want","were","what","when","where","which","with","would","yeah","your","para","pero","porque","como","esta","este","esto","todo","todos","tiene","vamos","bueno","entonces","cuando","donde","tambien","eine","nicht","und","der","die","das"]

    static func words(_ text: String) -> [String] {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    static func wordCounts(_ text: String) -> [String: Double] {
        Dictionary(words(text).map { ($0, 1.0) }, uniquingKeysWith: +)
    }

    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let dot = a.reduce(0.0) { $0 + $1.value * (b[$1.key] ?? 0) }
        let aa = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let bb = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return aa > 0 && bb > 0 ? dot / (aa * bb) : 0
    }

    static func topicTitle(at index: Int, blocks: [Block]) -> String {
        let end = min(blocks.count, index + 6)
        let counts = wordCounts(blocks[index..<end].map(\.text).joined(separator: " "))
        let terms = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map(\.key)
        return terms.isEmpty ? "Conversation" : terms.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func sponsorEvidence(around line: Int, blocks: [Block]) -> Bool {
        let start = max(0, line - 2), end = min(blocks.count, line + 5)
        guard start < end else { return false }
        return commercialEvidenceScore(blocks[start..<end].map(\.text).joined(separator: " ")) >= 3
    }

    static func trace(_ message: String) {
        // CLI regression runners can redirect diagnostics into their disposable
        // fixture directories, without writing even a log into the user's real
        // Application Support folder. Normal app behavior remains unchanged.
        let folder = ProcessInfo.processInfo.environment["PODCRAFT_TRACE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PodCraft", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("ChapterGeneration.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // Gemini: the whole transcript in one request, answered as JSON.

    static func gemini(_ bl: [Block], model: String, findSponsors: Bool) async throws -> [(line: Int, title: String, sponsor: Bool)] {
        guard let key = Keychain.read("gemini"), !key.isEmpty else { throw Failure.noKey }
        let text = bl.map { "\($0.number): \($0.text)" }.joined(separator: "\n")
        let prompt = instructions(findSponsors: findSponsors) +
            "\nAnswer only with JSON: {\"chapters\":[{\"line\":0,\"title\":\"...\",\"sponsor\":false}]}\n\nTranscript:\n" + text
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.timeoutInterval = 90
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = ["contents": [["parts": [["text": prompt]]]],
                                   "generationConfig": ["responseMimeType": "application/json"]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.unavailable("Gemini answered \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        struct Resp: Decodable { struct C: Decodable { struct Ct: Decodable { struct P: Decodable { var text: String? }; var parts: [P] }; var content: Ct }; var candidates: [C] }
        struct Plan: Decodable { struct D: Decodable { var line: Int; var title: String; var sponsor: Bool? }; var chapters: [D] }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let answer = resp.candidates.first?.content.parts.compactMap(\.text).joined(),
              let json = answer.data(using: .utf8), let plan = try? JSONDecoder().decode(Plan.self, from: json) else { throw Failure.badAnswer }
        return plan.chapters.map { ($0.line, $0.title, $0.sponsor ?? false) }
    }

    static var onDeviceStatus: String {
        let m = SystemLanguageModel.default
        switch m.availability {
        case .available: return "Ready on this Mac"
        case .unavailable(let why): return "Not available: \(why)"
        @unknown default: return "Unknown"
        }
    }
}

/// The Gemini key lives in the login keychain, never in the library file.
enum Keychain {
    static let service = "PodCraft"

    static func save(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        // Preserve credentials from releases before the product-name cleanup,
        // then copy them forward so subsequent reads use only PodCraft.
        let legacyService = ["Pod", "nest"].joined()
        guard let legacy = read(account, service: legacyService) else { return nil }
        save(legacy, for: account)
        return legacy
    }

    private static func read(_ account: String, service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

extension GenerationOptions {
    /// Deterministic output for classification-style prompts. The greedy-sampling argument is named `sampling:`
    /// in some SDKs and `samplingMode:` in others, so this uses temperature 0, which every SDK accepts.
    static func greedy(maximumResponseTokens: Int) -> GenerationOptions {
        GenerationOptions(temperature: 0, maximumResponseTokens: maximumResponseTokens)
    }
}
