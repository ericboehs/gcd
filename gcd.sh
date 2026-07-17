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
_gcd_disp() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# ---- default host (URL host > cwd-derived > GCD_HOST > GH_HOST > github.com)
_gcd_default_host() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L sh
  local root=${GCD_ROOT:-$HOME/Code} cwd=$PWD relc h
  case "$cwd" in
    "$root"/*)
      relc=${cwd#"$root"/}
      h=${relc%%/*}
      case "$h" in *.*) printf '%s' "$h"; return 0 ;; esac
      ;;
  esac
  printf '%s' "${GCD_HOST:-${GH_HOST:-github.com}}"
}

# ---- parse one argument into 8 newline-separated fields --------------------
# host / org / repo / kind / ref / path / line / num
_gcd_resolve() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L sh
  local input=$1 root frag base line first host org repo sub kind ref subpath num

  root=${GCD_ROOT:-$HOME/Code}

  # fragment (#L42 / #L42-L50) -> line
  case "$input" in
    *\#*) frag=${input##*#}; base=${input%%#*} ;;
    *)    frag="";           base=$input ;;
  esac
  line=""
  case "$frag" in L[0-9]*) line=${frag#L}; line=${line%%-*} ;; esac

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

  printf '%s\n' "$host" "$org" "$repo" "$kind" "$ref" "$subpath" "$line" "$num"
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
  GH_HOST="$host" gh pr checkout "$n"
}

# ---- open in editor --------------------------------------------------------
_gcd_open() {
  local ed=${EDITOR:-vi} f
  case "$kind" in
    pull)   "$ed" "octo://$host/$org/$repo/pull/$num" ;;
    issues) "$ed" "octo://$host/$org/$repo/issues/$num" ;;
    blob)   f=${_GCD_FILE:-$subpath}
            if [ -n "$line" ]; then "$ed" "+$line" -- "$f"; else "$ed" -- "$f"; fi ;;
    *)      "$ed" . ;;
  esac
}

# ---- emit the open command (used by the gvi clipboard widget) --------------
_gcd_emit() {
  local ed=${EDITOR:-vi} d
  d=$(_gcd_disp "$dir")
  case "$kind" in
    pull)   printf 'gcd %s && %s octo://%s/%s/%s/pull/%s\n'   "$d" "$ed" "$host" "$org" "$repo" "$num" ;;
    issues) printf 'gcd %s && %s octo://%s/%s/%s/issues/%s\n' "$d" "$ed" "$host" "$org" "$repo" "$num" ;;
    blob)   if [ -n "$line" ]; then printf 'gcd %s && %s +%s %s\n' "$d" "$ed" "$line" "$subpath"
            else printf 'gcd %s && %s %s\n' "$d" "$ed" "$subpath"; fi ;;
    *)      printf 'gcd %s && %s .\n' "$d" "$ed" ;;
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

  [ "$#" -eq 0 ] && { _gcd_help; return 2; }

  local root=${GCD_ROOT:-$HOME/Code}
  local host org repo kind ref subpath line num _GCD_FILE=""
  { IFS= read -r host; IFS= read -r org; IFS= read -r repo; IFS= read -r kind
    IFS= read -r ref;  IFS= read -r subpath; IFS= read -r line; IFS= read -r num
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
    return 0
  fi

  [ "$do_print" = 1 ] && { _gcd_emit; return 0; }

  if [ ! -e "$dir/.git" ]; then
    _gcd_clone || return 1
  fi
  cd "$dir" || return 1

  case "$kind" in
    pull)              _gcd_pr_checkout "$num" ;;
    issues)            : ;;
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
