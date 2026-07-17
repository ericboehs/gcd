# shellcheck shell=bash
# gcd — cd to (and clone/checkout) a repo from a URL.
#
#   gcd <url|host/org/repo|org/repo|local-path>
#   gvi <same>     # gcd, then open the file/line (or PR/issue) in $EDITOR
#
# Source this file from your shell rc (bash or zsh):
#   source /path/to/gcd/gcd.sh
#
# Config (env vars):
#   GCD_ROOT    base of your checkout tree      (default: ~/Code)
#   GCD_HOST    default host for bare names      (default: $GH_HOST, else github.com)
#   GCD_CLONE   clone backend: gh | git          (default: gh, falls back to git)
#   GCD_DIRTY   when tree is dirty and a ref is
#               requested: warn | worktree | stash   (default: warn)
#
# Layout: repos live at  $GCD_ROOT/<host>/<org>/<repo>
# Worktrees (GCD_DIRTY=worktree) live at  <repo>/.worktrees/<ref>

# ---- clipboard -------------------------------------------------------------
_gcd_clip() {
  if command -v pbpaste >/dev/null 2>&1; then pbpaste
  elif command -v wl-paste >/dev/null 2>&1; then wl-paste 2>/dev/null
  elif command -v xclip >/dev/null 2>&1; then xclip -o -selection clipboard 2>/dev/null
  fi
}

# ---- display helper: /Users/me/... -> ~/... --------------------------------
_gcd_disp() { local h=${HOME%/}; case "$1" in "$h"/*) printf '~%s' "${1#"$h"}" ;; *) printf '%s' "$1" ;; esac; }

# ---- sha256 of stdin -> bare hex (GitHub diff anchors hash the file path) ---
_gcd_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  fi
}

# ---- default host (URL host > cwd-derived > GCD_HOST > GH_HOST > github.com)
_gcd_default_host() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L sh
  # $HOME can carry a trailing slash on some systems; normalize so the $root
  # prefix match against $PWD (always single-slash) doesn't silently miss.
  local root=${GCD_ROOT:-${HOME%/}/Code} cwd=$PWD relc h
  root=${root%/}
  case "$cwd" in
    "$root"/*)
      relc=${cwd#"$root"/}
      h=${relc%%/*}
      case "$h" in *.*) printf '%s' "$h"; return 0 ;; esac
      ;;
  esac
  printf '%s' "${GCD_HOST:-${GH_HOST:-github.com}}"
}

# ---- parse one argument into 10 newline-separated fields -------------------
# host / org / repo / kind / ref / path / line / num / diffhash / side
_gcd_resolve() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L sh
  local input=$1 root frag base line first host org repo sub kind ref subpath num
  local diffhash="" side="" sidepart linepart

  root=${GCD_ROOT:-${HOME%/}/Code}; root=${root%/}

  # fragment (#L42 / #L42-L50 / #diff-<sha256>R28 / #diff-<sha256>L28) -> line
  case "$input" in
    *\#*) frag=${input##*#}; base=${input%%#*} ;;
    *)    frag="";           base=$input ;;
  esac
  line=""
  case "$frag" in
    diff-*)
      # GitHub diff anchor: diff-<sha256(path)><L|R><line>[-<L|R><line>]
      # hash is lowercase hex; the side marker is the first upper-case L/R.
      sidepart=${frag#diff-}
      diffhash=${sidepart%%[LR]*}          # hex before first L/R
      sidepart=${sidepart#"$diffhash"}     # e.g. "R28-R30"
      side=${sidepart%%[0-9]*}             # "R" (chars before first digit)
      linepart=${sidepart#"$side"}         # "28-R30"
      line=${linepart%%[!0-9]*}            # "28"
      ;;
    L[0-9]*) line=${frag#L}; line=${line%%-*} ;;
  esac

  # strip protocol, query, scp-ish prefix, trailing slash / .git
  base=${base#https://}; base=${base#http://}; base=${base#git://}; base=${base#ssh://}
  base=${base#git@}
  # scp form "host:org/repo" -> "host/org/repo" (colon before first slash)
  case "$base" in
    *:*) case "${base%%:*}" in */*) : ;; *) base="${base%%:*}/${base#*:}" ;; esac ;;
  esac
  base=${base%%\?*}
  base=${base%/}
  base=${base%.git}

  # local path under $GCD_ROOT -> host/org/repo...
  case "$base" in "~/"*) base=$HOME/${base#\~/} ;; esac
  case "$base" in "$root"/*) base=${base#"$root"/} ;; esac

  # split on '/'
  local IFS=/
  set -- $base
  unset IFS

  first=$1
  case "$first" in
    *.*) host=$first; shift ;;
    *)   host=$(_gcd_default_host) ;;
  esac
  org=$1; repo=$2
  [ "$#" -ge 2 ] && shift 2 || set --
  repo=${repo%.git}

  kind=repo; ref=""; subpath=""; num=""
  if [ "$#" -gt 0 ]; then
    sub=$1; shift
    case "$sub" in
      tree)         kind=tree;   IFS=/; ref="$*"; unset IFS ;;
      blob)         kind=blob;   ref=$1; [ "$#" -ge 1 ] && shift; IFS=/; subpath="$*"; unset IFS ;;
      commit)       kind=commit; ref=$1 ;;
      pull)         kind=pull;   num=$1 ;;
      issues|issue) kind=issues; num=$1 ;;
      *)            kind=repo ;;
    esac
  fi

  printf '%s\n' "$host" "$org" "$repo" "$kind" "$ref" "$subpath" "$line" "$num" "$diffhash" "$side"
}

# ---- clone -----------------------------------------------------------------
_gcd_clone() {
  mkdir -p "${dir%/*}" || return 1
  if [ "${GCD_CLONE:-gh}" = gh ] && command -v gh >/dev/null 2>&1; then
    GH_HOST="$host" gh repo clone "$org/$repo" "$dir"
  else
    git clone "https://$host/$org/$repo.git" "$dir"
  fi
}

# ---- dirty-tree policy -----------------------------------------------------
_gcd_dirty() {
  local want=$1 tail=$2 policy=${GCD_DIRTY:-warn} wt
  case "$policy" in
    worktree)
      wt="$dir/.worktrees/$(printf '%s' "$want" | tr '/' '-')"
      if [ ! -d "$wt" ]; then
        git worktree add "$wt" "$want" >/dev/null 2>&1 \
          || { git fetch --quiet 2>/dev/null; git worktree add "$wt" "$want" >/dev/null 2>&1; } \
          || { printf 'gcd: could not create worktree for %s\n' "$want" >&2; return 1; }
      fi
      cd "$wt" || return 1
      _GCD_FILE=$tail
      printf 'gcd: dirty tree; using worktree %s\n' "$(_gcd_disp "$wt")" >&2
      ;;
    stash)
      git stash push -u -m "gcd: auto-stash before $want" >/dev/null 2>&1
      git checkout "$want" >/dev/null 2>&1
      _GCD_FILE=$tail
      printf 'gcd: stashed changes; restore with: git stash pop\n' >&2
      ;;
    *)
      printf 'gcd: working tree dirty; staying put (wanted %s)\n' "$want" >&2
      _GCD_FILE=$tail
      ;;
  esac
}

# ---- default branch of origin (e.g. main / master) -------------------------
_gcd_default_branch() {
  local d
  d=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -z "$d" ]; then
    git remote set-head origin --auto >/dev/null 2>&1
    d=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  fi
  printf '%s' "${d#origin/}"
}

# ---- no ref in the URL: land on the default branch if the tree is clean -----
_gcd_default_checkout() {
  [ -n "$(git status --porcelain 2>/dev/null)" ] && return 0   # dirty: stay put, quietly
  local def cur
  def=$(_gcd_default_branch)
  cur=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
  [ -n "$def" ] && [ "$def" != "$cur" ] || return 0
  if git checkout "$def" >/dev/null 2>&1; then
    printf 'gcd: checked out default branch %s\n' "$def" >&2
  fi
}

# ---- checkout with lazy slashed-branch ref-walk ----------------------------
_gcd_checkout() {
  local want=$1 tail=$2 cur cand rest seg
  cur=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
  [ "$cur" = "$want" ] && { _GCD_FILE=$tail; return 0; }

  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    _gcd_dirty "$want" "$tail"; return $?
  fi

  # simple case first
  if git checkout "$want" >/dev/null 2>&1; then _GCD_FILE=$tail; return 0; fi

  # branch name may contain slashes that the naive parse put into the path
  cand=$want; rest=$tail
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    cand="$cand/$seg"
    case "$rest" in */*) rest=${rest#*/} ;; *) rest="" ;; esac
    if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1 \
       || git rev-parse --verify --quiet "origin/$cand" >/dev/null 2>&1; then
      if git checkout "$cand" >/dev/null 2>&1; then _GCD_FILE=$rest; return 0; fi
    fi
  done

  # stale clone? fetch and retry original
  git fetch --quiet 2>/dev/null
  if git checkout "$want" >/dev/null 2>&1; then _GCD_FILE=$tail; return 0; fi

  printf 'gcd: could not resolve ref %s (staying on %s)\n' "$want" "${cur:-detached HEAD}" >&2
  _GCD_FILE=$tail
  return 1
}

# ---- PR checkout -----------------------------------------------------------
_gcd_pr_checkout() {
  local n=$1
  command -v gh >/dev/null 2>&1 || { printf 'gcd: gh required for PR checkout\n' >&2; return 1; }
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    if [ "${GCD_DIRTY:-warn}" = warn ]; then
      printf 'gcd: dirty tree; not checking out PR #%s\n' "$n" >&2; return 0
    fi
    git stash push -u -m "gcd: auto-stash before PR $n" >/dev/null 2>&1 \
      && printf 'gcd: stashed changes; restore with: git stash pop\n' >&2
  fi
  # Pass the full URL so gh resolves the exact repo from the link, not an
  # ambiguous default remote (e.g. a fork alongside origin).
  GH_HOST="$host" gh pr checkout "https://$host/$org/$repo/pull/$n"
}

# ---- resolve a diff anchor's file via gh -----------------------------------
# GitHub hashes the *file path* into the anchor, so reverse it by hashing each
# changed path and matching. Uses gh (remote API) — no local checkout needed.
_gcd_diff_file() {
  command -v gh >/dev/null 2>&1 || return 1
  local api filter f h
  case "$kind" in
    pull)   api="repos/$org/$repo/pulls/$num/files"; filter='.[].filename' ;;
    commit) api="repos/$org/$repo/commits/$ref";     filter='.files[].filename' ;;
    *)      return 1 ;;
  esac
  GH_HOST="$host" gh api --paginate "$api" --jq "$filter" 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] || continue
    h=$(printf '%s' "$f" | _gcd_sha256)
    if [ "$h" = "$diffhash" ]; then printf '%s\n' "$f"; break; fi
  done
}

# ---- open in editor --------------------------------------------------------
_gcd_open() {
  local ed=${EDITOR:-vi} f
  if [ -n "$diffhash" ]; then
    f=$(_gcd_diff_file)
    if [ -n "$f" ]; then
      [ "$side" = L ] && printf 'gcd: %s#L%s is a base-side (L) line; opening the checked-out version\n' "$f" "$line" >&2
      if [ -n "$line" ]; then "$ed" "+$line" -- "$f"; else "$ed" -- "$f"; fi
    else
      printf 'gcd: could not resolve diff file for %s (opening editor)\n' "$diffhash" >&2
      "$ed"
    fi
    return
  fi
  case "$kind" in
    pull)   "$ed" "octo://$host/$org/$repo/pull/$num" ;;
    issues) "$ed" "octo://$host/$org/$repo/issues/$num" ;;
    blob)   f=${_GCD_FILE:-$subpath}
            if [ -n "$line" ]; then "$ed" "+$line" -- "$f"; else "$ed" -- "$f"; fi ;;
    *)      "$ed" ;;   # repo root, no file: open the editor without a dir arg (no explorer)
  esac
}

# ---- emit the open command (used by the gvi clipboard widget) --------------
_gcd_emit() {
  local ed=${EDITOR:-vi} d
  # Diff anchors need a gh lookup (and a PR/commit checkout) to resolve the
  # file — too heavy for a keypress-time expansion, so emit a runnable gvi that
  # does the real work when you press enter.
  if [ -n "$diffhash" ]; then printf 'gvi %s\n' "$url"; return 0; fi
  d=$(_gcd_disp "$dir")
  case "$kind" in
    pull)   printf 'gcd %s && %s octo://%s/%s/%s/pull/%s\n'   "$d" "$ed" "$host" "$org" "$repo" "$num" ;;
    issues) printf 'gcd %s && %s octo://%s/%s/%s/issues/%s\n' "$d" "$ed" "$host" "$org" "$repo" "$num" ;;
    blob)   if [ -n "$line" ]; then printf 'gcd %s && %s +%s %s\n' "$d" "$ed" "$line" "$subpath"
            else printf 'gcd %s && %s %s\n' "$d" "$ed" "$subpath"; fi ;;
    *)      printf 'gcd %s && %s\n' "$d" "$ed" ;;
  esac
}

# ---- prune this repo's worktrees ------------------------------------------
_gcd_prune() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { printf 'gcd: not in a git repo\n' >&2; return 1; }
  if [ -d "$top/.worktrees" ]; then
    local wt
    for wt in "$top"/.worktrees/*; do
      [ -d "$wt" ] || continue
      git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    done
    git worktree prune >/dev/null 2>&1
    printf 'gcd: pruned worktrees under %s/.worktrees\n' "$(_gcd_disp "$top")"
  else
    printf 'gcd: no worktrees to prune\n'
  fi
}

_gcd_help() {
  cat >&2 <<'EOF'
gcd — cd to (clone/checkout as needed) a repo from a URL

  gcd <url|host/org/repo|org/repo|local-path>   cd there
  gcd --dry-run <arg>                           show what would happen
  gcd --print   <arg>                           print the open command (for scripts/widgets)
  gcd --prune                                   remove this repo's .worktrees/*
  gvi <arg>                                     gcd, then open file/line (or PR/issue) in $EDITOR
  gvi                                           same, using the URL on your clipboard

Env: GCD_ROOT GCD_HOST GCD_CLONE(gh|git) GCD_DIRTY(warn|worktree|stash)
EOF
}

# ---- main ------------------------------------------------------------------
gcd() {
  local do_print=0 do_open=0 dry=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print)   do_print=1 ;;
      --open)    do_open=1 ;;
      --dry-run) dry=1 ;;
      --prune)   shift; _gcd_prune "$@"; return ;;
      -h|--help) _gcd_help; return ;;
      --)        shift; break ;;
      -*)        printf 'gcd: unknown option %s\n' "$1" >&2; return 2 ;;
      *)         break ;;
    esac
    shift
  done

  # no argument: fall back to a URL/repo ref on the clipboard, else show help
  if [ "$#" -eq 0 ]; then
    local clip; clip=$(_gcd_clip)
    case "$clip" in
      *://*|*/*) set -- "$clip" ;;
      *)         _gcd_help; return 2 ;;
    esac
  fi

  local root=${GCD_ROOT:-${HOME%/}/Code} url=$1; root=${root%/}
  local host org repo kind ref subpath line num diffhash side _GCD_FILE=""
  { IFS= read -r host; IFS= read -r org; IFS= read -r repo; IFS= read -r kind
    IFS= read -r ref;  IFS= read -r subpath; IFS= read -r line; IFS= read -r num
    IFS= read -r diffhash; IFS= read -r side
  } <<EOF
$(_gcd_resolve "$1")
EOF

  if [ -z "$host" ] || [ -z "$org" ] || [ -z "$repo" ]; then
    printf 'gcd: could not parse "%s"\n' "$1" >&2; return 2
  fi

  local dir="$root/$host/$org/$repo"

  if [ "$dry" = 1 ]; then
    printf 'dir : %s\nrepo: %s/%s/%s\nkind: %s  ref: %s  path: %s  line: %s  num: %s\n' \
      "$(_gcd_disp "$dir")" "$host" "$org" "$repo" "$kind" "${ref:-–}" "${subpath:-–}" "${line:-–}" "${num:-–}"
    [ -n "$diffhash" ] && printf 'diff: %s  side: %s\n' "$diffhash" "${side:-–}"
    return 0
  fi

  [ "$do_print" = 1 ] && { _gcd_emit; return 0; }

  if [ ! -e "$dir/.git" ]; then
    _gcd_clone || return 1
  fi
  cd "$dir" || return 1

  case "$kind" in
    pull)
      # gvi <pull> is view-only (octo), but a diff line means "take me to that
      # code", so check out the PR head first so the file exists at that version.
      if [ "$do_open" = 1 ]; then
        [ -n "$diffhash" ] && _gcd_pr_checkout "$num"
      else
        _gcd_pr_checkout "$num"
      fi
      ;;
    issues)            : ;;
    repo)              _gcd_default_checkout ;;
    tree|blob|commit)  [ -n "$ref" ] && _gcd_checkout "$ref" "$subpath" ;;
  esac

  [ "$do_open" = 1 ] && _gcd_open
  return 0
}

# ---- gvi: gcd + open -------------------------------------------------------
gvi() {
  if [ "$#" -eq 0 ]; then
    local clip; clip=$(_gcd_clip)
    [ -n "$clip" ] || { printf 'gvi: no argument and clipboard is empty\n' >&2; return 2; }
    set -- "$clip"
  fi
  gcd --open "$@"
}
