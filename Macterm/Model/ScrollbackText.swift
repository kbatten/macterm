import Foundation

/// Pure helpers for saving and replaying a pane's scrollback as plain text.
///
/// libghostty's text dump drops styling (SGR/colors), so restored scrollback is
/// always plain text. We render it *dim* and close it with a labeled separator
/// rule so the previous session's context is visually distinct from the fresh
/// prompt below it. Everything here is deterministic and unit-tested; the live
/// surface read/inject wiring lives in `GhosttyTerminalNSView`.
enum ScrollbackText {
    /// SGR: faint/dim on.
    static let dimOn = "\u{1b}[2m"
    /// SGR: reset all attributes.
    static let reset = "\u{1b}[0m"

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

    /// Wraps restored scrollback `body` in a dim banner closed by a labeled
    /// separator rule, ready to feed to libghostty as `initial_output`. The
    /// result always ends in a newline so the shell prompt starts on a fresh
    /// line below the rule. Returns "" for empty input (nothing to restore).
    ///
    /// Line endings are normalized to CRLF: this is written to the terminal as
    /// raw output, and a bare LF only moves the cursor down (no carriage
    /// return), which would render multi-line content as a rightward staircase.
    static func restoredBanner(body: String, timestamp: String) -> String {
        let trimmed = trimTrailingNewlines(body)
        guard !trimmed.isEmpty else { return "" }
        let rule = "───── Restored · \(timestamp) ─────"
        let bodyCRLF = crlf(trimmed)
        return "\(dimOn)\(bodyCRLF)\r\n\(rule)\(reset)\r\n"
    }

    /// Normalize any mix of CRLF/LF line endings to CRLF.
    private static func crlf(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
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
