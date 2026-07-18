import Foundation

/// Pure helpers for saving and replaying a pane's scrollback as plain text.
///
/// libghostty's text dump drops styling (SGR/colors), so restored scrollback is
/// always plain text. We close it with a labeled separator rule; libghostty dims
/// the block as it prints it, so the previous session's context is visually
/// distinct from the fresh prompt below it. Everything here is deterministic and
/// unit-tested; the live surface read/inject wiring lives in
/// `GhosttyTerminalNSView`.
enum ScrollbackText {
    /// Returns at most the last `maxLines` lines of `text`. Trailing newlines are
    /// ignored so a buffer ending in "\n" doesn't count a blank final line.
    /// Returns the input unchanged when it already fits (or `maxLines <= 0`).
    static func lastLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        // Drop a single trailing newline so we don't keep an empty last line.
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return body }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Wraps restored scrollback `body` with a labeled separator rule, ready to
    /// hand libghostty as `initial_output`. Returns "" for empty input.
    ///
    /// Plain text, deliberately: libghostty prints this straight to the terminal
    /// rather than parsing it (it writes it from inside its own escape-sequence
    /// handler, which can't re-enter the parser), so any escapes here would
    /// render as literal garbage. It dims the whole block itself — restored text
    /// is inert history, and the dimming marks it as such.
    ///
    /// Bare `\n`, also deliberately: libghostty's `printString` treats it as
    /// CR+LF, so there's no staircasing to guard against here.
    static func restoredBanner(body: String, timestamp: String) -> String {
        let trimmed = trimTrailingNewlines(body)
        guard !trimmed.isEmpty else { return "" }
        let rule = "───── Restored · \(timestamp) ─────"
        return "\(lf(trimmed))\n\(rule)"
    }

    /// Normalize any mix of CRLF/LF line endings to bare LF.
    private static func lf(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Formats a timestamp for the restore rule, e.g. "Jul 15, 14:32".
    static func timestamp(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") || out.hasSuffix("\r") {
            out.removeLast()
        }
        return out
    }
}
