import XCTest
@testable import PodCraft

final class BackendRegressionTests: XCTestCase {
    func testDurationParsingRejectsMalformedValues() {
        XCTAssertEqual(FeedFetcher.parseDuration("01:02:03"), 3723)
        XCTAssertEqual(FeedFetcher.parseDuration("12:30"), 750)
        XCTAssertEqual(FeedFetcher.parseDuration("-1:30"), 0)
        XCTAssertEqual(FeedFetcher.parseDuration("1:bad"), 0)
    }

    func testYouTubeIDExtractionAcceptsSupportedLinksOnly() {
        XCTAssertEqual(SponsorBlock.videoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(SponsorBlock.videoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(SponsorBlock.videoID(from: "https://example.com/watch?v=dQw4w9WgXcQ"))
    }

    func testCutRangesAreClampedAndMerged() {
        let cuts = [
            CutSegment(start: -2, end: 5, category: "intro", source: "test"),
            CutSegment(start: 5.4, end: 9, category: "sponsor", source: "test"),
            CutSegment(start: 18, end: 30, category: "outro", source: "test")
        ]
        XCTAssertEqual(AudioCutter.merged(cuts, duration: 20), [0...9, 18...20])
    }

    func testRSSOutputEscapesUserContent() {
        XCTAssertEqual(RSSGenerator.esc("A & B <C> \"D\""), "A &amp; B &lt;C&gt; &quot;D&quot;")
    }

    func testDirectoryResultsAreDeduplicatedWithoutReordering() {
        let first = FeedFetcher.SearchResult(title: "One", author: "A", feedURL: "http://example.com/feed/", artwork: nil)
        let duplicate = FeedFetcher.SearchResult(title: "Duplicate", author: "A", feedURL: "https://example.com/feed", artwork: nil)
        let second = FeedFetcher.SearchResult(title: "Two", author: "B", feedURL: "https://example.com/other", artwork: nil)
        XCTAssertEqual(FeedFetcher.deduplicated([first, duplicate, second]).map(\.title), ["One", "Two"])
    }

    func testYouTubeCaptionsRemoveSpeakerMarkers() {
        let vtt = """
        WEBVTT

        00:00.000 --> 00:02.000
        >> First speaker starts here.

        00:02.100 --> 00:04.000
        >> Second speaker answers clearly.

        00:04.100 --> 00:06.000
        The conversation continues.
        """
        let lines = YouTubeSource.parseVTT(Data(vtt.utf8), duration: 10)
        XCTAssertNotNil(lines)
        XCTAssertFalse(lines?.contains(where: { $0.text.contains(">>") }) ?? true)
        XCTAssertTrue(lines?.map(\.text).joined(separator: " ").contains("Second speaker") == true)
    }
}
