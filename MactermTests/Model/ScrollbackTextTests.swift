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
        #expect(ScrollbackText.lastLines("a\nb", maxLines: 0).isEmpty)
        #expect(ScrollbackText.lastLines("a\nb", maxLines: -3).isEmpty)
    }

    // MARK: - restoredBanner

    @Test
    func restoredBanner_appends_labeled_rule_to_body() {
        let out = ScrollbackText.restoredBanner(body: "hello\nworld", timestamp: "Jul 15, 14:32")
        #expect(out == "hello\nworld\n───── Restored · Jul 15, 14:32 ─────")
    }

    @Test
    func restoredBanner_carries_no_escape_sequences() {
        // libghostty prints this without parsing it (it writes it from inside
        // its own escape handler, which can't re-enter the parser), so an
        // escape here would render as literal garbage. It dims the block itself.
        let out = ScrollbackText.restoredBanner(body: "x", timestamp: "t")
        #expect(!out.contains("\u{1b}"))
    }

    @Test
    func restoredBanner_normalizes_crlf_to_bare_lf() {
        // printString maps \n to CR+LF itself; a surviving \r would be a real
        // carriage return and overwrite the line.
        let out = ScrollbackText.restoredBanner(body: "a\r\nb", timestamp: "t")
        #expect(!out.contains("\r"))
        #expect(out.hasPrefix("a\nb\n"))
    }

    @Test
    func restoredBanner_trims_trailing_newlines_before_rule() {
        let out = ScrollbackText.restoredBanner(body: "line\n\n", timestamp: "t")
        // No blank gap between the body and the rule.
        #expect(out == "line\n───── Restored · t ─────")
    }

    @Test
    func restoredBanner_empty_or_newline_only_body_returns_empty() {
        #expect(ScrollbackText.restoredBanner(body: "", timestamp: "t").isEmpty)
        #expect(ScrollbackText.restoredBanner(body: "\n\n", timestamp: "t").isEmpty)
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
