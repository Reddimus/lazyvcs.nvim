# Contributing

## Requirements

- Neovim 0.11+. CI tests 0.11.0 (the supported floor), 0.11.7, and 0.12.4 on
  Linux; 0.11.7 and 0.12.4 on Windows; 0.12.4 on macOS.
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
npm run lint:md                               # markdownlint-cli2
npm run lint:links                            # local Markdown link targets
npm run audit                                 # npm audit --audit-level=high
stylua --check lua tests                      # Lua formatting
lua-language-server --check=. --check_format=pretty --checklevel=Warning
actionlint                                    # workflow lint
shellcheck tests/minitest.sh tests/ci/install-neovim.sh tests/e2e/*.sh
bash -n tests/minitest.sh tests/ci/install-neovim.sh tests/e2e/*.sh

nvim --headless -u NONE -l tests/native_smoke.lua   # startup smoke
nvim --headless -u NONE -l tests/run.lua            # spec suite
tests/minitest.sh                                   # sidebar UI tests
nvim --headless -u NONE -c 'helptags doc' -c 'quitall'
# `-u NONE` alone cannot find the plugin, so the health provider never loads and
# the check silently reports nothing. Put the checkout on the runtimepath and
# source the plugin file first -- this is what `.github/workflows/verify.yml`
# runs.
nvim --headless -u NONE -c 'set rtp+=.' -c 'runtime plugin/lazyvcs.lua' \
  -c 'checkhealth lazyvcs' -c 'quitall'
```

`lua-language-server` needs `VIMRUNTIME` exported — `.luarc.json` resolves the
Neovim runtime through `${env:VIMRUNTIME}/lua`.

On Windows, `tests/minitest.sh` is not usable directly; clone mini.nvim at the
commit pinned in that script, set `MINI_TEST_PATH`, and run
`nvim --headless -u NONE -l tests/minitest.lua` instead. PowerShell also does
not glob-expand `tests/e2e/*.sh` for native executables, so pass explicit paths
to `shellcheck`.

Container E2E (Linux + Docker):

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
- **Never block the UI thread.** Anything on a navigation, autocmd, or keystroke
  path must use the async backend functions (`load_base_async`,
  `blame_lines_async`). Synchronous VCS calls are acceptable only in
  `health.lua` and tests. A blocking call starves `vim.schedule` callbacks,
  which looks exactly like a deadlock from the outside.
- **Never let an error escape a `vim.schedule` or autocmd callback.** Headless
  Neovim only logs it, but interactive Neovim renders the traceback and blocks
  on the hit-enter prompt. Report failures with a single-line `util.notify`.
- **Go through `lazyvcs.backends`**, not `backends.git` or `backends.svn`
  directly, so every feature works in both VCSes.
- **Highlights link to standard groups** with `default = true` and are
  re-applied on `ColorScheme`. Never hardcode colors; colorschemes must be able
  to theme them.
- Paths are normalized with `vim.fs.normalize`. Tests must normalize
  `vim.fn.tempname()` too, or they fail on Windows with mixed separators.

## Commands

The plugin exposes exactly one user command, `:LazyVCS`, with subcommand
completion. New functionality is added as a subcommand in the `spec` table in
`lua/lazyvcs/commands.lua`, never as a new top-level command.

## Releasing

1. Move the `Unreleased` CHANGELOG entries under a new `## [x.y.z] - DATE`
   heading.
2. Commit, and confirm CI is green on `main`.
3. `git tag -a vx.y.z -m "vx.y.z" && git push origin vx.y.z`.

`.github/workflows/release.yml` extracts that CHANGELOG section and publishes
the GitHub release.
