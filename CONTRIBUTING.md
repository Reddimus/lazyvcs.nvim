# Contributing

## Requirements

- Neovim 0.10+ (CI pins 0.12.2)
- `git`, and `svn` if you want the Subversion specs to run instead of skip
- [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.3.0 and
  [lua-language-server](https://github.com/LuaLS/lua-language-server) 3.15.0
- Node 22+ for the Markdown formatter (`npm ci`)
- Docker, only for the container E2E suites

## Running the checks

CI runs these; run them before opening a pull request.

```sh
npm ci
npm run format:md:check                       # Markdown formatting
stylua --check lua tests                      # Lua formatting
lua-language-server --check=. --checklevel=Warning
bash -n tests/minitest.sh tests/e2e/*.sh      # shell syntax

nvim --headless -u NONE -l tests/native_smoke.lua   # startup smoke
nvim --headless -u NONE -l tests/run.lua            # spec suite
tests/minitest.sh                                   # sidebar UI tests
nvim --headless -u NONE -c 'helptags doc' -c 'quitall'
```

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
