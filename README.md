# lazyvcs.nvim

`lazyvcs.nvim` is a Neovim plugin for opening an editable live diff view with a
real file buffer on one side and a VCS base scratch buffer on the other.

It is designed for a lazy.nvim and AstroNvim workflow:

- Git first, using `git show :path` for the base and optional `gitsigns.nvim`
  integration for hunk reset
- SVN support through a plugin-owned backend using `svn cat -r BASE`
- native splits, native diff mode, and debounced `:diffupdate`

## Controls and Usage

1. Restart Neovim if AstroNvim was already open before this plugin spec was added.
2. Open a versioned file that has local changes.
   For Git, any modified tracked file works.
   For SVN, open a file inside a working copy such as `~/Repos/SPI-1/platform/projects/...`.
3. Open the live diff view with one of:
   `:LazyVcsDiffOpen`
   `:VcsLiveDiffOpen`
   `<leader>vo`
4. Use the view:
   The left window is the real editable buffer.
   The right window is a scratch buffer showing the VCS base/original content.
   The diff updates as you edit, with a small debounce.
5. Revert the current hunk with:
   `:LazyVcsRevertHunk`
   `<leader>vr`
6. Move between hunks with:
   `:LazyVcsNextHunk`
   `:LazyVcsPrevHunk`
   `]v`
   `[v`
7. Refresh manually if needed with:
   `:LazyVcsDiffRefresh`
8. Close the session with:
   `:LazyVcsDiffClose`
   `<leader>vq`
   `q` inside the live diff session

### Useful checks

- Run `:checkhealth lazyvcs` to verify Neovim version and Git/SVN/gitsigns availability.
- Run `:echo exists(':LazyVcsDiffOpen')` to confirm the command is available. A result of `2` means it is defined.

### Behavior notes

- Git compares against the index.
- SVN compares against working-copy `BASE`.
- If a file is untracked, the right side may be empty because there is no VCS base yet.
- If you revert the wrong hunk, use normal Neovim undo with `u`. Redo with `Ctrl-r`.

## Commands

- `:LazyVcsDiffOpen`
- `:LazyVcsDiffClose`
- `:LazyVcsDiffToggle`
- `:LazyVcsDiffRefresh`
- `:LazyVcsRevertHunk`
- `:LazyVcsNextHunk`
- `:LazyVcsPrevHunk`
- `:VcsLiveDiffOpen`

## Default AstroNvim Mappings

- `<leader>vo` open live diff
- `<leader>vq` close live diff
- `<leader>vr` revert current hunk
- `]v` next hunk
- `[v` previous hunk

## Setup

### Generic lazy.nvim setup

Use a normal plugin spec if you are installing from a repository:

```lua
{
  "yourname/lazyvcs.nvim",
  dependencies = {
    "lewis6991/gitsigns.nvim",
  },
  cmd = {
    "LazyVcsDiffOpen",
    "LazyVcsDiffClose",
    "LazyVcsDiffToggle",
    "LazyVcsDiffRefresh",
    "LazyVcsRevertHunk",
    "LazyVcsNextHunk",
    "LazyVcsPrevHunk",
    "VcsLiveDiffOpen",
  },
  opts = {
    debounce_ms = 120,
    use_gitsigns = true,
    set_winbar = true,
    session_keymaps = true,
    base_window = {
      width = 0.45, -- ratio when <= 1, fixed columns when > 1
    },
  },
}
```

### Local development setup with AstroNvim

```lua
{
  dir = "/home/kevim/Repos/lazyvcs.nvim",
  name = "lazyvcs.nvim",
  main = "lazyvcs",
  dependencies = {
    "lewis6991/gitsigns.nvim",
  },
  cmd = {
    "LazyVcsDiffOpen",
    "LazyVcsDiffClose",
    "LazyVcsDiffToggle",
    "LazyVcsDiffRefresh",
    "LazyVcsRevertHunk",
    "LazyVcsNextHunk",
    "LazyVcsPrevHunk",
    "VcsLiveDiffOpen",
  },
  opts = {
    debounce_ms = 120,
    use_gitsigns = true,
    base_window = {
      width = 0.45, -- ratio when <= 1, fixed columns when > 1
    },
  },
}
```

After adding the plugin spec, restart Neovim or reload your lazy.nvim setup before using the commands.

## Health

Run `:checkhealth lazyvcs` to verify Neovim version and Git/SVN/gitsigns availability.

## Tests

Run the headless test suite with:

```sh
nvim --headless -u NONE -l /home/kevim/Repos/lazyvcs.nvim/tests/run.lua
```

Format and lint with locally available tools:

```sh
/home/kevim/.local/share/nvim/mason/bin/stylua /home/kevim/Repos/lazyvcs.nvim
/home/kevim/.local/share/nvim/mason/bin/lua-language-server --check=/home/kevim/Repos/lazyvcs.nvim --check_format=pretty --checklevel=Warning
```
