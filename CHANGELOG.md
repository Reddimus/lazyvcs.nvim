# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.2] - 2026-07-25

### Changed

- Live diff now mirrors the editable window's `wrap`, `linebreak`, and
  `breakindent` settings to the read-only base window. Add `followwrap` to
  `diffopt` to preserve wrapping through native diff mode; LazyVCS does not
  mutate `diffopt`.
- Documented Neovim's visual-alignment caveat for corresponding diff lines that
  wrap to different screen heights.

## [0.4.1] - 2026-07-25

Bug-fix release. An exhaustive audit of the 0.4.0 tree produced 69 findings, 43
of which survived adversarial verification; this release fixes the ones that
break the editor or block the UI thread. The remainder are tracked in #17-#24.

### Fixed

- **Inline blame no longer probes the VCS on every cursor movement.**
  `blame.lua` re-implemented backend probing locally instead of dispatching
  through `backends`, bypassing the probe cache, so every `CursorMoved` spawned
  `git rev-parse` (and `svn info`) synchronously.
- **`:q` no longer aborts with E937.** `layout.close` deleted the base buffer
  from inside that buffer's own `BufWipeout` autocmd; the surrounding `pcall`
  catches a Lua error but not an `emsg`.
- **Closing the sidebar as the last window no longer wedges the toggle.**
  `nvim_win_close` raised E444 out of the `q` keymap and left the window id set.
- **The sidebar finds the repository when opened from a subdirectory.**
  Discovery only scanned downward, so `cd repo/src && nvim` found nothing.
- **Backend resolution handles directory arguments.** The probe cwd and cache
  key came from `vim.fs.dirname`, so a repo root was probed against its parent
  and reported "No Git or SVN working copy found" — reached whenever the current
  buffer is not a real file, e.g. `:LazyVCS files` from a no-name buffer.
- **Negative backend probes expire after 5s** instead of being cached for the
  session, so a directory that becomes a working copy (`git init`, a clone)
  starts showing signs and diffs without restarting Neovim.
- **Non-ASCII filenames work in `:LazyVCS files`.** `git status --porcelain`
  C-quotes such paths; the quotes were stripped but the backslash escapes were
  not decoded, and `vim.fs.normalize` then turned them into path separators. A
  file legitimately named `a -> b.txt` is also no longer truncated.
- **Buffer-transfer failures are reported.** The async callback dropped its
  error argument, so a real backend failure (git mid-rebase, an `index.lock`, a
  timed-out `svn cat`) tore the diff down silently.
- **No orphaned diff window** when the transfer's target window has since moved
  to a third buffer; the unreachable session is now closed.
- Removed the synchronous `is_versioned()` probe from the signs hot path, which
  ran on every `BufEnter`/`BufReadPost`/`TextChanged`.

### Changed

- `vim.validate` migrated to the current `(name, value, validator)` signature;
  the documented minimum is now **Neovim 0.11**.

### Added

- Windows CI job. CI was Ubuntu-only while the primary development platform is
  Windows, which hid 10 spec failures and a `util.relpath` nil return.
- Issue forms, PR template, CODEOWNERS, dependabot.

## [0.4.0] - 2026-07-24

### Changed

- **Breaking:** the 47 user commands are replaced by a single `:LazyVCS` command
  with two-level tab completion (`:LazyVCS diff open`, `:LazyVCS blame split`,
  `:LazyVCS hunk next`, ...). Bare `:LazyVCS` toggles the source-control
  sidebar. The `LazyVcs*` casing twins, `:VcsLiveDiffOpen`, and the `Svn*`
  svnsigns.nvim aliases are removed, along with the `compat.svnsigns_commands`
  option.
- All buffer operations now dispatch through the backend registry, so `files`,
  `preview`, `revert`, `signs refresh` and hunk revert work in Git repositories.
  They previously did nothing outside an SVN working copy.
- `use_gitsigns` (default true) now controls only whether Git gutter signs are
  delegated to gitsigns.nvim; lazyvcs renders them natively when it is absent.
- Removed the `source_control.ui = "neo-tree"` value. The Neo-tree adapter was
  already gone, so the option is now rejected instead of silently ignored.

### Added

- `backends/init.lua` exposes the full backend interface (`resolve`, `root`,
  `is_versioned`, `load_base`, `load_base_async`, `changed_files`,
  `revert_file`, `blame_lines`) and caches backend probing per directory,
  removing two subprocess spawns from every sign refresh.
- Git backend gained `root`, `is_versioned`, `load_base`, `load_base_async`,
  `changed_files` and `revert_file` to match the SVN backend.
- `stylua.toml` and `.gitattributes`, so formatting and line endings are
  identical on Windows and in CI.

### Fixed

- Buffer-transfer failures no longer hang interactive Neovim. `open_session`
  re-raised layout errors and `handle_pending_transfer` called it unprotected
  inside `vim.schedule`; headless Neovim only logs such an error, but
  interactive Neovim blocks on the hit-enter prompt.
- `util.system_result` bounds `proc:wait()`, which previously had no timeout and
  could freeze the UI thread indefinitely against an unreachable SVN server.
- Buffer transfers are fully asynchronous. Navigating to a tracked SVN file ran
  `svn info` and `svn cat` on the UI thread while the signs autocmd ran its own
  commands against the same working copy; contending on the SVN working-copy
  lock froze Neovim for ~60s until both synchronous calls timed out.
- Gutter and blame highlights are re-applied on `ColorScheme`. They are defined
  as `default = true` links, which `:colorscheme` clears, so every lazyvcs
  highlight silently reverted after a theme switch.
- Test fixtures normalize `vim.fn.tempname()`, fixing 10 spec failures on
  Windows caused by mixed `\` and `/` separators.
- SVN added files use an empty base consistently for signs, live diff, and
  inline blame. Inline blame renders added-file lines as uncommitted instead of
  surfacing `svn blame` errors while moving across buffers.

### Removed

- `lua/lazyvcs/svn_ui.lua`, a pass-through shim whose functions forwarded to
  `blame` and `signs`. Use `lazyvcs.buffer_ops` or the public `lazyvcs` API.

## [0.3.0] - 2026-05-31

### Changed

- Live diff now follows the universal old/new convention: the read-only VCS base
  (the old version) is shown in the **left** window and the editable file (your
  new changes) in the **right** window, matching git, VS Code, GitHub, and
  `vimdiff`. Previously the sides were reversed.
- Inline SVN blame follows the cursor instantly. Full-file blame is fetched once
  per buffer and cached, and the cursor-follow render no longer waits behind the
  fetch debounce, so the overlay no longer lags when moving up and down.
  `blame.delay_ms` now only debounces the initial fetch and defaults to `150`
  (was `500`).

### Added

- Inline blame is now a single global toggle that persists across sessions.
  `:LazyVcsBlame` enables or disables the overlay for every supported SVN
  buffer, and with the new `blame.persist` option (default `true`) the choice is
  saved to `stdpath("state")/lazyvcs/state.json` and restored on the next
  launch.

## [0.2.1] - 2026-05-17

### Fixed

- `test_svn_async_blame_cancels_active_child_process` no longer fails the whole
  suite on machines without the `svn` executable. The v0.1.0 svn guard makes
  `blame_lines_async` short-circuit when svn is absent, so the test's mocked
  `system_start` was never reached and the test errored before restoring the
  global monkey-patch — which then cascaded into a spurious failure of
  `test_source_control_git_file_actions_commit_and_sync` (the leaked mock
  stalled its background `git commit`). The SVN test now skips cleanly without
  svn, and restores `util.system_start` via `pcall` so an assertion failure can
  never contaminate later tests. `tests/run.lua` is green again on svn-less
  environments (the documented local workflow).

## [0.2.0] - 2026-05-17

### Added

- Native source-control sidebar for nested Git and SVN repositories without a
  Neo-tree dependency.
- SVN gutter signs, inline current-line blame, fixed-width blame split, line
  log, file picker, preview, and revert commands.
- Background source-control jobs so repo sync/update/commit/switch operations do
  not block the editor.
- VS Code-style branch picker, mutation confirmation popup, and AI-assisted
  commit-message generation through optional editor or CLI providers.
- Docker E2E coverage for vanilla Neovim and AstroNvim plus native sidebar UI
  tests.

### Changed

- Documentation now focuses on the standalone plugin install path for vanilla
  Neovim, lazy.nvim, and AstroNvim.
- Optional integrations are detected at runtime; users get vanilla behavior when
  dependencies are absent and enhanced behavior when they are already installed.

### Fixed

- Git-only setups continue to work when Subversion is not installed, including
  asynchronous command paths.
- Source-control rows preserve cached metadata during refresh and keep other
  repos usable while one repo is busy.

## [0.1.0] - 2026-05-16

First tagged release.

### Fixed

- **SVN backend no longer breaks Git-only setups.** `backends/init.lua` probes
  every backend on each session open, and `backends/svn.lua` spawned `svn`
  unguarded. On any machine without the `svn` executable (the common case —
  lazyvcs is Git-first) this raised `ENOENT` and broke `:LazyVcsDiffOpen` and
  the source-control sidebar for Git repositories too. The svn backend now
  checks for the `svn` executable once and degrades to a clean no-match when it
  is absent.
- **`util.system` is now resilient to missing executables.** `vim.system` raises
  synchronously when a command is not found; `util.system_result` wraps it so
  callers receive a normal non-zero result (`code = 127`) instead of an uncaught
  error.

### Changed

- **Resilient test runner.** `tests/spec.lua` now runs every test in isolation
  via `xpcall` and prints a `PASS` / `SKIP` / `FAIL` line plus a
  `N passed, N skipped, N failed` summary. Previously the suite executed tests
  as bare sequential calls, so the first SVN test aborted the entire run when
  `svnadmin` was missing — masking every later test (this is how the SVN backend
  bug above went undetected).
- **SVN tests skip cleanly without Subversion.** The `svnadmin` guard in the
  test fixtures now raises a structured skip signal instead of a hard `assert`,
  so SVN tests report `SKIP` rather than failing the suite.
- `tests/run.lua` propagates a non-zero exit status when any test fails, making
  the suite usable as a CI gate.

### Added

- GitHub Actions: `ci.yml` (stylua + lua-language-server + full headless test
  suite, including SVN), `release.yml` (tagged releases), and a
  `workflow_dispatch` `e2e.yml` for the Docker AstroNvim smoke test.
- Verified Vim help tags generate cleanly from `doc/lazyvcs.txt` (CI gate);
  `doc/tags` itself stays git-ignored and is built by the plugin manager
  (`lazy.nvim` runs `:helptags` on install) and the release workflow.
- `CHANGELOG.md` and a CI status badge in the README.

[0.1.0]: https://github.com/Reddimus/lazyvcs.nvim/releases/tag/v0.1.0
[0.2.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.1.0...v0.2.0
[0.2.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.2.0...v0.2.1
