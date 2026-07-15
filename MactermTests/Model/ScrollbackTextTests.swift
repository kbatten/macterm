import Foundation
@testable import Macterm
import Testing

struct ScrollbackTextTests {
    // MARK: - lastLines

    @Test
    func lastLines_returns_all_when_within_limit() {
        #expect(ScrollbackText.lastLines("a\nb\nc", maxLines: 10) == "a\nb\nc")
    }

    @Test
    func lastLines_keeps_only_trailing_lines() {
        #expect(ScrollbackText.lastLines("a\nb\nc\nd", maxLines: 2) == "c\nd")
    }

    @Test
    func lastLines_ignores_single_trailing_newline() {
        // A buffer ending in "\n" shouldn't count a blank final line.
        #expect(ScrollbackText.lastLines("a\nb\nc\n", maxLines: 2) == "b\nc")
    }

    @Test
    func lastLines_preserves_interior_blank_lines() {
        #expect(ScrollbackText.lastLines("a\n\nb", maxLines: 5) == "a\n\nb")
    }

    @Test
    func lastLines_zero_or_negative_is_empty() {
        #expect(ScrollbackText.lastLines("a\nb", maxLines: 0) == "")
        #expect(ScrollbackText.lastLines("a\nb", maxLines: -3) == "")
    }

    // MARK: - restoredBanner

    @Test
    func restoredBanner_dims_body_and_appends_labeled_rule_with_crlf() {
        // CRLF line endings so terminal output doesn't staircase (LF alone
        // moves down without returning to column 0).
        let out = ScrollbackText.restoredBanner(body: "hello\nworld", timestamp: "Jul 15, 14:32")
        #expect(out == "\u{1b}[2mhello\r\nworld\r\n───── Restored · Jul 15, 14:32 ─────\u{1b}[0m\r\n")
    }

    @Test
    func restoredBanner_always_ends_with_crlf() {
        let out = ScrollbackText.restoredBanner(body: "x", timestamp: "t")
        #expect(out.hasSuffix("\u{1b}[0m\r\n"))
    }

    @Test
    func restoredBanner_trims_trailing_newlines_before_rule() {
        let out = ScrollbackText.restoredBanner(body: "line\n\n", timestamp: "t")
        // No blank gap between the body and the rule.
        #expect(out == "\u{1b}[2mline\r\n───── Restored · t ─────\u{1b}[0m\r\n")
    }

    @Test
    func restoredBanner_empty_or_newline_only_body_returns_empty() {
        #expect(ScrollbackText.restoredBanner(body: "", timestamp: "t") == "")
        #expect(ScrollbackText.restoredBanner(body: "\n\n", timestamp: "t") == "")
    }

    // MARK: - timestamp

    @Test
    func timestamp_formats_month_day_time() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 15
        comps.hour = 14
        comps.minute = 32
        let date = try #require(cal.date(from: comps))
        #expect(ScrollbackText.timestamp(for: date, calendar: cal) == "Jul 15, 14:32")
    }
}
