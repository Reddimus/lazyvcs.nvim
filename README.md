# lazyvcs.nvim

[![CI](https://github.com/Reddimus/lazyvcs.nvim/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Reddimus/lazyvcs.nvim/actions/workflows/ci.yml)

Git and Subversion in Neovim: a repository sidebar, editable live diffs, branch
comparisons, hunk actions, and blame. Works with vanilla Neovim and AstroNvim on
Linux, macOS, and Windows. No required Lua dependencies.

## Requirements

- Neovim 0.11 or newer. On Windows, use a standard LuaJIT build.
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
    { "<leader>vs", "<cmd>LazyVCS<cr>", desc = "Toggle VCS sidebar" },
    { "<leader>vo", "<cmd>LazyVCS diff open<cr>", desc = "Open VCS diff" },
    { "<leader>vq", "<cmd>LazyVCS diff close<cr>", desc = "Close VCS diff" },
    { "<leader>vr", "<cmd>LazyVCS hunk revert<cr>", desc = "Revert VCS hunk" },
    { "<leader>vb", "<cmd>LazyVCS blame toggle<cr>", desc = "Toggle VCS blame" },
    { "<leader>vc", "<cmd>LazyVCS compare<cr>", desc = "Compare against base" },
    { "<leader>vC", "<cmd>LazyVCS compare base<cr>", desc = "Choose comparison base" },
    { "]v", "<cmd>LazyVCS hunk next<cr>", desc = "Next VCS hunk" },
    { "[v", "<cmd>LazyVCS hunk prev<cr>", desc = "Previous VCS hunk" },
  },
  opts = {},
}
```

The `BufReadCmd` event loads LazyVCS when Neovim rereads a Compare snapshot
buffer, such as after `:edit`.

For AstroNvim, put `return { ... }` around this spec and save it as
`lua/plugins/lazyvcs.lua`. Restart Neovim and run `:checkhealth lazyvcs`.
Sidebar diffs use your editing window alongside Neo-tree. With Resession
installed, session saves preserve the editor's pre-diff window options without
restoring temporary LazyVCS panes.

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

Native hunks preserve supported text encodings and EOF state and refuse symlink
bases. See `:help lazyvcs-notes` for limits and undo behavior.

Press `<Tab>` after `:LazyVCS ` for command completion. In the sidebar, `C`
compares a repository against a base. `.` opens repository actions, `c` commits,
`b` switches branches or SVN targets, `R` refreshes, `?` shows help, and `q`
closes it.

## Compare a branch

Run `:LazyVCS compare` and choose a Git branch/commit or SVN `URL@revision`. The
choice is remembered for the current worktree and branch.

Omitted sparse-checkout files use read-only index snapshots.

Git compares the common ancestor with your saved working tree, including
committed, staged, unstaged, and nonignored untracked changes. SVN compares the
selected repository revision with the working copy. The file list reflects saved
changes; save and refresh to discover new paths.

The comparison uses native Neovim buffers and windows. Press `Enter` or
double-click a file in the list to focus its first hunk. `]v` and `[v` cycle
hunks; `]b` and `[b` cycle files and restore your position. Both wrap, and file
counts work, such as `3]b`. These mappings apply only in Compare.

Text panes keep normal Vim motions, search, macros, marks, and jump history. The
right pane edits the real file, including unsaved changes; the left stays
read-only. Save with `:write`. Edited buffers survive closing Compare. Symlinks,
deleted files, and other unsupported paths use read-only snapshots. Set
`compare.editable = false` to use snapshots throughout. Use `<leader>vf` for the
file list, `<leader>ve` for your original editing window, or `<leader>v?` for
help. File and grep searches, including AstroNvim's `<leader>ff` and
`<leader>fw`, open other files in your editing window. Searching within the
displayed working file jumps directly in its editable pane.

In the file list, `P` previews, `e` fits the width, `o` edits, `R` refreshes,
`b` changes the base, `p` toggles metadata, and `q` closes. From any Compare
pane, use `:LazyVCS compare width`, `metadata`, `refresh`, or `close`. The
installation mappings use `<leader>vc` to compare and `<leader>vC` to choose a
base. Deleted files focus the base pane; binary and oversized files remain
listed without a text preview. SVN properties remain available through metadata.
Snapshots decode each source to UTF-8 for display, including Git
`working-tree-encoding` files, while blame retains the original bytes. Display
normalizes CRLF to LF on both sides and preserves lone CR characters as content.
Editable Compare instead reads the base with the real buffer's newline format.
Hunk navigation from metadata loads the text before jumping.

Files load on demand; Compare does not fill your ordinary buffer list. Editing a
file adds it to that list. Native jumps can also list their destination.
Controls apply only while a Compare pane has focus. Compare keeps up to 32
cached snapshots, plus current, visible, or pending files. Eviction drops
snapshot marks and jumps; review positions remain remembered. Private working
buffers used by pane jump history stay loaded until their jump entries expire or
Compare closes. Set `compare.max_cached_files = 0` for an unlimited cache.
Customize or disable pane shortcuts with
`compare.keymaps = { files = "<leader>vf", edit = "<leader>ve", help = "<leader>v?" }`;
use `false` to disable a key.

## Known limits

- Compare panes are diff windows. As with any diff window, a split of a pane, or
  another window in Compare's tab that shows a pane's file, starts in diff mode;
  `:diffoff` ends it. Diff mode replaces manual folds, so a reviewed file keeps
  no manual folds in windows that take a pane's options, including views saved
  by auto-view autocommands.
- While Compare shows a file again after `]b` or `[b`, a window in another tab
  that opens that file for the first time can start with the pane's diff mode
  and label. `o`, `<leader>ve`, and picker selections reset the window they
  open; other windows are not reset.
- When Compare takes a pane back from a picker preview, the preview's own diff
  ends in that pane. Its winbar and scroll and cursor bindings remain.

## Blame selected lines

Select lines, then run `:LazyVCS blame`. Vim supplies the selected range. This
also works in Compare's text panes. `q` closes the report. Unsaved edits are
marked uncommitted in editor buffers.

SVN blame maps working-copy BASE history onto saved and unsaved edits. New or
changed lines stay uncommitted after saving; unchanged lines keep their history.

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
are detected automatically. See `:help lazyvcs-configuration` for all options
and `:help lazyvcs-defaults` for the complete default configuration.

Commit messages use CopilotChat.nvim by default. Set
`ai.commit_message.provider` to `"claude"`, `"codex"`, `"gemini"`, or
`"copilot_cli"` for a CLI, to `"auto"` to try `provider_order`, or to `"off"` to
disable generation:

```lua
opts = { ai = { commit_message = { provider = "off" } } }
```

Diff panes use normal syntax colors, including code an LSP marks inactive. On
Neovim versions with `link_global`, a custom namespace stays active if any link
target resolves differently in that namespace and globally, including through
link chains. Semantic overlays remain visible in those windows because the API
cannot distinguish ordinary links from global-only links. Other custom
namespaces keep normal diff highlighting. Set `diff_highlighting = "editor"` to
keep LSP semantic colors in every comparison.

## Help and contribute

- `:help lazyvcs` covers commands, mappings, and configuration.
- [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, checks, architecture, and
  releases.
- [CHANGELOG.md](CHANGELOG.md) lists changes.
- [SECURITY.md](SECURITY.md) explains private security reporting.
