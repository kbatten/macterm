import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "WorkspacePersistence")

// MARK: - Histfile storage helpers

/// Directory in App Support where per-pane HISTFILEs are stored.
private let histfilesDirectoryName = "macterm/history"

@MainActor
private func histfileDirectory() -> URL? {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    return appSupport?.appendingPathComponent(histfilesDirectoryName, isDirectory: true)
}

/// Derives a deterministic HISTFILE URL for a pane given its snapshot ID and project path.
@MainActor
private func deriveHistfileURL(for paneID: UUID, inProjectPath projectPath: String) -> URL? {
    guard let dir = histfileDirectory() else { return nil }
    // Use the snapshot pane ID to create a unique filename that survives restarts.
    let fileName = "pane_\(paneID.uuidString).zsh"
    return dir.appendingPathComponent(fileName, isDirectory: false)
}

/// Derives a pane-specific histfile directory URL for ZDOTDIR isolation on zsh shells.
@MainActor
func deriveHistfileDirURL(for paneID: UUID, inProjectPath projectPath: String) -> URL? {
    guard let dir = histfileDirectory() else { return nil }
    let sub = dir.appendingPathComponent("pane_\(paneID.uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    return sub
}

/// Creates a pane-specific histfile directory and `.zshenv` eagerly (e.g. at pane spawn time).
/// This ensures .zshenv exists BEFORE the shell starts so zsh can source it and set HISTFILE.
@MainActor
func ensureHistfileDirExists(for paneID: UUID, inProjectPath projectPath: String) -> URL? {
    let url = deriveHistfileURL(for: paneID, inProjectPath: projectPath)
    guard let url else { return nil }
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data().write(to: url, options: .atomic)
    }
    try? FileManager.default.createDirectory(
        at: histfileDirectory() ?? URL(fileURLWithPath: "/dev/null"),
        withIntermediateDirectories: true
    )

    let dirURL = deriveHistfileDirURL(for: paneID, inProjectPath: projectPath)
    if let dirURL {
        ensureZshenvIn(histfileDir: url.path, at: dirURL)
    }

    return url
}

/// Ensures a pane-specific histfile directory exists with a proper `.zshenv` that exports HISTFILE.
/// This .zshenv loads BEFORE any user dot files (including /etc/zshrc), so HISTFILE can't be overridden.
@MainActor
private func ensureHistfileExists(for paneID: UUID, inProjectPath projectPath: String) -> URL? {
    let url = deriveHistfileURL(for: paneID, inProjectPath: projectPath)
    guard let url else { return nil }
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data().write(to: url, options: .atomic)
    }
    try? FileManager.default.createDirectory(
        at: histfileDirectory() ?? URL(fileURLWithPath: "/dev/null"),
        withIntermediateDirectories: true
    )

    // Create the pane-specific histfile directory with a .zshenv for ZDOTDIR isolation.
    // Keep ZDOTDIR permanently pointing here (never unset) so /etc/zshrc's
    // ${ZDOTDIR:-$HOME} defaults to our dir instead of the user's home.
    let dirURL = deriveHistfileDirURL(for: paneID, inProjectPath: projectPath)
    if let dirURL {
        ensureZshenvIn(histfileDir: url.path, at: dirURL)
    }

    return url
}

/// Ensures a .zshenv exists in the given histfile directory for zsh shells.
/// The key insight: keep ZDOTDIR permanently pointing to this directory (never unset),
/// so /etc/zshrc's ${ZDOTDIR:-$HOME}/.zsh_history defaults to our dir instead of ~.
/// Then source ~/.zshenv so ghostty integration and user configs still load.
@MainActor
private func ensureZshenvIn(histfileDir: String, at dirURL: URL) {
    let zshenv = dirURL.appendingPathComponent(".zshenv", isDirectory: false)
    // Always (re)write — the content is deterministic from histfileDir, so overwriting
    // is idempotent and auto-heals any stale file from an older format.
    // Keep ZDOTDIR permanently here (never unset — that's what broke the previous approach).
    // /etc/zshrc's `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history` will now default to
    // our dir instead of ~ because ZDOTDIR is always set to us.
    let content = """
    # This directory IS zsh's config root for this pane (keep ZDOTDIR permanently).
    export HISTFILE=\(histfileDir)

    # Source user's ~/.zshenv so ghostty integration and user configs still load.
    if [[ -f "$HOME/.zshenv" ]]; then
        builtin source -- "$HOME/.zshenv" 2>/dev/null || true
    fi

    """
    try? content.write(to: zshenv, atomically: true, encoding: .utf8)
}

/// Derives a project-level HISTFILE URL for panes that don't go through
/// workspace persistence (e.g. QuickTerminal). All panes within one project
/// share the same histfile so their command histories merge across sessions.
@MainActor
func quickTerminalHistfileURL() -> String? {
    guard let dir = histfileDirectory() else { return nil }
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
    guard let dir = histfileDirectory() else { return nil }
    let sub = dir.appendingPathComponent("qt", isDirectory: true)
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    if let histfilePath = quickTerminalHistfileURL() {
        ensureZshenvIn(histfileDir: histfilePath, at: sub)
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
        // Collect histfile mappings from all panes in the snapshot so we can
        // inject them into restored panes below. The UUIDs survive across restarts.
        var histfileFor: [UUID: String] = [:]
        for snap in snapshots where validIDs.contains(snap.projectID) {
            for tab in snap.tabs {
                collectHistfiles(in: tab.splitRoot, projectID: snap.projectID, into: &histfileFor)
            }
        }
        return snapshots.compactMap { snap in
            guard validIDs.contains(snap.projectID) else { return nil }
            let tabs = snap.tabs.map { t in
                let root = restoreNode(t.splitRoot, projectID: snap.projectID, histfileFor: histfileFor)
                let focused = t.focusedPaneID.flatMap { root.findPane(id: $0)?.id } ?? root.allPanes().first?.id
                return TerminalTab(id: t.id, splitRoot: root, focusedPaneID: focused, customTitle: t.customTitle)
            }
            guard !tabs.isEmpty else { return nil }
            return Workspace(projectID: snap.projectID, tabs: tabs, activeTabID: snap.activeTabID)
        }
    }

    /// Collect histfile URLs from the snapshot tree for later injection into restored panes.
    private static func collectHistfiles(in node: SplitNodeSnapshot, projectID: UUID, into map: inout [UUID: String]) {
        switch node {
        case let .pane(p):
            if let url = p.historyFileURL, !url.isEmpty {
                map[p.id] = url
            }
        case let .split(b):
            collectHistfiles(in: b.first, projectID: projectID, into: &map)
            collectHistfiles(in: b.second, projectID: projectID, into: &map)
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
            // Derive and store a per-pane HISTFILE URL so command history
            // survives across app restarts. The snapshot pane ID anchors the
            // filename; if the user splits/merges panes between sessions, the
            // same histfile stays on disk — harmless orphaning is acceptable.
            _ = ensureHistfileExists(for: p.id, inProjectPath: path)
            let historyFileURL = deriveHistfileURL(for: p.id, inProjectPath: path)?.path
            return .pane(PaneSnapshot(
                id: p.id,
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

    private static func restoreNode(_ snap: SplitNodeSnapshot, projectID: UUID, histfileFor: [UUID: String]) -> SplitNode {
        switch snap {
        case let .pane(p):
            var env: [String: String] = [:]
            // Re-derive HISTFILE and ZDOTDIR fresh from the snapshot ID rather than trusting
            // the stored `historyFileURL` string (older snapshots stored a `file://` URL that
            // zsh can't use as a path). Pane.id gets a fresh random UUID on restore — it doesn't
            // match p.id (the snapshot ID) — so we key both off p.id, which is what the histfile
            // directories on disk were created under.
            if histfileFor[p.id] != nil {
                if let histfile = deriveHistfileURL(for: p.id, inProjectPath: p.projectPath)?.path {
                    env["HISTFILE"] = histfile
                }
                // Keep ZDOTDIR permanently at this pane's histfile dir so /etc/zshrc's
                // ${ZDOTDIR:-$HOME}/.zsh_history defaults here, NOT to ~.
                if let zdotdir = deriveHistfileDirURL(for: p.id, inProjectPath: p.projectPath)?.path {
                    env["ZDOTDIR"] = zdotdir
                }
            }
            // Ensure the histfile directory with .zshenv exists BEFORE the pane's surface
            // spawns the shell. zsh will source this .zshenv when ZDOTDIR is set, which
            // means HISTFILE is already set before /etc/zshrc can override it.
            _ = ensureHistfileDirExists(for: p.id, inProjectPath: p.projectPath)
            let pane = Pane(projectPath: p.projectPath, projectID: projectID, command: nil, shell: nil, env: env.isEmpty ? nil : env)
            if p.needsAttention == true {
                pane.restoreNeedsAttention()
            }
            return .pane(pane)
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.ratio),
                first: restoreNode(b.first, projectID: projectID, histfileFor: histfileFor),
                second: restoreNode(b.second, projectID: projectID, histfileFor: histfileFor)
            ))
        }
    }
}
