# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
