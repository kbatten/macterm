# Rebase conflict-surface analysis

Analysis of how easily this fork's four customizations rebase onto a moving upstream, and where
the real conflict risk lives. Companion to [REBASE.md](REBASE.md) (the procedure). Measured against
`main` (the upstream mirror); commit shas are on `main-fork`.

## Summary

The delta is **4 commits, 16 files, ~95% additive** — already a good position. Additive lines
(new files, new methods, new stored properties) rarely conflict; only *replacements* inside an
upstream method it also edits do. So the true risk metric is:

> **risk ≈ (interleaved-edit lines + hunk count) × how often upstream touches that file**

Ranking by that metric — not by raw diff size — the real hotspots are `SplitNode`, `AppState`,
and `GhosttyTerminalNSView`, **not** the file with the scariest-looking hunk (`WindowAppearance`,
which is a cold file). A hunk that looks big but sits in code upstream never touches is cheap; a
one-line hook in a hot file is not.

Two cross-cutting, cheap wins apply to all features:

1. **Reworded comments are pure waste.** 12 of 44 removed-upstream lines (27%) are comment
   rewording — they guarantee a conflict if upstream touches that line, for zero functional value.
   Reverting them to upstream's exact wording is the single cheapest reduction available.
2. **`git rerere`** (now enabled in `.git/config`) replays each resolved conflict automatically.

## Upstream churn (last 50 commits on `main`)

Conflict likelihood per file. High-churn files are where a hook actually bites.

| churn | file |
|------:|------|
| 49 | `App/AppState.swift` |
| 45 | `Settings/SettingsView.swift` |
| 45 | `App/MactermApp.swift` |
| 39 | `Views/Terminal/GhosttyTerminalNSView.swift` |
| 31 | `Views/QuickTerminal.swift` |
| 28 | `Model/SplitNode.swift` |
| 16 | `App/Preferences.swift` |
| 11 | `Persistence/WorkspacePersistence.swift` |
|  8 | `Views/WindowAppearance.swift` |
|  7 | `App/Updater.swift` |

## Per-feature findings

### autoupdate — `d509e3e` "Fix skip update check when auto-updates disabled"
- **Surface:** +20 / −2, 3 files, no new files. Smallest and lowest-risk feature.
- **Files:** `Preferences.swift` (+11, additive), `Updater.swift` (−1: one changed return in
  `automaticallyChecksForUpdates`, churn 7), `SettingsView.swift` (−1: one binding line, but the
  file is hot at churn 45).
- **Verdict:** near-nothing to do. The two 1-line touches are unavoidable hooks. Watch the
  `SettingsView` line on rebase because the file churns, but it's a single line.

### glass — `a849f00` "Apply liquid glass to QuickTerminal window"
- **Surface:** +50 / −14, 2 files (`WindowAppearance.swift`, `QuickTerminal.swift`), no new files.
- **The one genuinely-interleaved hunk in the whole fork:** a 14-line panel/non-panel branch woven
  into the middle of `WindowAppearance.syncGlass`, plus a rewrite of `existingGlass`. 2 of the 14
  removed lines are comment rewording.
- **BUT `WindowAppearance` is a COLD file (churn 8)** — so despite the scary hunk, its real risk is
  mid-pack, below the history/scrollback hooks that sit in hot files.
- **Proven-out refactor (built and validated, then dropped uncommitted per the "codebase is in a
  good state" decision):** extract creation into `installGlass` / `glassTopInset` helpers +
  reuse a `themeFrame(for:)` helper, leaving `syncGlass` as upstream's shape with **2 changed
  call-site lines** and `existingGlass` with **1**; the `.configure(...)` tail stays byte-identical.
  A rebase drill (synthetic upstream editing the glass-creation block) confirmed: the **original
  interleaved version conflicts (1 hunk); the refactored version cherry-picks clean.** Behavior was
  identical (panel anchors to `contentView` == `themeFrame` since they're the same view for panels).
  If glass is ever revisited, this is the shape to restore. `QuickTerminal.swift` side is +6, purely
  additive.

### history — `2a42549` "add zsh history to each pane"
- **Surface:** +302 / −19, 5 files, **1 new file** (`System/LoginShell.swift`, conflict-proof).
- **Highest raw interleaved count (−19), but concentrated:** the `SplitNode.swift` −15 is almost
  entirely ONE hunk — the `defaultShellName` rewrite (13 lines, of which 6 are the doc comment)
  replaced by a one-line delegation to `LoginShell.name`. `SplitNode` churn is 28. The other three
  `SplitNode` hunks are tiny (−1/−0/−1, additive property/hook inserts).
- `WorkspacePersistence.swift` (+187, churn 11): mostly a big append-only block, plus the
  `WorkspaceSerializer.snapshotNode` signature gaining a `tabID:` param threaded through 3 call
  sites (−5, 1 of them a comment). Low risk — it's the fork's own serialization code upstream
  rarely touches.
- `QuickTerminal.swift` (+22) and the test file (+30) are purely additive.
- **Verdict:** the `defaultShellName` extraction is legitimately shared (`LoginShell` also feeds
  history isolation), so it's justified, not churn. Its only cheap improvement is dropping the 6
  reworded comment lines. Not worth a bigger refactor.

### scrollback — `93f6675` "Restore each pane's scrollback when reopened"
- **Surface:** +496 / −9, 12 files, **2 new files** (`Model/ScrollbackText.swift`,
  `MactermTests/Model/ScrollbackTextTests.swift`, both conflict-proof). Biggest feature, but
  lowest interleaved-edit ratio — overwhelmingly additive.
- **Hooks in HOT files (the real attention points):**
  - `GhosttyTerminalNSView.swift` (+76 / −3, churn 39) — the surface-spawn hook: the
    `wrapperArgv` construction gained a reattach-gate branch (−3). Hot file; a candidate for a
    one-line-delegation shrink if this is ever hardened.
  - `AppState.swift` (+40 / −3, churn 49 — hottest file) — teardown hooks
    (`removeProject`/`closeTab`/close-pane) gained scrollback cleanup. **2 of the 3 removed lines
    are pure comment rewording** ("…die with it" → "…die with it, and saved scrollback goes too").
    Reverting those two comments removes almost all of this file's surface for free.
  - `SettingsView.swift` (+34, churn 45) and `MactermApp.swift` (−1: `onTerminate` closure, churn
    45) — small hooks in hot files; watch on rebase.
- `Preferences.swift` (+24), `ZmxClient.swift` (+29), `QuickTerminal.swift` (+17), `SplitNode.swift`
  (+12), and the `ZmxClientTests` (+36) are additive.
- **Verdict:** structurally the cleanest feature already (new logic isolated in `ScrollbackText` /
  `ZmxAttach.isSessionLive`). Cheapest win: revert the 2 `AppState` comment edits.

## Recommendation (if this is ever picked up again)

In priority order, cheapest first:

1. **Revert all reworded-comment lines to upstream's exact text** (~12 lines across `AppState`,
   `SplitNode`, `WorkspacePersistence`, `WindowAppearance`). Pure conflict-surface removal, zero
   functional change, minutes of work.
2. **Shrink the 2–3 real hooks in hot files** toward one-line delegations: the
   `GhosttyTerminalNSView` spawn hook and the `AppState` teardown hooks. Lower leverage than #1.
3. The **glass refactor** above — worthwhile if glass is revisited, but `WindowAppearance` is cold
   so it's not urgent.
4. Optional, only if rebasing becomes frequent: **split `main-fork` into per-topic branches** so a
   conflict in one feature doesn't wedge the others (see REBASE.md).

`QuickTerminal` (additive despite churn 31) and the new files need nothing.
