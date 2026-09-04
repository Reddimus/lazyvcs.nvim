# lazyvcs.nvim

[![CI](https://github.com/Reddimus/lazyvcs.nvim/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Reddimus/lazyvcs.nvim/actions/workflows/ci.yml)

`lazyvcs.nvim` brings Git and Subversion workflows into Neovim. It provides a
source-control sidebar, an editable live diff, gutter signs, hunk actions, and
blame without requiring Neo-tree. It works with vanilla Neovim, lazy.nvim, and
AstroNvim on Linux, macOS, and Windows.

## Features

- Browse nested Git and SVN repositories in one native sidebar.
- Stage, unstage, revert, commit, sync, and switch branches or SVN targets.
- Edit a file beside its Git index or SVN `BASE` version.
- Navigate, preview, and revert hunks without leaving the buffer.
- Show inline or split blame for Git and SVN files.
- Use installed pickers and commit-message providers when available.
- Scan repositories in small batches and keep VCS commands off Neovim's UI
  thread.

## Requirements

- Neovim 0.11 or newer
- `git` for Git repositories
- `svn` for Subversion working copies
- A Nerd Font for sidebar icons, recommended but optional

## Install

Add this lazy.nvim spec, restart Neovim, then run `:checkhealth lazyvcs`:

```lua
{
  "Reddimus/lazyvcs.nvim",
  main = "lazyvcs",
  event = { "BufReadPost", "BufNewFile" },
  cmd = { "LazyVCS" },
  keys = {
    { "<leader>vs", "<cmd>LazyVCS<cr>", desc = "Toggle VCS sidebar" },
    { "<leader>vo", "<cmd>LazyVCS diff open<cr>", desc = "Open VCS diff" },
    { "<leader>vr", "<cmd>LazyVCS hunk revert<cr>", desc = "Revert VCS hunk" },
    { "]v", "<cmd>LazyVCS hunk next<cr>", desc = "Next VCS hunk" },
    { "[v", "<cmd>LazyVCS hunk prev<cr>", desc = "Previous VCS hunk" },
  },
  opts = {},
}
```

For AstroNvim, save the same spec as `lua/plugins/lazyvcs.lua`. The plugin has
no required Lua dependencies. It detects `gitsigns.nvim`, `snacks.nvim`,
`fzf-lua`, and supported commit-message providers if they are already present.

## First run

Start Neovim from inside a Git or SVN working copy, open a file, then try:

```vim
:LazyVCS diff open
:LazyVCS blame toggle
:LazyVCS
```

The live diff puts the VCS base on the left and the editable file on the right.
Normal undo works after a hunk revert.

## Main commands

| Command                            | Purpose                              |
| ---------------------------------- | ------------------------------------ |
| `:LazyVCS`                         | Toggle the source-control sidebar    |
| `:LazyVCS sidebar open [path]`     | Open the sidebar at a workspace root |
| `:LazyVCS diff open`               | Open the current file's live diff    |
| `:LazyVCS diff close`              | Close the live diff                  |
| `:LazyVCS hunk next` / `hunk prev` | Move between hunks                   |
| `:LazyVCS hunk revert`             | Revert the hunk under the cursor     |
| `:LazyVCS blame toggle`            | Toggle inline Git or SVN blame       |
| `:LazyVCS blame split`             | Toggle a full-file blame split       |
| `:LazyVCS files`                   | Pick from changed files              |
| `:LazyVCS health`                  | Run the health check                 |

Press `<Tab>` after `:LazyVCS ` to complete commands. Inside the sidebar, press
`s` or `.` for repository actions, `c` to commit, `b` to switch, `R` to refresh,
and `q` to close. See `:help lazyvcs-mappings` for the full list.

## Configure

Defaults are conservative. Replace `opts = {}` in the install spec with this
example to refresh remotes when the sidebar opens and keep blame off until
requested without persisting the toggle:

```lua
opts = {
  blame = { mode = "inline", persist = false },
  source_control = {
    remote_refresh = "on_open",
    scan_depth = 3,
    show_clean = false,
  },
}
```

Use `:help lazyvcs-configuration` for every option. Unknown or removed options
produce one startup warning so stale configuration does not fail silently.

Before any worktree-changing repository action, LazyVCS checks modified buffers
that point into the repository, including symlink aliases. Save or discard those
changes before continuing. Push-only actions and a new branch at the current
`HEAD` remain available because they do not rewrite files.

## Where things live

| Path                 | Contents                             |
| -------------------- | ------------------------------------ |
| `lua/lazyvcs/`       | Plugin code and VCS backends         |
| `plugin/lazyvcs.lua` | Neovim command entry point           |
| `doc/lazyvcs.txt`    | Complete user help                   |
| `tests/`             | Unit, integration, UI, and E2E tests |
| `CONTRIBUTING.md`    | Development workflow and conventions |
| `CHANGELOG.md`       | Release notes                        |
| `SECURITY.md`        | Security reporting policy            |

## Develop

Run the main local checks from the repository root:

```sh
npm ci && npm run format:md:check && npm run lint:md && npm run lint:links
stylua --check lua tests && nvim --headless -u NONE -l tests/run.lua
tests/minitest.sh
```

The full cross-platform gate and tool versions are documented in
[`CONTRIBUTING.md`](CONTRIBUTING.md). CI also tests the supported Neovim
versions and the AstroNvim integration.

## More help

- Run `:help lazyvcs` for features, mappings, and configuration.
- Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before changing the plugin.
- Check [`CHANGELOG.md`](CHANGELOG.md) before upgrading.
- Report security issues through [`SECURITY.md`](SECURITY.md).
