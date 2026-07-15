import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "WorkspacePersistence")

private let quickTerminalPaneID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

// MARK: - Histfile storage helpers

/// Derives the histfile directory URL for a pane's session — the dir ZDOTDIR
/// points at for zsh isolation. The single source of truth for histfile paths.
///
/// Keyed by `Pane.sessionID`, which is persisted verbatim in the snapshot and so
/// names the same dir across restarts. It must never be keyed by `Pane.id`: that
/// is a fresh UUID every launch, which would strand the previous launch's history
/// in an orphaned dir and start each relaunch with an empty one.
@MainActor
func deriveHistfileDirPath(for sessionID: UUID) -> URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = appSupport.appendingPathComponent("macterm/history", isDirectory: true)
    let sub = dir.appendingPathComponent("pane_\(sessionID.uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return sub
}

/// Derives the deterministic HISTFILE path for a pane's session.
@MainActor
func deriveHistfilePath(for sessionID: UUID) -> URL? {
    deriveHistfileDirPath(for: sessionID)?.appendingPathComponent(".zsh_history", isDirectory: false)
}

/// Creates a pane's histfile directory and its ZDOTDIR dotfile mirror, returning
/// the directory for ZDOTDIR. Called at spawn so the files exist BEFORE the shell
/// starts and zsh can source them.
///
/// HISTFILE is reasserted in the generated `.zshrc` (after the user's config and
/// /etc/zshrc), so the per-pane histfile can't be overridden. ZDOTDIR stays
/// pointed here for the pane's whole life (never unset) so /etc/zshrc's
/// `${ZDOTDIR:-$HOME}` defaults to our dir instead of the user's home.
@MainActor
@discardableResult
func ensureHistfileDirExists(for sessionID: UUID) -> URL? {
    guard let dirURL = deriveHistfileDirPath(for: sessionID),
          let fileURL = deriveHistfilePath(for: sessionID)
    else { return nil }
    // Directory before file: the histfile lives inside it, so seeding the file
    // first would just silently fail against a missing parent.
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
        try? Data().write(to: fileURL, options: .atomic)
    }
    ensureZshenvIn(histfilePath: fileURL.path, at: dirURL)
    return dirURL
}

/// Writes the ZDOTDIR dotfile mirror into the given histfile directory for zsh shells.
/// The key insight: keep ZDOTDIR permanently pointing to this directory (never unset),
/// so /etc/zshrc's ${ZDOTDIR:-$HOME}/.zsh_history defaults to our dir instead of ~.
/// Then mirror the user's own dot files phase-by-phase (see `zdotdirFiles`) so their
/// config loads at its *normal* startup phase, AND re-load ghostty's shell integration,
/// which our ZDOTDIR override would otherwise suppress.
@MainActor
private func ensureZshenvIn(histfilePath: String, at dirURL: URL) {
    // Always (re)write — the content is deterministic, so overwriting is idempotent
    // and auto-heals any stale file from an older format.
    for (name, content) in zdotdirFiles(histfilePath: histfilePath) {
        let url = dirURL.appendingPathComponent(name, isDirectory: false)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The dotfiles we drop into a pane's ZDOTDIR — one per zsh startup phase.
///
/// Splitting them (rather than cramming everything into `.zshenv`) is what lets the
/// user's `~/.zshrc` load at its *normal* phase — **after** `/etc/zshrc` — so their
/// PROMPT/PS1 wins. Sourcing `~/.zshrc` from `.zshenv` (the previous approach) ran it
/// *before* `/etc/zshrc`, whose `PS1="%n@%m %1~ %# "` then clobbered the user's prompt.
///
/// zsh reads, in order: `$ZDOTDIR/.zshenv` → `.zprofile` (login) → `.zshrc`
/// (interactive) → `.zlogin` (login). Because ZDOTDIR points here for the pane's whole
/// life, the user's own `~/.z*` files would never be read; each generated file chains
/// to its `~/` counterpart at the matching phase (absolute path, so no recursion since
/// ZDOTDIR ≠ $HOME). Errors are not swallowed (only `|| true` guards abort), matching
/// native zsh — a broken prompt framework should surface, not fail silently.
///
/// HISTFILE is set in `.zshenv` (defined for every shell) and re-exported at the end of
/// `.zshrc` — after `~/.zshrc` and after `/etc/zshrc`'s `${ZDOTDIR:-$HOME}/.zsh_history`
/// — so the per-pane file is the last writer. ghostty's shell integration is sourced at
/// the end of `.zshrc` too: our ZDOTDIR override suppresses ghostty's own injection, and
/// without the OSC 133 markers ghostty believes a command is perpetually running and
/// pops a spurious "zsh is still running" quit dialog. It defers to the first precmd, so
/// it wraps whatever prompt `~/.zshrc` ends up with, and needs the user's fpath first.
private func zdotdirFiles(histfilePath: String) -> [(name: String, content: String)] {
    [
        (".zshenv", """
        # Per-pane HISTFILE isolation; ZDOTDIR points here for this pane's lifetime.
        export HISTFILE="\(histfilePath)"

        # Chain to the user's real ~/.zshenv at its normal phase.
        if [[ -f "$HOME/.zshenv" ]]; then
            builtin source -- "$HOME/.zshenv" || true
        fi

        """),
        (".zprofile", """
        # Chain to the user's real ~/.zprofile at its normal phase (login shells).
        if [[ -f "$HOME/.zprofile" ]]; then
            builtin source -- "$HOME/.zprofile" || true
        fi

        """),
        (".zshrc", """
        # Load the user's real interactive config at its normal phase — after
        # /etc/zshrc — so their PROMPT/PS1, HISTSIZE, etc. are the last writers.
        if [[ -f "$HOME/.zshrc" ]]; then
            builtin source -- "$HOME/.zshrc" || true
        fi

        # Reassert our per-pane HISTFILE last, beating /etc/zshrc's
        # ${ZDOTDIR:-$HOME}/.zsh_history and any HISTFILE the user set.
        export HISTFILE="\(histfilePath)"

        # Re-load ghostty's shell integration (OSC 133 prompt markers). Our ZDOTDIR
        # override suppresses ghostty's own injection; without this the app shows a
        # spurious "zsh is still running" dialog on quit. Sourced after ~/.zshrc so it
        # has the user's fpath and wraps the final prompt.
        if [[ -n "$GHOSTTY_RESOURCES_DIR" \\
              && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]]; then
            builtin source -- "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
        fi

        """),
        (".zlogin", """
        # Chain to the user's real ~/.zlogin at its normal phase (login shells).
        if [[ -f "$HOME/.zlogin" ]]; then
            builtin source -- "$HOME/.zlogin" || true
        fi

        """),
    ]
}

/// Derives a project-level HISTFILE URL for panes that don't go through
/// workspace persistence (e.g. QuickTerminal). All panes within one project
/// share the same histfile so their command histories merge across sessions.
@MainActor
func quickTerminalHistfilePath() -> String? {
    guard let dir = deriveHistfilePath(for: quickTerminalPaneID) else { return nil }
    let fileName = "qt.zsh"
    let url = dir.appendingPathComponent(fileName, isDirectory: false)
    // Ensure the file exists so shells have somewhere to write.
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data().write(to: url, options: .atomic)
    }
    return url.path
}

/// Derives a project-level HISTFILE directory URL for ZDOTDIR isolation on
/// QuickTerminal panes. All panes within one project share the same zsh history
/// and dot file isolation directory. Creates .zshenv that exports HISTFILE before
/// any /etc/zshrc or user dot files can override it.
@MainActor
func quickTerminalHistfileDirURL() -> String? {
    guard let dir = deriveHistfileDirPath(for: quickTerminalPaneID) else { return nil }
    let sub = dir.appendingPathComponent("qt", isDirectory: true)
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    if let histfilePath = quickTerminalHistfilePath() {
        ensureZshenvIn(histfilePath: histfilePath, at: sub)
    }
    return sub.path
}

// MARK: - File envelope

/// Current schema version. Bump when the snapshot types change shape.
/// Adding an optional field does NOT require a bump — Codable decodes
/// missing fields as nil / default. Removing or renaming fields does.
private let currentSchemaVersion = 4

/// Top-level on-disk representation. Wraps the workspace array so we can
/// evolve the file format (add fields, do migrations) without renaming the
/// file. Readers that encounter the old bare-array format still work.
struct WorkspacesFile: Codable {
    var version: Int
    var workspaces: [WorkspaceSnapshot]
}

// MARK: - Snapshot types

struct WorkspaceSnapshot: Codable {
    let projectID: UUID
    let activeTabID: UUID?
    let tabs: [TabSnapshot]
}

struct TabSnapshot: Codable {
    let id: UUID
    let customTitle: String?
    let focusedPaneID: UUID?
    let splitRoot: SplitNodeSnapshot
}

indirect enum SplitNodeSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(SplitBranchSnapshot)

    private enum CodingKeys: String, CodingKey { case type, pane, split }
    private enum NodeType: String, Codable { case pane, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(NodeType.self, forKey: .type) {
        case .pane: self = try .pane(c.decode(PaneSnapshot.self, forKey: .pane))
        case .split: self = try .split(c.decode(SplitBranchSnapshot.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(p):
            try c.encode(NodeType.pane, forKey: .type)
            try c.encode(p, forKey: .pane)
        case let .split(b):
            try c.encode(NodeType.split, forKey: .type)
            try c.encode(b, forKey: .split)
        }
    }
}

struct PaneSnapshot: Codable {
    let id: UUID
    let projectPath: String
    /// Whether the pane was left in the "done / needs attention" state when the
    /// app last quit, so the green checkmark survives a restart until the user
    /// acknowledges it. Only `.done` is worth persisting: `.running` can't
    /// outlive the shell process, and `.idle` is the default. Optional so older
    /// snapshots (without the field) decode as nil / idle.
    var needsAttention: Bool?
    /// Stable zmx session id (`Pane.sessionID`). On restore the rebuilt pane
    /// reuses it, so its shell reattaches to the still-running daemon instead
    /// of spawning fresh. Optional: older snapshots decode nil → fresh id.
    var sessionID: UUID?
    /// The pane's zmx session name, persisted VERBATIM — never re-derived. The
    /// name embeds the project slug at creation time, so re-deriving it after
    /// a project rename would target a session that doesn't exist.
    var sessionName: String?
    /// The pane's live working directory at snapshot time, so a session that
    /// did NOT survive (reboot, external kill) respawns where the user was.
    /// A surviving session reattaches with its own live cwd regardless.
    var workingDirectory: String?
    // No `title`: the tab name is derived live from the pane's foreground
    // process, so there's nothing per-pane to persist. (An older snapshot's
    // `title` key is harmlessly ignored on decode.)
    //
    // No `historyFileURL` either: the pane's histfile path is a pure function of
    // its `sessionID` (`deriveHistfilePath`), so persisting it would be a second
    // copy of a derivable value — one that could disagree with the real dir.
    // (An older snapshot's key is harmlessly ignored on decode.)

    /// Memberwise init with defaults for the optional fields, so call sites
    /// and tests that build old-shape snapshots keep compiling. (SwiftLint
    /// forbids `= nil` on the stored declarations.)
    init(
        id: UUID,
        projectPath: String,
        needsAttention: Bool? = nil,
        sessionID: UUID? = nil,
        sessionName: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.needsAttention = needsAttention
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
    }
}

struct SplitBranchSnapshot: Codable {
    let direction: SplitDirection
    let ratio: Double
    let first: SplitNodeSnapshot
    let second: SplitNodeSnapshot
}

// MARK: - Persistence

final class WorkspaceStore {
    private let fileURL: URL
    /// Set when `load()` found a present-but-undecodable file. While set,
    /// `save()` refuses to overwrite — a single corrupt field (or a snapshot
    /// written by a newer build) must never let the next autosave clobber the
    /// user's persisted tabs/sessions with empty state.
    private var loadFailed = false

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    func load() -> [WorkspaceSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Could not even read the bytes (transient I/O). Preserve the file:
            // don't let the next save overwrite what we couldn't read.
            logger.error("Failed to read workspaces file: \(error, privacy: .public)")
            loadFailed = true
            return []
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        // Envelope format first (version + workspaces).
        do {
            let file = try decoder.decode(WorkspacesFile.self, from: data)
            guard file.version <= currentSchemaVersion else {
                // A newer build wrote this. Decoding dropped keys it doesn't
                // know, so re-saving would silently downgrade + lose data.
                // Refuse to persist over it this session.
                logger.error("""
                Workspaces file schema v\(file.version, privacy: .public) is newer than \
                supported v\(currentSchemaVersion, privacy: .public); not overwriting
                """)
                loadFailed = true
                return migrate(file).workspaces
            }
            return migrate(file).workspaces
        } catch let envelopeError {
            // Fallback: pre-envelope format where the file was a bare array of
            // WorkspaceSnapshot. Upgrade on next save.
            if let bare = try? decoder.decode([WorkspaceSnapshot].self, from: data) {
                return clearPersistedAttention(in: bare)
            }
            // Present but decodable as neither shape → corrupt or a format we
            // don't understand. Log the PRIMARY (envelope) error and preserve
            // the file rather than clobbering it with the next save.
            logger.error("Failed to decode workspaces file: \(envelopeError, privacy: .public)")
            loadFailed = true
            return []
        }
    }

    func save(_ snapshots: [WorkspaceSnapshot]) {
        guard !loadFailed else {
            logger.error("Refusing to save workspaces: prior load failed, file preserved")
            return
        }
        do {
            let file = WorkspacesFile(version: currentSchemaVersion, workspaces: snapshots)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error, privacy: .public)")
        }
    }

    /// Apply any needed in-memory migrations.
    private func migrate(_ file: WorkspacesFile) -> WorkspacesFile {
        if file.version < 4 {
            // v3 could persist spurious completion checkmarks for tabs that had
            // already been visually cleared. Drop the old attention bits once;
            // v4+ saves them only after the false-start and clear/save fixes.
            logger.info("Migrating workspaces v\(file.version, privacy: .public)→4: clearing persisted attention bits")
            return WorkspacesFile(version: 4, workspaces: clearPersistedAttention(in: file.workspaces))
        }
        return file
    }

    private func clearPersistedAttention(in snapshots: [WorkspaceSnapshot]) -> [WorkspaceSnapshot] {
        snapshots.map { ws in
            WorkspaceSnapshot(
                projectID: ws.projectID,
                activeTabID: ws.activeTabID,
                tabs: ws.tabs.map { tab in
                    TabSnapshot(
                        id: tab.id,
                        customTitle: tab.customTitle,
                        focusedPaneID: tab.focusedPaneID,
                        splitRoot: clearPersistedAttention(in: tab.splitRoot)
                    )
                }
            )
        }
    }

    private func clearPersistedAttention(in node: SplitNodeSnapshot) -> SplitNodeSnapshot {
        switch node {
        case var .pane(p):
            p.needsAttention = nil
            return .pane(p)
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: b.ratio,
                first: clearPersistedAttention(in: b.first),
                second: clearPersistedAttention(in: b.second)
            ))
        }
    }
}

// MARK: - Snapshot / Restore

@MainActor
enum WorkspaceSerializer {
    static func snapshot(_ workspaces: [UUID: Workspace]) -> [WorkspaceSnapshot] {
        // Sort by projectID so the serialized file is byte-stable across saves
        // (Dictionary.values iteration order is unspecified). restore() is
        // order-independent, so this only tames diff churn on the file.
        workspaces.values.sorted { $0.projectID.uuidString < $1.projectID.uuidString }.map { ws in
            WorkspaceSnapshot(
                projectID: ws.projectID,
                activeTabID: ws.activeTabID,
                tabs: ws.tabs.map { tab in
                    TabSnapshot(
                        id: tab.id,
                        customTitle: tab.customTitle,
                        focusedPaneID: tab.focusedPaneID,
                        splitRoot: snapshotNode(tab.splitRoot, tabID: tab.id)
                    )
                }
            )
        }
    }

    static func restore(from snapshots: [WorkspaceSnapshot], validIDs: Set<UUID>) -> [Workspace] {
        snapshots.compactMap { snap in
            guard validIDs.contains(snap.projectID) else { return nil }
            let tabs = snap.tabs.map { t in
                let root = restoreNode(t.splitRoot, projectID: snap.projectID)
                let focused = t.focusedPaneID.flatMap { root.findPane(id: $0)?.id } ?? root.allPanes().first?.id
                return TerminalTab(id: t.id, splitRoot: root, focusedPaneID: focused, customTitle: t.customTitle)
            }
            guard !tabs.isEmpty else { return nil }
            return Workspace(projectID: snap.projectID, tabs: tabs, activeTabID: snap.activeTabID)
        }
    }

    static func snapshotNode(_ node: SplitNode, tabID: UUID) -> SplitNodeSnapshot {
        switch node {
        case let .pane(p):
            // `projectPath` is the pane's IDENTITY — persisted verbatim so a
            // remote pane's scp-style spec (`host:dir`) survives restart and
            // still parses as `.remote` (drives ssh + zmx reattach). Never
            // overwrite it with a live cwd.
            //
            // `workingDirectory` is a *local* respawn hint: prefer the shell's
            // live cwd so reopening lands a LOCAL pane back where the user had
            // navigated (OSC 7 `currentPwd` first, then the foreground
            // process's kernel cwd). It is deliberately nil for remote panes —
            // `currentPwd` there is a REMOTE-filesystem path (OSC 7 from the
            // remote shell) that would parse as a bogus local dir on restore
            // and orphan the remote session (the hazard
            // `AppState.replaceProjectPathWithCurrentDir` gates the same way).
            let liveCwd = p.isRemote
                ? nil
                : (p.nsView?.currentPwd ?? ProcessInspector.foregroundWorkingDirectory(forPane: p))
            let needsAttention = p.executionState == .done
            // `id` is the pane's VOLATILE runtime id, persisted only so this
            // tab's `focusedPaneID` still resolves on restore. Nothing durable
            // may key off it — the pane's history keys off `sessionID`, which is
            // persisted below and survives verbatim.
            return .pane(PaneSnapshot(
                id: p.id,
                projectPath: p.projectPath,
                needsAttention: needsAttention,
                sessionID: p.sessionID,
                sessionName: p.sessionName,
                workingDirectory: liveCwd
            ))
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: Double(b.ratio),
                first: snapshotNode(b.first, tabID: tabID),
                second: snapshotNode(b.second, tabID: tabID)
            ))
        }
    }

    private static func restoreNode(_ snap: SplitNodeSnapshot, projectID: UUID) -> SplitNode {
        switch snap {
        case let .pane(p):
            // Reuse the persisted session identity so the restored pane
            // reattaches to its still-running zmx daemon: `zmx attach` is an
            // upsert, so a session that died while the app was closed just
            // becomes a fresh shell in the saved working directory — no
            // staleness handling needed. Old snapshots (nil identity) get a
            // fresh session — and so a fresh history dir, since the two are
            // keyed together.
            //
            // A LOCAL pane prefers its persisted live cwd (`workingDirectory`)
            // so a respawn lands where the user was; a REMOTE pane persists no
            // `workingDirectory` (see `snapshotNode`), so this falls back to
            // `projectPath` — the scp-style spec that keeps the pane remote.
            let pane = Pane(
                projectPath: p.workingDirectory ?? p.projectPath,
                projectID: projectID,
                sessionID: p.sessionID ?? UUID(),
                sessionName: p.sessionName
            )
            if p.needsAttention == true {
                pane.restoreNeedsAttention()
            }
            return .pane(pane)
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.ratio),
                first: restoreNode(b.first, projectID: projectID),
                second: restoreNode(b.second, projectID: projectID)
            ))
        }
    }
}
