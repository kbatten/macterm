import Foundation

/// Resolves which shell a pane will actually spawn.
///
/// Two callers need this and must agree: the tab name (a pane with no surface
/// yet shows its shell's name) and the per-pane history isolation (only zsh can
/// be isolated, via ZDOTDIR). Both have to predict the shell libghostty will
/// launch *before* it launches it, so the resolution order lives here rather
/// than being re-derived at each site.
enum LoginShell {
    /// The user's login shell path, from the password database — the same shell
    /// libghostty launches when `config.command` is unset. `$SHELL` is only a
    /// last resort: it names the shell of whatever process launched the app
    /// (often `/bin/zsh` from the launchd chain), not the user's login shell, so
    /// trusting it first would force every pane onto zsh regardless of the real
    /// one.
    static let path: String = {
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        return (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
    }()

    /// The login shell's basename (`zsh`, `nu`) — what a pane displays before it
    /// has a live foreground process to name it.
    static var name: String { (path as NSString).lastPathComponent }

    /// The shell a pane will spawn: its explicit `shell:` (from a declarative
    /// layout), else the ghostty config's `command`, else the login shell.
    @MainActor
    static func resolvedPath(explicit: String? = nil) -> String {
        explicit ?? GhosttyApp.shared.configuredShell ?? path
    }

    /// Whether a pane with this explicit shell lands in zsh — the only shell
    /// whose history we can isolate (ZDOTDIR has no equivalent elsewhere). A
    /// fresh interactive pane names no shell, so the login-shell fallback in
    /// `resolvedPath` is what makes the default-zsh case resolve at all.
    @MainActor
    static func isZsh(explicit: String? = nil) -> Bool {
        (resolvedPath(explicit: explicit) as NSString).lastPathComponent == "zsh"
    }
}
