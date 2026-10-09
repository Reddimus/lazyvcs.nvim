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
  event = { "BufReadPost", "BufNewFile", "BufReadCmd lazyvcs://compare/*" },
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

The comparison uses native Neovim buffers and windows. Press `Enter` or
double-click a file in the list to focus its first hunk. `]v` and `[v` cycle
hunks; `]b` and `[b` cycle files and restore your position. Both wrap, and file
counts work, such as `3]b`. These mappings apply only in Compare.

Text panes keep normal Vim motions, search, macros, marks, and jump history.
Both panes are read-only snapshots of saved contents. Use `<leader>vf` for the
file list, `<leader>ve` to edit at your review position, or `<leader>v?` for
help. File and grep searches, including AstroNvim's `<leader>ff` and
`<leader>fw`, open actual files in your editing window.

In the file list, `P` previews, `e` fits the width, `o` edits, `R` refreshes,
`b` changes the base, `p` toggles metadata, and `q` closes. From any Compare
pane, use `:LazyVCS compare width`, `metadata`, `refresh`, or `close`. The
installation mappings use `<leader>vc` to compare and `<leader>vC` to choose a
base. Deleted files focus the base pane; binary and oversized files remain
listed without a text preview.

Snapshots are unlisted and loaded on demand; ordinary buffer cycling stays
unchanged. Compare keeps up to 32 cached files, plus visible or pending files.
Eviction drops snapshot marks and jumps; review positions remain remembered. Set
`compare.max_cached_files = 0` for an unlimited cache. Customize or disable pane
shortcuts with
`compare.keymaps = { files = "<leader>vf", edit = "<leader>ve", help = "<leader>v?" }`;
use `false` to disable a key.

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
