# Contributing

## Requirements

- Neovim 0.11+. CI tests 0.11.0 (the supported floor), 0.11.7, and 0.12.5 on
  Linux; 0.11.7 and 0.12.5 on Windows; 0.12.5 on macOS.
- `git`, and `svn` if you want the Subversion specs to run instead of skip
- [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.5.2 and
  [lua-language-server](https://github.com/LuaLS/lua-language-server) 3.18.2
- Node 22+ for the Markdown tooling (`npm ci`)
- `actionlint` and `shellcheck` for the workflow and shell gates
- Docker, only for the container E2E suites

## Running the checks

CI runs all of these from the reusable `.github/workflows/verify.yml`; run them
before opening a pull request.

```sh
npm ci
npm run format:md:check                       # Markdown formatting
npm run lint:md                               # markdownlint
npm run lint:links                            # local Markdown link targets
npm run audit                                 # includes development dependencies
stylua --check lua tests                      # Lua formatting
lua-language-server --check=. --check_format=pretty --checklevel=Warning
actionlint                                    # workflow lint
shellcheck tests/minitest.sh tests/ci/install-neovim.sh tests/e2e/*.sh
bash -n tests/minitest.sh tests/ci/install-neovim.sh tests/e2e/*.sh

nvim --headless -u NONE -l tests/native_smoke.lua   # startup smoke
nvim --headless -u NONE -l tests/run.lua            # spec suite
tests/minitest.sh                                   # sidebar UI tests
nvim --headless -u NONE -c 'helptags doc' -c 'quitall'
# Load the plugin before checking health; -u NONE does not add this checkout.
nvim --headless -u NONE -c 'set rtp+=.' -c 'runtime plugin/lazyvcs.lua' \
  -c 'checkhealth lazyvcs' -c 'quitall'
```

Export `VIMRUNTIME` for LuaLS. `.luarc.json` uses `$VIMRUNTIME/lua`.

On Windows, `tests/minitest.sh` is not usable directly; clone mini.nvim at the
commit pinned in that script, set `MINI_TEST_PATH`, and run
`nvim --headless -u NONE -l tests/minitest.lua` instead. PowerShell also does
not glob-expand `tests/e2e/*.sh` for native executables, so pass explicit paths
to `shellcheck`.

Container E2E (Linux + Docker):

CI pulls the same pinned Docker Official Images from their public ECR mirror.
When a registry rate-limits the pull, `tests/e2e/image.sh` retries and then
pulls the same digest from mirror.gcr.io or Docker Hub.

```sh
tests/e2e/ubuntu-native.sh
tests/e2e/ubuntu-astronvim.sh
```

Without `svn` installed, the Subversion specs report `SKIP` rather than failing.
A green run on an svn-less machine therefore covers less than CI does.

## Conventions

- **Formatting is enforced.** `stylua.toml` pins the settings; do not
  hand-format.
- **Line endings are LF everywhere**, enforced by `.gitattributes`. On Windows,
  clone with `core.autocrlf=false` or let `.gitattributes` normalize the
  checkout.
- **Never block the UI thread.** Navigation, autocmds, and keystrokes use async
  backends (`load_base_async`, `blame_lines_async`). Synchronous VCS calls
  belong only in `health.lua` and tests.
- **Never let an error escape a `vim.schedule` or autocmd callback.** Headless
  Neovim only logs it, but interactive Neovim renders the traceback and blocks
  on the hit-enter prompt. Report failures with a single-line `util.notify`.
- **Go through `lazyvcs.backends`**, not `backends.git` or `backends.svn`
  directly, so every feature works in both VCSes.
- **Highlights link to standard groups** with `default = true` and are
  re-applied on `ColorScheme`. Never hardcode colors; colorschemes must be able
  to theme them.
- Window-option writes use the local-scope helpers in `lazyvcs.util`. Capture
  raw local values and restore them, including global-local fallback sentinels.
- Detach a buffer from diff mode before hiding it from a diff window. Use
  `util.show_win_buffer` for buffer replacements; callers reapply diff mode.
- Literal filesystem paths use `util.normalize_literal_path`, which disables
  environment expansion. Join relative repository entries to their root before
  normalization. Model paths are normalized without resolving symlinks, so
  status parsing adds no per-file realpath calls. Use
  `util.relative_literal_path` for lexical membership and nullable
  `util.relpath` for verified entry membership. Mutation callers must reject
  failures and recheck identity at command start. Expand paths only at explicit
  user-input boundaries, such as the sidebar path argument in `commands.lua`.
  Tests must normalize `vim.fn.tempname()` too, or they fail on Windows with
  mixed separators.

## Commands

The plugin exposes exactly one user command, `:LazyVCS`, with subcommand
completion. New functionality is added as a subcommand in the `spec` table in
`lua/lazyvcs/commands.lua`, never as a new top-level command.

## Releasing

1. Move the `Unreleased` CHANGELOG entries under a new `## [x.y.z] - DATE`
   heading.
2. Commit, and confirm CI is green on `main`.
3. `git -c gpg.format=ssh tag -s vx.y.z -m "vx.y.z" && git push origin vx.y.z`.

Use a signing key trusted by `.github/allowed_signers`. Verify the tag with
`git -c gpg.ssh.allowedSignersFile=.github/allowed_signers verify-tag vx.y.z`.

`.github/workflows/release.yml` extracts that CHANGELOG section and publishes
the GitHub release.

## Architecture

- `backends/` owns Git/SVN commands, entry eligibility, and immutable comparison
  data. Editable payloads retain complete raw bytes until the real buffer is
  available. Legacy `base_lines` payloads remain decoded UTF-8 with a final
  newline.
- `compare_text.lua` owns lossless byte conversion, decoded documents, and
  buffer text identities. `serialize()` produces normalized UTF-8 for diffing;
  `encode_file()` and `capture_file()` preserve file bytes for blame. Encoding
  requires an exact reverse conversion. Clean captures preserve read EOF state,
  while modified nonempty captures honor `fixendofline`. The module depends only
  on Neovim APIs. Native editable hunks use full documents, including
  empty-content and EOF state. Live diff bounds both raw and decoded content to
  1 MiB per side; signs also honor `signs.max_file_bytes`. Profile changes
  invalidate decoded bases. Revalidate entry eligibility and the captured
  context before native replacement.
- `source_control/jobs.lua` bounds and profiles repository/comparison commands.
- Source-control summaries own branch, upstream, and remote status. Details own
  local rows and counts. Merge each completion into the current repository
  generation without clearing the other request's loading flag. Manual refresh
  retains SVN incoming metadata until a successful replacement; mutations and
  project changes discard it.
- Sidebar window ownership requires the window to display its sidebar buffer.
  Pending opens capture the originating editor and buffer, and reject replaced
  owners or destinations.
- `source_control/persist.lua` writes independent project files and reads the
  legacy shared file without changing it. Same-project saves use the last write.
- `source_control/mutation_start.lua` holds one scheduler worker and one
  deadline across asynchronous preflight and mutation. Recheck branch and buffer
  guards before spawning the mutation; never enqueue preflight into the same
  queue.
- `compare.lua` owns review tabs, source-control navigation, and read-only
  previews. Its `set_panes()` transition installs both panes before publishing
  their slots and defers results while the picker router owns a borrowed buffer.
  Failed installations restore the preceding display or invalidate the session.
  Pane closure advances an epoch synchronously; asynchronous results must check
  that epoch and all pane windows before installation.
- `compare_navigation.lua` owns hunk navigation and per-path review positions.
- `compare_open.lua` routes file-opening actions without replacing review panes.
- `compare_buffers.lua` owns snapshot identity, reload guards, and bounded
  caching.
- `compare_actions.lua` shares action names across mappings, commands, and help.
- `compare_view.lua` builds file rows, highlights, and cached width
  measurements.
- Switch-target enumeration finalizes its own repository marker before checking
  sidebar liveness. A stale callback cannot clear another operation's marker.
- Commit message files are created exclusively with private permissions at
  process start and removed after process exit, including cancellation and spawn
  failure.
- Sidebar AI drafts belong to one state and repository root. Request tickets and
  draft revisions reject superseded responses. Context commands use the
  scheduler; repository cancellation also stops provider requests after context
  collection.
- `blame_context.lua` captures source identity and changedtick for blame
  requests.
- `blame_selection.lua` presents selected-line reports through a cancellable
  backend loader.
- `actions.lua`, `layout.lua`, and `state.lua` own editable per-file diff
  sessions.
- `highlighting.lua` uses native `winhighlight` overlays for inherited colors
  and strips copied overlays from unowned windows. Only explicit theme
  namespaces use its pool, which grows with concurrently managed custom
  namespaces.
- `signs.lua` and `blame.lua` own buffer state and cancel stale generations.
- New regression cases belong in sibling `tests/spec_*.lua` modules. The main
  spec is near LuaJIT's local-variable limit.

Comparison discovery parses bounded command output in O(output bytes), sorts
paths in O(files log files), and loads only the selected preview. Preview reads
are bounded to 1 MiB. Untracked SVN directory traversal does not follow
symlinks. Git rename detection has a limit of 1000 candidates. Repository
resolution uses at most 512 cached directories and shares concurrent probes for
one directory. Wrapped alignment takes O(log hunks + visible units) time and
O(visible units) space. The scheduler uses a priority heap with O(log queued)
enqueue/dequeue and a 4096-job limit per queue. Editor commands have separate
queues with two Git workers and one SVN worker, so background operations cannot
consume their capacity. Sidebar cancellation leaves editor requests running.

Use disposable repositories for mutation tests. For live terminal validation,
exercise keyboard and mouse actions in both vanilla Neovim and AstroNvim; verify
actual buffer contents and repository state as well as the rendered screen.

Comparison rows take O(displayed bytes) time and space per snapshot. Width
changes use cached measurements; cursor movement does not load previews.
Selection blame sends one bounded request chain, never a command per line. Git
maps selections to historical ranges on older Git; SVN maps historical blame
through decoded captured contents. Git receives file bytes with its attributes
and filters active. Representations that may use a different Git line model
require bounded full-file blame and record-count validation before selecting
editor lines. Ordinary selections and line history keep bounded `-L` requests.
CI also runs native E2E with Ubuntu 22.04 Git.

Compare file navigation selects its destination in O(1) and loads only that
preview. Review history stores O(visited paths) view metadata, prunes removed
paths, and resets when the pinned base changes. Snapshots use an O(1) LRU cache
with a default limit of 32 file pairs, plus current, visible, or pending files.
Each side is bounded to 1 MiB. The cache does not alter AstroNvim's ordinary
buffer list.
