# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **`util.system` is now resilient to missing executables.** `vim.system`
  raises synchronously when a command is not found; `util.system_result` wraps
  it so callers receive a normal non-zero result (`code = 127`) instead of an
  uncaught error.

### Changed

- **Resilient test runner.** `tests/spec.lua` now runs every test in isolation
  via `xpcall` and prints a `PASS` / `SKIP` / `FAIL` line plus a
  `N passed, N skipped, N failed` summary. Previously the suite executed tests
  as bare sequential calls, so the first SVN test aborted the entire run when
  `svnadmin` was missing — masking every later test (this is how the SVN
  backend bug above went undetected).
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
