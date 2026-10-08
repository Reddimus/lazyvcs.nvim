# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.0] - 2026-10-08

### Added

- Cycle Compare files with `]b` and `[b`, including counts such as `3]b`.
  Revisiting restores both panes' review positions without adding editing
  buffers.
- Add `:LazyVCS compare next` and `prev`, Lua `compare_next(count)` and
  `compare_prev(count)`, and configurable file navigation keys.

### Fixed

- Open AstroNvim file and grep search results from Compare without `E1513`. Keep
  the diff panes and focus the selected saved line.
- Keep Compare actions such as `e` available in both panes after filetype
  changes. Explain when the file list already fits or cannot widen further.
- Clear pending focus requests when a comparison preview fails.
- Restore horizontal scrolling and keep reviewed lines visible inside folds.

## [0.9.0] - 2026-10-08

### Added

- Navigate Compare hunks with `]v` and `[v` from either pane or the file list.
- Review files with Enter or double-click, preview with `P`, and return with
  `Esc`. First activation focuses the first hunk; later activation preserves
  your position. Deleted files focus the base pane.
- Document `<leader>vc` and `<leader>vC` shortcuts for lazy.nvim and AstroNvim.

### Fixed

- Choose a comparison base from the editor even when a remembered base exists.
- Cancel stale preview focus requests after navigation, refresh, or closing.
- Keep deletion anchors and folded hunks visible when navigating.
- Remove vulnerable glob tooling from Markdown checks and update its math
  parser.

## [0.8.1] - 2026-10-01

### Fixed

- Use normal syntax colors in every diff pane, including LSP-inactive code. Set
  `diff_highlighting = "editor"` to retain semantic colors.
- Preserve other windows' colors and restore theme namespaces when diffs close.
- Update security-support versions and shorten documentation and comments.

## [0.8.0] - 2026-09-10

### Added

- Open repository comparisons with `C` or repository actions in source control.
- Blame visually selected lines in editor buffers and comparison text panes.

### Changed

- Comparison rows show filenames first, theme colors, and the previewed-file
  marker.
- In Compare, `e` fits the sidebar width and `o` edits the file.
- The sidebar mapping returns to source control; reopening refreshes the
  existing comparison and preserves your place.

### Fixed

- Keep saved-pane attribution pinned on older Git versions.
- Skip automatic SVN blame for new unsaved files without an SVN error.
- Preserve manual widths, selection, and preview positions across refreshes and
  resizing.
- Keep help and metadata separate from pending text previews.
- Avoid orphaned blank buffers and editing into plugin-owned windows.

## [0.7.1] - 2026-09-10

### Fixed

- Updated the Markdown tooling's TOML parser to fix GHSA-7w5x-hrqm-74c2.
- Dependency audits now include development tools.
- The confirmation UI test waits for repository discovery before checking cursor
  restoration, avoiding a timing race on slower runners.

## [0.7.0] - 2026-09-10

### Added

- Read-only total comparisons against a chosen Git base or SVN URL/revision,
  with remembered bases, saved untracked files, and explicit editing.
- Sidebar help and a scrollable job profile.

### Fixed

- Automatic blame skips ignored and untracked files without notifications.
- SVN blame maps saved and unsaved edits to the correct lines and handles `@`
  filenames. Git blame accepts SHA-256 commit IDs.
- Cancelled blame resolution can restart. Typed diff refresh preserves its
  sources.
- Incomplete command output is rejected before diffing or reverting.
- Missing comparison content no longer hides unrelated command failures.
- Repository probes share in-flight work and use a bounded cache. Wrapped diff
  alignment limits work and allocations to the visible viewports. Editor
  requests have reserved workers so sidebar commands cannot block them.
- Conflict comparisons handle missing index stages, including add/add and
  delete/modify conflicts. Automatic signs skip unmerged index entries. Git
  diagnostics use a stable locale.
- Signs defer to gitsigns before loading content and reuse unchanged renders.
- Blame and signs check both disk and buffer sizes.

### Maintenance

- Updated stable CI to Neovim 0.12.5 with verified release checksums.
- Shortened setup documentation and corrected signed-release instructions.

### Previously unreleased safety fixes

- Destructive actions confirm consistently and refuse to act when the buffer,
  cursor, or selected hunk changed while the confirmation was open.
- Whole-file discards always show their own confirmation, even when
  `confirm_mutations` is off or session prompts have been suppressed.
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

### Fixed

- Sidebar discovery runs asynchronously and shows a loading state. Unreachable
  SVN servers no longer freeze the editor during discovery.
- Refresh discovers repositories created or removed since the sidebar opened.
- Canonical root identities keep symlinked macOS paths in the same cache and
  session.
- Cancellation drains jobs queued by completion callbacks. Closing the sidebar
  also cancels branch enumeration and prevents late pickers.
- Aborting a buffer transfer leaves other windows' transfers running.
- Blame width uses terminal cells; byte truncation preserves UTF-8 characters.
- Executable probes rerun after PATH changes, including Homebrew configuration.
- `util.trim` returns only the string. Failed blame construction cleans up
  autocommands, blame splits reuse a namespace, and persistence failures warn
  once.

### Maintenance

- Corrected help commands and fixed sidebar mapping documentation.
- CI checks explicit diff ranges, including pull-request merge commits.
- Test fixtures ignore developer Git configuration. New specs live in sibling
  modules because the main spec reached LuaJIT's local-variable limit.

## [0.6.0] - 2026-08-05

### Added

- `base_window.align_wrapped = "auto"` pads wrapped diff lines to align their
  screen rows. The default is "off" because native scroll binding cannot see
  virtual padding. Padding changes no text and is skipped when another window
  shows the same buffer.
- `base_window.cursor_sync` defaults to true.

### Fixed

- Scroll events follow the focused pane when both move, except when wrapped
  alignment already relies on native binding.
- Reassert `scrollbind` and `cursorbind` after `diffthis`.
- Resizing and rebalancing resynchronize panes. Unrelated scroll events are
  ignored.
- Restore `smoothscroll` with the other window options on close.

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

- The asynchronous SVN cancellation test skips when SVN is unavailable and
  restores its mocked process launcher after assertion failures.

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

- Missing SVN no longer breaks Git workflows. Missing subprocess executables
  return a failure result instead of raising.
- Tests report individual failures and skips, continue through the suite, and
  return a failing exit status when needed. SVN fixtures skip without svnadmin.

### Added

- GitHub Actions for CI, tagged releases, and Docker AstroNvim E2E.
- Help-tag generation checks, a changelog, and the README CI badge.

[0.1.0]: https://github.com/Reddimus/lazyvcs.nvim/releases/tag/v0.1.0
[0.2.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.1.0...v0.2.0
[0.2.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.2.0...v0.2.1
[0.3.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.2.1...v0.3.0
[0.4.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.3.0...v0.4.0
[0.4.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.4.0...v0.4.1
[0.4.2]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.4.1...v0.4.2
[0.5.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.4.2...v0.5.0
[0.6.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.5.0...v0.6.0
[0.6.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.6.0...v0.6.1
[0.6.2]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.6.1...v0.6.2
[0.7.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.6.2...v0.7.0
[0.8.0]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.7.0...v0.7.1
[0.8.1]: https://github.com/Reddimus/lazyvcs.nvim/compare/v0.8.0...v0.8.1
