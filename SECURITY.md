# Security Policy

## Supported versions

Only the latest minor release receives security fixes.

| Version | Supported |
| ------- | --------- |
| 0.12.x  | Yes       |
| < 0.12  | No        |

## Reporting a vulnerability

Report vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/Reddimus/lazyvcs.nvim/security/advisories/new).
Please do not open a public issue for a suspected vulnerability.

Include the Neovim version, the plugin version or commit, the VCS in use (Git or
Subversion), and the smallest reproduction you can manage. You should get an
initial response within seven days.

## Scope

LazyVCS runs `git` and `svn` as subprocesses, reads and writes files in your
working copies, and can send diff content to a configured AI provider. The
following are in scope:

- Command injection through branch names, paths, remote URLs, or other
  repository-controlled strings reaching a subprocess argument list.
- Path traversal or writes outside the repository during buffer transfer, hunk
  revert, or diff-target resolution.
- Leaking repository contents to an AI provider when
  `ai.commit_message.provider` is disabled, or beyond what
  `ai.commit_message.context` selects.
- Exposure of diff content through process arguments, environment, log files, or
  task listings visible to other local users.
- Persisted state under `store.path()` being written outside its directory or
  with unsafe permissions.

The following are out of scope:

- Vulnerabilities in `git`, `svn`, Neovim, or third-party plugins. Report those
  upstream.
- Behavior requiring a hostile `init.lua`, since that already executes arbitrary
  code.
- Prompt-injection of a configured AI provider by repository content. Treat
  generated commit messages as untrusted text and review before committing.

## Git repository selection

LazyVCS always removes these variables from the environment of Git subprocesses:
`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
`GIT_COMMON_DIR`, `GIT_NAMESPACE`, `GIT_PREFIX`, `GIT_SHALLOW_FILE`,
`GIT_GRAFT_FILE`, and `GIT_IMPLICIT_WORK_TREE`. Alternate-index workflows are
not supported.

Inherited `GIT_DIR` and `GIT_WORK_TREE` are kept only when all of these hold:

- Both are set and not empty.
- The command's working directory is inside that work tree, compared after
  resolving symlinks and without case sensitivity on Windows.
- No directory from the working directory up to, but not including, the work
  tree root contains a `.git` file or directory.

Otherwise LazyVCS removes both, and Git finds the repository from the working
directory. A bare dotfiles repository therefore keeps working in its work tree,
while a separate repository nested inside that work tree uses its own `.git`.
The `.git` check is cached per directory for up to five seconds, and repository
redetection clears the cache.

Authentication and ordinary Git configuration remain inherited. LazyVCS does not
change Neovim's environment.

## Handling of repository content

Diffs passed to an AI provider are sent over stdin or a private,
deleted-on-completion attachment rather than as command-line arguments, so they
do not appear in process listings. Content is truncated to
`ai.commit_message.max_context_chars`. No telemetry is collected. LazyVCS opens
no network connections itself; network traffic comes only from the `git` and
`svn` commands it runs on your behalf (fetch, push, update, and remote status)
and from the AI provider you configure.
