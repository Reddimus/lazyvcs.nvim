## What and why

<!-- What changes, and what problem it solves. -->

## Verification

<!-- How you know it works. Paste the suite summary. -->

- [ ] `stylua --check lua tests`
- [ ] `nvim --headless -u NONE -l tests/run.lua`
- [ ] `nvim --headless -u NONE -l tests/native_smoke.lua`
- [ ] Ran against a real Git working copy
- [ ] Ran against a real SVN working copy (or: no SVN available, specs skipped)

## Invariants

See CONTRIBUTING.md. Confirm the change does not violate these:

- [ ] No synchronous VCS call on a navigation, autocmd, or keystroke path
- [ ] No error can escape a `vim.schedule` or autocmd callback
- [ ] VCS access goes through `lazyvcs.backends`, not a concrete backend
- [ ] Paths normalized with `vim.fs.normalize`
- [ ] Highlights link to standard groups; no hardcoded colors
