# Rebasing this fork onto upstream

This fork carries a small set of private customizations on top of an upstream Macterm we don't
control. `main` here is a **convenience mirror** of that upstream; the real target is the upstream
repo, which moves independently. This doc is the procedure for carrying our changes forward with
minimal conflict. For the per-feature conflict-surface analysis (where the risk actually lives and
what's worth hardening), see [REBASE-FINDINGS.md](REBASE-FINDINGS.md).

## Principles that keep rebases cheap

The delta is deliberately kept **~95% additive** — new files and new methods, not rewrites of
upstream code. Additive changes rarely conflict (only when upstream edits immediately adjacent
lines). The expensive part is any hunk that *replaces* upstream code inside a method it also
evolves, so we minimize those:

- **New logic goes in new files** (`Macterm/Model/ScrollbackText.swift`,
  `Macterm/System/LoginShell.swift`, …). New files never conflict.
- **A touch inside an upstream method should be a single call into our code**, not a reworked
  block. `LoginShell.name` / `ZmxAttach.isSessionLive` / `ScrollbackText` are the model: the logic
  lives in a fork-owned type and the upstream file only calls it. Where a hook is still an
  interleaved edit (see the hotspots below), prefer re-minimizing over re-interleaving when it
  conflicts.
- **Don't reword upstream comments.** Rewording a `//` line guarantees a conflict if upstream ever
  touches that line, for zero functional value — 27% of this fork's replacement lines are exactly
  this waste (see REBASE-FINDINGS.md). Keep upstream comment text byte-identical.

Hotspots to eyeball on every rebase, ordered by real risk (interleaved edits × upstream churn —
NOT raw diff size; the scariest-looking hunk sits in a cold file). Full breakdown in
REBASE-FINDINGS.md:

1. `Model/SplitNode.swift` — `defaultShellName` → `LoginShell.name` (one rewritten hunk; churn 28).
2. `App/AppState.swift` — teardown hooks in the hottest file (churn 49); mostly additive + 2
   reworded comments that should be reverted.
3. `Views/Terminal/GhosttyTerminalNSView.swift` — surface-spawn reattach-gate hook (churn 39).
4. `Views/WindowAppearance.swift` — the one deeply-interleaved hunk (`syncGlass`), but a COLD file
   (churn 8); a proven helper-extraction refactor is recorded in REBASE-FINDINGS.md if revisited.
5. `Settings/SettingsView.swift`, `App/MactermApp.swift` — 1-line hooks in hot files (churn 45).
6. `Persistence/WorkspacePersistence.swift` — `snapshotNode(tabID:)` codec hook (cold, churn 11).

Purely additive, no attention needed: `Preferences.swift`, `ZmxClient.swift`, `QuickTerminal.swift`,
and all new files/tests.

## One-time setup

Enable `rerere` so a conflict resolved once is replayed automatically on every future rebase — the
single biggest time-saver for a recurring rebase:

```bash
git config rerere.enabled true
git config rerere.autoUpdate true
```

## Procedure

```bash
# 1. Fetch the real upstream (add the remote once; the origin 'main' is only a mirror).
git remote add upstream <upstream-macterm-url>   # first time only
git fetch upstream main

# 2. Rebase the fork branch onto fresh upstream.
git checkout main-fork
git rebase upstream/main

# 3. Resolve conflicts. rerere replays known ones; for new ones, prefer re-minimizing
#    (move logic into a helper) over re-interleaving, so the next rebase is cheaper.
#    Then: git add <files> && git rebase --continue

# 4. Verify (the CLAUDE.md contract).
mise run test --verbose
mise run lint --verbose
mise run run          # smoke-test the app, esp. any feature whose hook conflicted
```

## If you rebase often: split into topic branches

`main-fork` currently bundles unrelated features (update-check fix, liquid glass, zsh history,
scrollback restore) in one line of commits, so a conflict in one wedges the rest. If rebasing
becomes frequent, maintain one topic branch per feature off `main` and rebuild `main-fork` as
their integration (never hand-edit the integration branch). That lets each feature rebase — and be
upstreamed — independently. This is optional and not yet done.
