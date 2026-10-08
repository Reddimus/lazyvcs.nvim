# lazyvcs.nvim

[![CI](https://github.com/Reddimus/lazyvcs.nvim/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Reddimus/lazyvcs.nvim/actions/workflows/ci.yml)

Git and Subversion in Neovim: a repository sidebar, editable live diffs, branch
comparisons, hunk actions, and blame. Works with vanilla Neovim and AstroNvim on
Linux, macOS, and Windows. No required Lua dependencies.

## Requirements

- Neovim 0.11 or newer.
- `git` or `svn` for the repositories you use.
- A Nerd Font for icons, optional.

## Install

With lazy.nvim:

```lua
{
  "Reddimus/lazyvcs.nvim",
  main = "lazyvcs",
  event = { "BufReadPost", "BufNewFile" },
  cmd = "LazyVCS",
  keys = {
    { "<leader>vc", "<cmd>LazyVCS compare<cr>", desc = "Compare against base" },
    { "<leader>vC", "<cmd>LazyVCS compare base<cr>", desc = "Choose comparison base" },
  },
  opts = {},
}
```

For AstroNvim, put `return { ... }` around this spec and save it as
`lua/plugins/lazyvcs.lua`. Restart Neovim and run `:checkhealth lazyvcs`.

Without a plugin manager, clone the repository into
`stdpath("data")/site/pack/plugins/start/lazyvcs.nvim` and add
`require("lazyvcs").setup()` to your `init.lua`.

## Start here

Open a file inside a Git or SVN working copy:

| Command                 | What it does                                       |
| ----------------------- | -------------------------------------------------- |
| `:LazyVCS`              | Browse repositories, changes, and actions          |
| `:LazyVCS diff open`    | Edit beside the Git index or SVN BASE              |
| `:LazyVCS compare`      | Review total saved changes against a chosen base   |
| `:LazyVCS hunk next`    | Jump to the next hunk; `hunk prev` moves back      |
| `:LazyVCS hunk revert`  | Revert the current hunk; normal undo still works   |
| `:LazyVCS blame toggle` | Toggle inline blame; `blame split` shows all lines |

Press `<Tab>` after `:LazyVCS ` for command completion. In the sidebar, `C`
compares a repository against a base. `.` opens repository actions, `c` commits,
`b` switches branches or SVN targets, `R` refreshes, `?` shows help, and `q`
closes it.

## Compare a branch

Run `:LazyVCS compare` and choose a Git branch/commit or SVN `URL@revision`. The
choice is remembered for the current worktree and branch.

Git compares the common ancestor with your saved working tree, including
committed, staged, unstaged, and nonignored untracked changes. SVN compares the
selected repository revision with the working copy. Save buffers before
refreshing to include their latest edits.

The comparison tab has a file list and two read-only panes. Press `Enter` or
double-click a file to review its first hunk. `]v` and `[v` move between hunks
and wrap within that file. `Esc` returns to the list; `P` previews without
leaving it. Deleted files open in the base pane.

Press `e` to widen the list, `o` to edit, `R` to refresh, or `b` to change the
base. `q` closes Compare; your sidebar mapping returns to source control.
Reopening and refreshing preserve your position. The installation mappings use
`<leader>vc` to open Compare and `<leader>vC` to choose its base. Binary and
oversized files remain listed without a text preview.

## Blame selected lines

Select lines, then run `:LazyVCS blame`. Vim supplies the selected range. This
also works in Compare's text panes. `q` closes the report. Unsaved edits are
marked uncommitted in editor buffers.

Optional visual mapping:

```lua
vim.keymap.set("x", "<leader>vb", "<Plug>(LazyVCSBlameSelection)")
```

## Configure

Keep inline blame off between sessions:

```lua
opts = { blame = { persist = false } }
```

Defaults avoid remote refreshes unless requested. Git signs are delegated to
`gitsigns.nvim` when installed. Optional pickers and commit-message providers
are detected automatically. See `:help lazyvcs-configuration` for all options.

Diff panes use normal syntax colors, including code an LSP marks inactive. Set
`diff_highlighting = "editor"` to keep LSP semantic colors in comparisons.

## Help and contribute

- `:help lazyvcs` covers commands, mappings, and configuration.
- [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, checks, architecture, and
  releases.
- [CHANGELOG.md](CHANGELOG.md) lists changes.
- [SECURITY.md](SECURITY.md) explains private security reporting.
