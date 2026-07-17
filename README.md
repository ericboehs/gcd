# gcd

`cd` to a repo from its URL. If you don't have it, `gcd` clones it first. Paste a
link that points at a branch, commit, or file — `gcd` checks out the ref (when
your tree is clean) and `gvi` opens the file at the right line.

Everything lives under one predictable tree:

```
$GCD_ROOT/<host>/<org>/<repo>
```

so `https://github.com/foo/bar` → `~/Code/github.com/foo/bar`.

## Install

`gcd` changes your shell's working directory, so it must be **sourced**, not run
as a script. Clone this repo and source `gcd.sh` from your `~/.bashrc` or
`~/.zshrc`:

```sh
git clone https://github.com/ericboehs/gcd ~/path/to/gcd
echo 'source ~/path/to/gcd/gcd.sh' >> ~/.zshrc   # or ~/.bashrc
```

Requires `git`. Cloning uses [`gh`](https://cli.github.com/) when available
(so private repos and GitHub Enterprise "just work"), falling back to
`git clone` over HTTPS.

## Usage

```sh
gcd https://github.com/foo/bar               # clone if needed, cd, land on default branch
gcd github.com/foo/bar                       # host/org/repo
gcd foo/bar                                  # bare org/repo (uses default host)
gcd https://github.com/foo/bar/tree/topic    # cd + checkout branch "topic"
gcd https://github.com/foo/bar/commit/<sha>  # cd + checkout commit (detached)
gcd https://github.com/foo/bar/pull/123      # cd + `gh pr checkout 123` (switch to the PR branch)

gvi https://github.com/foo/bar/blob/main/app/x.rb#L42   # gcd, then `nvim +42 app/x.rb`
gvi https://github.com/foo/bar/pull/123                 # opens octo://…/pull/123 (view only, no checkout)
gvi https://github.com/foo/bar/pull/123/files#diff-<h>R28  # checkout PR head, open that file at line 28
gvi https://github.com/foo/bar/issues/5                 # opens octo://…/issues/5
gvi                                                     # same, from the URL on your clipboard

gcd --dry-run <arg>   # show how an argument resolves, do nothing
gcd --print   <arg>   # print the "gcd … && $EDITOR …" open command (for scripts)
gcd --prune           # remove the current repo's ./.worktrees/*
```

Input can be a full URL (with or without protocol), `host/org/repo`,
bare `org/repo`, an `scp`-style `git@host:org/repo`, or a local path already
under `$GCD_ROOT` (which reverse-maps back to its remote, so it still clones if
missing).

### Which ref you land on

- URL with a ref (`/tree/<branch>`, `/blob/<branch>/…`, `/commit/<sha>`) → that ref, when the tree is clean (otherwise `GCD_DIRTY` decides).
- URL with **no** ref (a plain repo link, `host/org/repo`, or bare `org/repo`) → the repo's **default branch** (origin's HEAD), but only when the tree is clean and you aren't already on it. If the tree is dirty, `gcd` just cd's and leaves your branch alone.

### Diff links with a selected line

A GitHub diff link points at a file by *hashing its path* into the anchor
(`#diff-<sha256(path)><L|R><line>`), so there's no filename in the URL. `gvi`
resolves it by asking `gh` for the changed files and matching the hash:

- `.../pull/<n>/files#diff-<hash>R28` → check out the PR head, open that file at line 28 (**R** = the new/right side, so the line numbers match the checked-out file).
- `.../pull/<n>/files#diff-<hash>L40` → **L** is the base/left side; `gvi` still opens the file at that line on the checked-out head and prints a note that the line is base-relative.
- `.../commit/<sha>#diff-<hash>R7` → check out the commit (detached) and open the file at line 7.

This path needs [`gh`](https://cli.github.com/) (it's a remote lookup). `gcd`
(without `gvi`) on a diff link just checks out the PR/commit — the file/line
only matters when there's an editor to open.

### Branch names with slashes

A URL like `.../blob/feature/nested/app/x.rb` is ambiguous — is the branch
`feature` or `feature/nested`? `gcd` tries the simple checkout first and, only if
that fails, walks the path segments against your refs (locally, then after a
`git fetch`) to find the longest one that's a real branch. The leftover becomes
the file path.

## Configuration

All configuration is via environment variables:

| Variable    | Default                          | Meaning                                                        |
|-------------|----------------------------------|----------------------------------------------------------------|
| `GCD_ROOT`  | `~/Code`                         | Base of your checkout tree.                                    |
| `GCD_HOST`  | `$GH_HOST`, else `github.com`    | Default host for bare `org/repo` names.                       |
| `GCD_CLONE` | `gh`                             | Clone backend: `gh` (falls back to `git`) or `git`.           |
| `GCD_DIRTY` | `warn`                           | When the tree is dirty and a ref is requested (see below).    |

**Host precedence** for bare names: an explicit host in the URL wins; otherwise
if you're already inside `$GCD_ROOT/<host>/…` that host is used; otherwise
`GCD_HOST` → `GH_HOST` → `github.com`. So `gcd foo/bar` run from inside
`~/Code/va.ghe.com/…` resolves to `va.ghe.com/foo/bar`.

**Dirty-tree policy** (`GCD_DIRTY`), used when a URL asks for a ref your current
checkout isn't on and you have uncommitted changes:

- `warn` — stay on the current branch and print a warning (default; never touches your work).
- `worktree` — check the ref out in `./.worktrees/<ref>` and `cd` there. The worktree is reused across invocations; run `gcd --prune` to remove them. Add `.worktrees/` to your global gitignore so it stays invisible.
- `stash` — `git stash -u`, check out the ref, and remind you to `git stash pop`.

## Clipboard & pasting URLs

`gcd` and `gvi` with no arguments fall back to the clipboard, so the fast path
is: copy a GitHub link, type `gcd⏎` (or `gvi⏎`). `gcd` only does this when the
clipboard looks like a URL/repo ref (contains `/`), otherwise it prints help;
`gvi` always tries the clipboard.

If you pass the URL instead, quote it — the `#` in a `#L42` / `#diff-…` fragment
is special to the shell (a glob operator under zsh `extendedglob`), so an
unquoted paste fails to run (`no matches found`) rather than doing what you
meant. In zsh you can make `gcd␣` / `gvi␣` expand to `cmd "|"` (cursor between
the quotes) with a one-liner in your magic-abbrev/space widget:

```zsh
[[ $MATCH == (gcd|gvi) && -z $command ]] && (( $+functions[$MATCH] )) && command="$MATCH \"__CURSOR__\""
```

See `abbreviations.zsh` in
[ericboehs/dotfiles](https://github.com/ericboehs/dotfiles) for the surrounding
widget.

Opening PRs/issues uses [octo.nvim](https://github.com/pwntester/octo.nvim)
buffers (`octo://<host>/<org>/<repo>/pull/<n>`).

## License

MIT
