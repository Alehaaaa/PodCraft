import Foundation

/// Deterministic, network-free chapter/ad boundary checks. A separate test runner
/// calls failures(); production code never invokes them or mutates the user library.
enum AIServiceRegression {
    static func failures() -> [String] {
        var errors: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { errors.append(message) }
        }

        check(AIService.sanitizeChapterTitle("C|74|productos De Cuidado Personal") ==
              "productos De Cuidado Personal", "three-column row prefix")
        check(AIService.sanitizeChapterTitle("C|74|topic|C|74|topic|Árboles y océanos") ==
              "Árboles y océanos", "nested serialized row and diacritics")
        check(AIService.sanitizeChapterTitle("• C|12|anuncio|Promoción de café") ==
              "Promoción de café", "Markdown and Spanish category")
        check(AIService.sanitizeChapterTitle("C|1|topic|\"Niñez y educación\"") ==
              "Niñez y educación", "quoted accented title")
        check(AIService.sanitizeChapterTitle("Clothing Budget|ad") ==
              "Clothing Budget", "trailing protocol category not shown in title")
        check(AIService.formattedChapterTitle("C|74|productos De Cuidado Personal") ==
              "Productos de Cuidado Personal", "Spanish connector case")

        let shortBlocks = [
            AIService.Block(number: 0, start: 0, end: 14, text: "Presentación"),
            AIService.Block(number: 1, start: 14, end: 28, text: "Hablamos de música"),
            AIService.Block(number: 2, start: 28, end: 42, text: "Un debate sobre ciencia")
        ]
        let parsed = AIService.parseChapterText("""
            - C|1|topic|C|1|topic|Música y emoción
            C|2|ciencia y educación
            C|999|topic|Fuera de rango
            """, window: shortBlocks[0...], blocks: shortBlocks, findSponsors: false)
        check(parsed.count == 2, "three/four-column parse and index range")
        if parsed.count == 2 {
            check(parsed[0].title == "Música y emoción", "nested parse")
            check(parsed[1].title == "ciencia y educación", "three-column parse")
        }
        let assembled = AIService.assemble([(1, "C|74|topic|Árboles y océanos", false)],
                                           blocks: shortBlocks, duration: 45)
        check(assembled.chapters.first?.title.contains("|") == false, "assembled row leak")
        check(assembled.chapters.first?.title.localizedCaseInsensitiveContains("océanos") == true,
              "assembled accent preservation")

        // The model must not merge distinct spoken subjects simply because a
        // chapter title was emitted as "A | B". The second chapter starts on
        // an actual ASR block, not at an inferred midpoint of the recording.
        let topicBlocks = [
            AIService.Block(number: 0, start: 0, end: 11, text: "Travel trains and hotels around Europe"),
            AIService.Block(number: 1, start: 12, end: 23, text: "Train travel in Spain with hotel bookings"),
            AIService.Block(number: 2, start: 26, end: 37, text: "Science research explores the galaxies"),
            AIService.Block(number: 3, start: 39, end: 52, text: "Space science and telescopes are fascinating")
        ]
        let twoTopics = AIService.assemble([(0, "Travel | Science", false)],
                                           blocks: topicBlocks, duration: 52)
        check(twoTopics.chapters.count == 2 &&
              twoTopics.chapters.map(\.title) == ["Travel", "Science"] &&
              twoTopics.chapters.map(\.start) == [0, 26],
              "two topics split at transcript-grounded boundary")
        let noProof = AIService.assemble([(0, "Travel | Science", false)],
                                        blocks: Array(topicBlocks.prefix(2)), duration: 24)
        check(noProof.chapters.count == 1 && noProof.chapters[0].title == "Travel",
              "never invent a second timestamp or show a pipe without transcript evidence")
        let shortModel = AIService.merge(model: [
            (0, "Opening", false), (1, "New topic", false), (2, "Next topic", false)
        ], topics: [], blocks: topicBlocks)
        check(shortModel.count == 3,
              "explicit 12-second and 14-second chapters retained")
        let heuristic = AIService.merge(model: [], topics: [
            (0, "Travel", false), (2, "Science", false)
        ], blocks: topicBlocks)
        check(heuristic.count == 2,
              "24-second grounded heuristic boundary retained")

        let edgeBlocks = [
            AIService.Block(number: 0, start: 0.18, end: 12.42,
                            text: "Crea una tienda Shopify, tu primera venta"),
            AIService.Block(number: 1, start: 12.42, end: 25.20,
                            text: "Empieza gratis en Shopify punto com"),
            AIService.Block(number: 2, start: 28.38, end: 35.34, text: "Podcast music"),
            AIService.Block(number: 3, start: 36.9, end: 50,
                            text: "Hello everyone, welcome back to the show"),
            AIService.Block(number: 4, start: 70, end: 82,
                            text: "I love Dr Pepper. This isn't even sponsored."),
            AIService.Block(number: 5, start: 3380, end: 3387,
                            text: "Thanks for listening. See you next week."),
            AIService.Block(number: 6, start: 3397.44, end: 3415.26,
                            text: "Descubre todos modelos en Toyota punto es"),
            AIService.Block(number: 7, start: 3417.06, end: 3430.38,
                            text: "Black Friday: tu tienda con Shopify, empieza ahora"),
            AIService.Block(number: 8, start: 3430.38, end: 3454,
                            text: "Lanza tu tienda Shopify antes de la venta"),
            AIService.Block(number: 9, start: 3454, end: 3475.8,
                            text: "Empieza gratis en Shopify punto com")
        ]
        let cuts = AIService.verifiedEdgeAds(blocks: edgeBlocks, duration: 3476.37)
        check(cuts.count == 2, "opening and terminal commercial proof")
        if cuts.count == 2 {
            check(cuts[0].start == 0 && abs(cuts[0].end - 25.2) < 0.01,
                  "opening cutoff before host")
            check(abs(cuts[1].start - 3397.44) < 0.01 && abs(cuts[1].end - 3476.37) < 0.01,
                  "terminal EOF cut after sign-off")
        }
        let nonAdBlocks = [
            AIService.Block(number: 0, start: 0, end: 22,
                            text: "Hello everyone, welcome back. I love Dr Pepper."),
            AIService.Block(number: 1, start: 22, end: 42,
                            text: "This isn't sponsored. We are talking about beverages."),
            AIService.Block(number: 2, start: 42, end: 62,
                            text: "En mi vida cotidiana comento productos y tiendas, nada más."),
            AIService.Block(number: 3, start: 62, end: 75,
                            text: "Thanks for listening, see you next week")
        ]
        check(AIService.verifiedEdgeAds(blocks: nonAdBlocks, duration: 75).isEmpty,
              "incidental brand and Spanish conversation")
        let separatedByPause = AIService.blocks([
            TranscriptLine(start: 3386.28, end: 3387.30, text: "Seriously, bye."),
            TranscriptLine(start: 3397.44, end: 3415.26,
                           text: "Descubre todos nuestros modelos en Toyota punto es")
        ])
        check(separatedByPause.count == 2 && separatedByPause[1].start == 3397.44,
              "long pause must separate host sign-off from the next commercial")

        let midRoll = [
            AIService.Block(number: 0, start: 0, end: 30, text: "Let's discuss science"),
            AIService.Block(number: 1, start: 30, end: 50, text: "This episode is sponsored by a partner"),
            AIService.Block(number: 2, start: 50, end: 95, text: "Use code TREAT for a discount"),
            AIService.Block(number: 3, start: 95, end: 113, text: "Now back to the show"),
            AIService.Block(number: 4, start: 113, end: 150, text: "We resume our discussion")
        ]
        let mid = AIService.sponsorBoundaryDrafts(midRoll)
        check(mid.count == 2 && mid.first?.sponsor == true && mid.last?.line == 3,
              "explicit mid-roll return boundary")
        return errors
    }
}
