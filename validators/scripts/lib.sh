#!/usr/bin/env bash
# shellcheck disable=SC2034  # the variables are for the scripts that source this file
# Shared helpers of the DiabloArb validator kit. Sourced by the other scripts; does nothing on its own.
# Reads process arguments and config files only. Never reads, prints or sends a private key.

KIT_VERSION="2026-11-13"
PUBLIC_RPC="https://api.mainnet-beta.solana.com"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed (Debian/Ubuntu: sudo apt install $c)"
  done
}

# The running processes as "PID ARGS…". Tests feed a file through DIABLOARB_PS_FILE.
procs() {
  if [ -n "${DIABLOARB_PS_FILE:-}" ]; then
    cat "$DIABLOARB_PS_FILE"
  else
    ps -eo pid=,args= 2>/dev/null
  fi
}

# The arguments of PID, one per line: from /proc (exact) or, failing that, from ps (split on spaces).
args_of() {
  local pid=$1
  if [ -z "${DIABLOARB_PS_FILE:-}" ] && [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' '\n' < "/proc/$pid/cmdline"
  else
    procs | awk -v p="$pid" '$1 == p { for (i = 2; i <= NF; i++) print $i }'
  fi
}

# Every value of a flag in an argument list on stdin: "--flag value", "--flag=value", repeated, comma-separated.
flag_values() {
  local flag=$1
  awk -v f="$flag" '
    take { print; take = 0; next }
    $0 == f { take = 1; next }
    index($0, f "=") == 1 { print substr($0, length(f) + 2) }
  ' | tr ',' '\n' | sed '/^$/d'
}

has_flag() {
  local flag=$1
  grep -q -x -e "$flag" -e "$flag=.*"
}

# PID of the first process whose program name matches the regex.
find_pid() {
  local re=$1
  procs | awk -v re="$re" '{ n = split($2, a, "/"); if (a[n] ~ re) { print $1; exit } }'
}

# The validator: sets VAL_PID, VAL_KIND (agave | firedancer), VAL_BIN and VAL_ARGS (one per line).
find_validator() {
  VAL_PID="" VAL_KIND="" VAL_BIN="" VAL_ARGS=""
  local pid line
  while read -r pid line; do
    local prog=${line%% *}
    prog=${prog##*/}
    case "$prog" in
      agave-validator|solana-validator)
        if printf '%s\n' "$line" | grep -q -e '--identity' -e '--vote-account' -e '--entrypoint'; then
          VAL_PID=$pid VAL_KIND=agave VAL_BIN=${line%% *}
          break
        fi ;;
      fdctl|firedancer|fddev)
        if printf '%s\n' "$line" | grep -q -w 'run'; then
          VAL_PID=$pid VAL_KIND=firedancer VAL_BIN=${line%% *}
          break
        fi ;;
    esac
  done < <(procs)
  [ -n "$VAL_PID" ] && VAL_ARGS=$(args_of "$VAL_PID")
  # the binary as the kernel knows it (the command line may name it relatively); not one replaced on disk since start
  if [ -n "$VAL_PID" ] && [ -z "${DIABLOARB_PS_FILE:-}" ] && [ -e "/proc/$VAL_PID/exe" ]; then
    local exe
    exe=$(readlink "/proc/$VAL_PID/exe" 2>/dev/null || true)
    case "$exe" in
      ""|*" (deleted)") ;;
      *) VAL_BIN=$exe ;;
    esac
  fi
  return 0
}

# The relayer: sets REL_PID and REL_ARGS.
find_relayer() {
  REL_PID=$(find_pid 'transaction-relayer|jito-relayer')
  REL_ARGS=""
  [ -n "$REL_PID" ] && REL_ARGS=$(args_of "$REL_PID")
  return 0
}

# A key of a TOML section, its value joined onto one line (multi-line arrays included).
toml_get() {
  local file=$1 section=$2 key=$3
  awk -v sec="[$section]" -v key="$key" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^[ \t]*\[/ { cur = trim($0); sub(/[ \t]*#.*$/, "", cur); next }
    cur != sec { next }
    collecting { line = $0; sub(/#.*$/, "", line); val = val " " trim(line); if (line ~ /\]/) { print val; exit } next }
    {
      line = $0; sub(/^[ \t]+/, "", line)
      if (index(line, key) != 1) next
      rest = trim(substr(line, length(key) + 1))
      if (substr(rest, 1, 1) != "=") next
      v = trim(substr(rest, 2)); sub(/[ \t]+#.*$/, "", v)
      if (v ~ /^\[/ && v !~ /\]/) { collecting = 1; val = v; next }
      print v; exit
    }
  ' "$file"
}

# The entries of a TOML string array on stdin, one per line.
toml_array_items() {
  tr -d '[]' | tr ',' '\n' | sed -e 's/^[ \t]*"//' -e 's/"[ \t]*$//' -e '/^[ \t]*$/d'
}

# Only the scheme and host of a URL: query strings and paths may carry tokens.
url_host() {
  printf '%s\n' "$1" | sed -E 's#^([a-z]+://)?([^/?]+).*#\1\2#'
}

rpc_call() {
  local url=$1 body=$2
  curl -s -m 30 --compressed -H 'content-type: application/json' -d "$body" "$url"
}
