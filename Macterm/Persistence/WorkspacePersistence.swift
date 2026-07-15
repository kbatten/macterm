import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "WorkspacePersistence")

private let quickTerminalPaneID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

// MARK: - Histfile storage helpers

/// Derives the pane-specific histfile directory URL for ZDOTDIR isolation on zsh.
/// The single source of truth for histfile paths — `GhosttyTerminalNSView` calls
/// this too, so the on-disk layout can't drift between the two.
@MainActor
func deriveHistfileDirPath(for paneID: UUID) -> URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = appSupport.appendingPathComponent("macterm/history", isDirectory: true)
    let sub = dir.appendingPathComponent("pane_\(paneID.uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return sub
}

/// Derives a deterministic HISTFILE URL for a pane given its snapshot ID and project path.
@MainActor
func deriveHistfilePath(for paneID: UUID) -> URL? {
    deriveHistfileDirPath(for: paneID)?.appendingPathComponent(".zsh_history", isDirectory: false)
}

/// Creates a pane-specific histfile directory and `.zshenv` eagerly (e.g. at pane spawn time).
/// This ensures .zshenv exists BEFORE the shell starts so zsh can source it and set HISTFILE.
@MainActor
func ensureHistfileDirExists(for paneID: UUID) -> URL? {
    let url = deriveHistfilePath(for: paneID)
    guard let url else { return nil }
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data().write(to: url, options: .atomic)
    }
    try? FileManager.default.createDirectory(
        at: deriveHistfileDirPath(for: paneID) ?? URL(fileURLWithPath: "/dev/null"),
        withIntermediateDirectories: true
    )

    let dirURL = deriveHistfileDirPath(for: paneID)
    if let dirURL {
        ensureZshenvIn(histfilePath: url.path, at: dirURL)
    }

    return url
}

/// Ensures a pane-specific histfile directory exists with a proper `.zshenv` that exports HISTFILE.
/// This .zshenv loads BEFORE any user dot files (including /etc/zshrc), so HISTFILE can't be overridden.
@MainActor
private func ensureHistfileExists(for paneID: UUID) -> URL? {
    let url = deriveHistfilePath(for: paneID)
    guard let url else { return nil }
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data().write(to: url, options: .atomic)
    }
    try? FileManager.default.createDirectory(
        at: deriveHistfileDirPath(for: paneID) ?? URL(fileURLWithPath: "/dev/null"),
        withIntermediateDirectories: true
    )

    // Create the pane-specific histfile directory with a .zshenv for ZDOTDIR isolation.
    // Keep ZDOTDIR permanently pointing here (never unset) so /etc/zshrc's
    // ${ZDOTDIR:-$HOME} defaults to our dir instead of the user's home.
    let dirURL = deriveHistfileDirPath(for: paneID)
    if let dirURL {
        ensureZshenvIn(histfilePath: url.path, at: dirURL)
    }

    return url
}

/// Ensures a .zshenv exists in the given histfile directory for zsh shells.
/// The key insight: keep ZDOTDIR permanently pointing to this directory (never unset),
/// so /etc/zshrc's ${ZDOTDIR:-$HOME}/.zsh_history defaults to our dir instead of ~.
/// Then chain to the user's own dot files AND re-load ghostty's shell integration,
/// which our ZDOTDIR override would otherwise suppress (see zshenvContent).
@MainActor
private func ensureZshenvIn(histfilePath: String, at dirURL: URL) {
    let zshenv = dirURL.appendingPathComponent(".zshenv", isDirectory: false)
    // Always (re)write — the content is deterministic, so overwriting is idempotent
    // and auto-heals any stale file from an older format.
    try? zshenvContent(histfilePath: histfilePath).write(to: zshenv, atomically: true, encoding: .utf8)
}

/// The `.zshenv` we drop into a pane's ZDOTDIR. It must do three things, in order:
///
///   1. Export our per-pane HISTFILE (before /etc/zshrc's
///      `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history` — which now resolves *here*
///      because ZDOTDIR points at us, not $HOME).
///   2. Chain to the user's real ~/.zshenv and ~/.zshrc so their config still loads.
///   3. **Re-source ghostty's shell integration.** Ghostty normally injects its
///      integration by pointing ZDOTDIR at its own integration dir so *its* .zshenv
///      runs. Our ZDOTDIR override replaces that, so ghostty's integration never
///      loads — no OSC 133 prompt markers — and ghostty then believes a command is
///      perpetually running, popping a spurious "zsh is still running" quit dialog.
///      Sourcing `ghostty-integration` (ghostty's documented manual hook) restores
///      the markers. It's loaded AFTER ~/.zshrc because it needs the user's fpath.
private func zshenvContent(histfilePath: String) -> String {
    """
    # This directory IS zsh's config root for this pane (keep ZDOTDIR permanently).
    export HISTFILE="\(histfilePath)"

    # Chain to the user's real dot files so their config still loads.
    if [[ -f "$HOME/.zshenv" ]]; then
        builtin source -- "$HOME/.zshenv" 2>/dev/null || true
    fi
    if [[ -o interactive && -f "$HOME/.zshrc" ]]; then
        builtin source -- "$HOME/.zshrc" 2>/dev/null || true
    fi

    # Re-load ghostty's shell integration (OSC 133 prompt markers). Our ZDOTDIR
    # override suppresses ghostty's own ZDOTDIR-based injection; without this the
    # app shows a spurious "zsh is still running" dialog on quit.
    if [[ -o interactive && -n "$GHOSTTY_RESOURCES_DIR" \\
          && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]]; then
        builtin source -- "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
    fi

    """
}

/// Derives a project-level HISTFILE URL for panes that don't go through
/// workspace persistence (e.g. QuickTerminal). All panes within one project
/// share the same histfile so their command histories merge across sessions.
@MainActor
func quickTerminalHistfileURL() -> String? {
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
    if let histfilePath = quickTerminalHistfileURL() {
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
    /// HISTFILE path for restoring shell command history across restarts.
    /// Stored as a plain string so JSON encoding is explicit and predictable.
    var historyFileURL: String?
    // No `title`: the tab name is derived live from the pane's foreground
    // process, so there's nothing per-pane to persist. (An older snapshot's
    // `title` key is harmlessly ignored on decode.)
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

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    func load() -> [WorkspaceSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            // Try the envelope format first (version + workspaces).
            if let file = try? decoder.decode(WorkspacesFile.self, from: data) {
                return migrate(file).workspaces
            }
            // Fallback: pre-envelope format where the file was a bare array
            // of WorkspaceSnapshot. Upgrade on next save.
            return try clearPersistedAttention(in: decoder.decode([WorkspaceSnapshot].self, from: data))
        } catch {
            logger.error("Failed to load workspaces: \(error)")
            return []
        }
    }

    func save(_ snapshots: [WorkspaceSnapshot]) {
        do {
            let file = WorkspacesFile(version: currentSchemaVersion, workspaces: snapshots)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error)")
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
        workspaces.values.map { ws in
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
        // Collect the snapshot IDs of panes that recorded a history file. A restored
        // pane reuses its snapshot ID as its stable `histfileID` only when it had one,
        // so panes from older/foreign snapshots without history don't claim a dir.
        var panesWithHistfile: Set<UUID> = []
        for snap in snapshots where validIDs.contains(snap.projectID) {
            for tab in snap.tabs {
                collectHistfilePanes(in: tab.splitRoot, into: &panesWithHistfile)
            }
        }
        return snapshots.compactMap { snap in
            guard validIDs.contains(snap.projectID) else { return nil }
            let tabs = snap.tabs.map { t in
                let root = restoreNode(t.splitRoot, projectID: snap.projectID, panesWithHistfile: panesWithHistfile)
                let focused = t.focusedPaneID.flatMap { root.findPane(id: $0)?.id } ?? root.allPanes().first?.id
                return TerminalTab(id: t.id, splitRoot: root, focusedPaneID: focused, customTitle: t.customTitle)
            }
            guard !tabs.isEmpty else { return nil }
            return Workspace(projectID: snap.projectID, tabs: tabs, activeTabID: snap.activeTabID)
        }
    }

    /// Collect the IDs of snapshot panes that recorded an on-disk history file.
    private static func collectHistfilePanes(in node: SplitNodeSnapshot, into set: inout Set<UUID>) {
        switch node {
        case let .pane(p):
            if let url = p.historyFileURL, !url.isEmpty {
                set.insert(p.id)
            }
        case let .split(b):
            collectHistfilePanes(in: b.first, into: &set)
            collectHistfilePanes(in: b.second, into: &set)
        }
    }

    static func snapshotNode(_ node: SplitNode, tabID: UUID) -> SplitNodeSnapshot {
        switch node {
        case let .pane(p):
            // Prefer the shell's live cwd over the pane's original project
            // path so reopening the app lands each pane back in the directory
            // the user had navigated to. Falls back to projectPath when the
            // surface hasn't reported a pwd yet.
            let path = p.nsView?.currentPwd ?? p.projectPath
            let needsAttention = p.executionState == .done
            // Persist the pane's stable `histfileID` (not the volatile `id`) so the
            // restored pane reuses the same on-disk history directory. Restore feeds
            // `PaneSnapshot.id` back in as the new pane's `histfileID`.
            _ = ensureHistfileExists(for: p.histfileID)
            let historyFileURL = deriveHistfilePath(for: p.histfileID)?.path
            return .pane(PaneSnapshot(
                id: p.histfileID,
                projectPath: path,
                needsAttention: needsAttention,
                historyFileURL: historyFileURL
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

    private static func restoreNode(_ snap: SplitNodeSnapshot, projectID: UUID, panesWithHistfile: Set<UUID>) -> SplitNode {
        switch snap {
        case let .pane(p):
            // Carry the snapshot ID forward as the pane's stable `histfileID` when
            // the snapshot recorded a history file, so the restored pane reuses its
            // existing history directory instead of spawning a fresh empty one.
            // `Pane.ensureNSView` derives HISTFILE/ZDOTDIR from `histfileID` and
            // creates the .zshenv, so nothing needs injecting into `env` here.
            let pane = Pane(
                projectPath: p.projectPath,
                projectID: projectID,
                command: nil,
                shell: nil,
                env: nil,
                histfileID: panesWithHistfile.contains(p.id) ? p.id : UUID()
            )
            if p.needsAttention == true {
                pane.restoreNeedsAttention()
            }
            return .pane(pane)
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.ratio),
                first: restoreNode(b.first, projectID: projectID, panesWithHistfile: panesWithHistfile),
                second: restoreNode(b.second, projectID: projectID, panesWithHistfile: panesWithHistfile)
            ))
        }
    }
}
