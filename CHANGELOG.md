# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.3] - 2026-09-03

Safety release for repository mutations and background work.

### Fixed

- Destructive actions confirm consistently and refuse to act when the buffer,
  cursor, or selected hunk changed while the confirmation was open.
- Cancelling a repository operation clears work owned by both the sidebar and
  the repository.
- Configuration and JSON writes handle partial writes without leaving a
  truncated file.
- The supported-version table in `SECURITY.md` matches the current release.

## [0.6.2] - 2026-09-03

Safety and maintenance release. Repository actions now protect unsaved buffer
changes without blocking operations that leave the worktree untouched.

### Fixed

- Worktree-changing Git and Subversion operations stop before overwriting a
  modified buffer in the target repository.
- The buffer guard resolves relative paths, repository symlinks, tracked
  symlinks, and external aliases that point back to tracked files.
- Push-only sync and creating a branch at the current `HEAD` remain available
  with modified buffers because neither operation rewrites the worktree.
- Mutation failures keep bounded output so a noisy process cannot grow memory
  without limit. Truncated streams retain their beginning and report omitted
  bytes.
- Safety cleanup tests use valid Lua types under strict language-server checks.

### Documentation

- Replaced the long README reference manual with a first-run guide and links to
  the complete built-in help.

### Internal

- Kept CodeQL setup and analysis actions on the same version and grouped their
  dependency updates.
- Updated the checkout action and hardened pull-request review automation.

## [0.6.1] - 2026-08-07

Correctness release. Opening the source-control sidebar no longer blocks Neovim,
and repository identity, job cancellation and text truncation are all fixed in
ways that show up most on macOS.

### Fixed

- **Opening the sidebar froze Neovim while it looked for repositories.**
  `native.open` rendered before starting discovery, and rendering fell back to
  the synchronous discoverer: a recursive directory walk plus a blocking
  `git rev-parse` **and** `svn info`, each with a 30-second cap. Because that
  fallback also populated the spec list, the asynchronous discovery added in
  0.5.0 could never start — it was unreachable code. The sidebar now paints
  immediately, shows `Discovering repositories...` while the scan runs, and
  fills in as results arrive. An unreachable Subversion server no longer costs a
  minute of frozen editor.
- **`R` (refresh) never looked for new repositories.** It cleared caches but
  kept the existing spec list, so a repository created after the sidebar opened
  stayed invisible until the sidebar was closed and reopened.
- **The same repository could end up with two identities.** Roots were compared
  as text, so `/tmp/work` and `/private/tmp/work` — the same directory on macOS,
  where `/tmp` and `/var` are symlinks into `/private` — did not match. Git and
  Subversion both report resolved paths, so a sidebar opened from an unresolved
  path disagreed with its own backend and its caches, jobs and sessions stopped
  matching. Roots are now canonicalised through `fs_realpath`.
- **Cancelling background work could leave some of it running.** `jobs.cancel`
  took one snapshot of matching jobs, but finishing a job runs its callback
  synchronously, and those callbacks queue more work — so a job enqueued during
  the sweep survived it. Cancellation now repeats until a pass finds nothing
  new, and holds the queues until it has converged.
- **Closing the sidebar did not cancel branch/target enumeration**, which could
  still open a picker afterwards. Its jobs are now owned by the sidebar, scoped
  per repository, and given their own generation — previously they borrowed the
  hydration counter, whose watermark outlived the sidebar and could reject a new
  sidebar's first enumeration as stale.
- **Aborting one buffer transfer cancelled every other window's.** The abort
  paths asked for the current window's pending transfer but then cleared all of
  them, stranding unrelated sessions.
- **Inline blame could be cut mid-character and overflow its width.**
  `blame.max_width` is a column budget but was measured in bytes, so CJK text or
  an emoji produced roughly double-width virtual text and could split a UTF-8
  sequence. Truncation is now cell-aware, and the byte-budget helper never
  splits a character.
- **Git and Subversion were assumed missing for the rest of the session** if the
  first probe failed. A GUI-launched Neovim inherits launchd's `PATH` on macOS,
  so `/opt/homebrew/bin` is absent and both probes fail; correcting `PATH`
  afterwards had no effect until restart. The probe now re-runs when `PATH`
  changes.
- `util.trim` returned two values (the trimmed string and the substitution
  count), so both backends' `get_root` handed callers a number where an error
  was expected.
- A blame split leaked its autocommand group if construction failed partway, and
  allocated a new namespace per buffer — namespaces cannot be deleted.
- Failures to persist state were discarded silently; they now warn once.

### Changed

- The sidebar shows `Discovering repositories...` rather than
  `No repositories selected` while a scan is in flight.

### Documentation

- Removed `:LazyVCS diff cancel` from `doc/lazyvcs.txt`; no such verb exists.
- Documented the sidebar's `q` and `X` mappings, and that sidebar mappings are
  fixed rather than configurable through `config.keymaps`.
- Corrected the `:checkhealth lazyvcs` command in `CONTRIBUTING.md`, which could
  not find the plugin as written.

### Internal

- The CI whitespace check used `git diff-tree --check --cc`. A combined diff
  only lists files that differ from _every_ parent, so a pull request's own
  changes were omitted and the check passed unconditionally. It now diffs an
  explicit range.
- Test fixtures no longer inherit the developer's git configuration; a
  contributor with commit or tag signing enabled globally saw three unrelated
  specs fail.
- New specs live in `tests/spec_discovery.lua`: `tests/spec.lua` reached
  LuaJIT's limit of 200 local variables per function.

## [0.6.0] - 2026-08-05

Live-diff synchronisation release. The two panes now stay together under every
scroll gesture, including with soft wrapping on, where they previously drifted
apart and never recovered.

### Added

- `base_window.align_wrapped` (`"off"` by default, or `"auto"`) keeps
  corresponding diff lines on the same screen row when the panes wrap. Neovim's
  `'scrollbind'` binds buffer lines, not screen rows, so a line that occupies
  four rows on one side and one on the other pushed everything below it out of
  alignment — and because nothing reconciled the difference, the error
  accumulated down the file. Corresponding text is paired into units and the
  shorter side padded with virtual rows. Measured against a wrapped fixture in a
  real terminal, 18 of 31 visible lines were misaligned before and 0 after.

  It is **off by default**. The padding is drawn with extmarks, which Neovim's
  own scroll binding cannot see, so the two disagree about position _while
  scrolling_ and the panes can land on different lines until the view settles.
  With `"auto"` the result is exact once the view is still, which is the right
  trade for reading a diff and the wrong one for scrolling through it. The
  padding adds no text, so undo, marks, and the file on disk are untouched, and
  it is skipped while the same file is open in another window.

- `base_window.cursor_sync` (`true` by default) keeps the two cursors on
  corresponding lines.

### Fixed

- A scroll event reporting **both** panes now follows the focused pane instead
  of declining to act, correcting the `topfill` and offset differences that were
  previously swallowed. It still defers to Neovim when the panes wrap and
  alignment is on: `:syncbind` sets a _relative_ offset that drifts under
  `'wrap'`, so intervening there pulled correctly-bound panes apart.
- `'scrollbind'` and `'cursorbind'` are re-asserted after `:diffthis`. Both are
  reset to the global value when a window edits another file, and an ftplugin or
  colorscheme loading afterwards could clear them — silently unbinding the pair
  with no symptom other than scrolling appearing to stop working.
- Resizing the window or rebalancing the split re-synchronises the panes. Only
  the widths were adjusted, which re-wraps every line and left the pair offset.
- A `WinScrolled` event naming neither pane returns immediately. The autocmd is
  global and one is registered per live session, so every session previously did
  work for every unrelated scroll.
- `'smoothscroll'` is saved and restored with the other tracked window options.

## [0.5.0] - 2026-07-28

Hardening release. An exhaustive audit of the 0.4.x tree produced 32 confirmed
findings, tracked as #17-#24; this release fixes all of them, along with
independent findings from a follow-up architecture review. Every user-facing
command keeps working — the only breaking change is the `mutation_timeout_ms`
default described below.

### Changed

- **Breaking:** `source_control.background.mutation_timeout_ms` now defaults to
  `120000` instead of being unlimited, and `0` is rejected at setup. A mutation
  that hangs forever cannot be told apart from one still running, so it now
  always has a finite deadline. If you previously set it to `0`, choose a real
  timeout instead.
- Every source-control command now runs through one bounded, cancellable
  scheduler. Tasks carry an owner, scope, repository, generation, priority,
  timeout, and output limit; Git and SVN get separate worker pools
  (`background.git_workers`, `background.svn_workers`). Timeouts escalate
  `SIGTERM` to `SIGKILL` after a grace period, and a worker slot is held until
  the child process is actually reaped.
- Repository discovery, status hydration, branch switching, blame, and signs are
  asynchronous and cancellable. Synchronous subprocess calls have been removed
  from user-facing paths.
- Collapsed sidebar sections no longer build their children, and renders are
  coalesced and cached per revision, so large repositories stay responsive.
- `ai.commit_message.context` accepts `staged_first`, `staged`, `unstaged`,
  `all`, or `status`.
- Each live-diff keymap in `keymaps` may be `false` to leave the key unmapped.
  Empty strings are rejected, and binding two actions to the same key is a
  configuration error.
- Unknown or removed configuration keys are reported once at startup instead of
  being ignored silently.

### Added

- `:LazyVCS sidebar cancel [path]` and
  `require("lazyvcs").source_control_cancel(path?)` cancel in-flight work,
  returning the number of cancelled tasks. `X` in the sidebar cancels the
  repository under the cursor.
- `:LazyVCS profile` shows recent command timings from a bounded history ring
  (`background.history_limit`).
- `source_control.remote_error_notifications` (`summary`, `inline`, `notify`) is
  now implemented rather than inert.
- `SECURITY.md`, a documented vulnerability-reporting path, and
  `.github/allowed_signers` so release tags are SSH-signed and verifiable.
- CodeQL analysis for GitHub Actions, Markdown lint and local-link checking,
  `actionlint`, `shellcheck`, and an npm audit gate. CI and release now share
  one reusable exact-commit verification workflow covering Neovim 0.11.0,
  0.11.7, and 0.12.4 on Linux, 0.11.7 and 0.12.4 on Windows, and 0.12.4 on
  macOS, plus both container E2E suites.

### Fixed

- Diff sessions are created transactionally: overwritten mappings and window
  options are restored exactly, and only session-owned windows are reset. Global
  `diffoff!` is never used, so unrelated diff groups are left alone.
- Splits that LazyVCS opens for a comparison are now owned and closed by the
  session, instead of leaking duplicate sidebar windows.
- Cancelling or invalidating one repository no longer strands its siblings in a
  permanent loading state, and no longer cancels work belonging to a different
  sidebar or tab.
- Prompts, confirms, and the AI commit popup are owned by a single modal
  lifecycle, so `<Esc>`, `:q`, and external window closure all cancel the
  underlying task exactly once.
- AI diff context is passed over stdin or a private `0600` attachment that is
  deleted on completion, so it never appears in process arguments or task
  listings.
- SVN status parsing uses a real entity-aware XML parser covering every status
  class, replacing regex matching.
- Persisted state is written atomically through a versioned schema with a
  migration from the 0.4.x format.
- Test fixtures build `file://` URLs correctly on Windows. They previously
  produced `file://C:/...`, which Subversion parses with `C:` as the URL
  authority; because CI's Windows runner has no `svn`, those specs skipped and
  the breakage stayed invisible.

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
[0.3.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.2.1...v0.3.0
[0.4.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.3.0...v0.4.0
[0.4.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.4.0...v0.4.1
[0.4.2]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.4.1...v0.4.2
[0.5.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.4.2...v0.5.0
[0.6.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.5.0...v0.6.0
