# Agent instructions

## Code Review Rules

- Follow `.github/review-policy.md`.

## Terminal testing

- When `kettle` ([Reddimus/kettle](https://github.com/Reddimus/kettle)) is
  installed and a display is available, run interactive checks of the sidebar,
  Compare, and blame in Kettle. Launch it with `--agent-server full` and drive
  Neovim with `kettle ctl` (`run_command`, `send_keys`, `wait_for`,
  `read_screen`, `screenshot`); `kettle ctl schema` lists the parameters.
  Without Kettle, use the checks in
  [CONTRIBUTING.md](CONTRIBUTING.md#running-the-checks).
- When something looks wrong in Kettle, repeat the same steps in another
  terminal. If it happens only in Kettle, open an issue in Reddimus/kettle with
  its bug report template (`kettle --version`, OS, minimal steps, expected and
  actual output, a screenshot) instead of working around it in lazyvcs. Fix
  problems that also happen elsewhere here.
