#!/usr/bin/env bash
# Path B: give DiabloArb's sender identities stake-weighted priority on your own TPU, through a "staked nodes
# overrides" file. Keeps every entry already in the file. Dry run by default.
#
#   staked-overrides.sh --add PUBKEY=LAMPORTS [--add …] [--file PATH] [--ledger PATH] [--relayer] [--apply]
#   staked-overrides.sh --remove PUBKEY [--remove …] [--file PATH] [--ledger PATH] [--relayer] [--apply]
#
# Amounts are lamports (1 SOL = 1000000000). Only useful where users' transactions arrive at your own machine (Jito
# without BAM, Agave, Rakurai, or the relayer in front of them); under BAM and Harmonic it has no effect.
#
# --file     the overrides file (default: the one the validator or relayer already uses, else
#            /home/sol/staked-nodes-overrides.yml)
# --relayer  the file is the relayer's: written, not loaded (restart the relayer to load it)
# --apply    write the file (a backup is kept next to it) and load it into the running validator
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ADDS="" REMOVES="" FILE="" LEDGER="" RELAYER=0 APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --add) ADDS="$ADDS ${2:?}"; shift 2 ;;
    --remove) REMOVES="$REMOVES ${2:?}"; shift 2 ;;
    --file) FILE=${2:?}; shift 2 ;;
    --ledger) LEDGER=${2:?}; shift 2 ;;
    --relayer) RELAYER=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ADDS$REMOVES" ] || die "nothing to do: use --add PUBKEY=LAMPORTS or --remove PUBKEY"

is_pubkey() { printf '%s' "$1" | grep -Eq '^[1-9A-HJ-NP-Za-km-z]{32,44}$'; }
for a in $ADDS; do
  k=${a%%=*} v=${a#*=}
  is_pubkey "$k" || die "not a public key: $k"
  printf '%s' "$v" | grep -Eq '^[0-9]+$' || die "amount must be whole lamports: $a"
done
for k in $REMOVES; do is_pubkey "$k" || die "not a public key: $k"; done

find_validator
find_relayer
if [ "$RELAYER" = 1 ]; then
  [ -n "$FILE" ] || FILE=$(printf '%s\n' "$REL_ARGS" | flag_values --staked-nodes-overrides | head -n1)
else
  [ -n "$FILE" ] || FILE=$(printf '%s\n' "$VAL_ARGS" | flag_values --staked-nodes-overrides | head -n1)
fi
IN_USE=1
[ -n "$FILE" ] || { FILE=/home/sol/staked-nodes-overrides.yml; IN_USE=0; }

# the file as it is: only "staked_map_id:" and "  <pubkey>: <number>" lines (and comments) are understood
OLD=""
if [ -e "$FILE" ]; then
  OLD=$(cat "$FILE")
  strange=$(printf '%s\n' "$OLD" | grep -Ev '^[[:space:]]*(#.*)?$' | grep -Ev '^staked_map_id:[[:space:]]*$' | grep -Ev '^[[:space:]]+[1-9A-HJ-NP-Za-km-z]{32,44}:[[:space:]]*[0-9]+[[:space:]]*$' || true)
  [ -z "$strange" ] || die "$FILE has lines this script does not understand; edit it by hand:
$strange"
fi

NEW=$( {
  printf 'staked_map_id:\n'
  printf '%s\n' "$OLD" | grep -E '^[[:space:]]+[1-9A-HJ-NP-Za-km-z]{32,44}:' | sed -E 's/^[[:space:]]+//; s/:[[:space:]]*/ /' | while read -r k v; do
    drop=0
    for r in $REMOVES; do [ "$k" = "$r" ] && drop=1; done
    for a in $ADDS; do [ "$k" = "${a%%=*}" ] && drop=1; done
    [ "$drop" = 1 ] || printf '  %s: %s\n' "$k" "$v"
  done
  for a in $ADDS; do printf '  %s: %s\n' "${a%%=*}" "${a#*=}"; done
} )

say "file: $FILE$( [ "$IN_USE" = 1 ] && echo ' (already in use)' || echo ' (new)')"
say "--- now"
printf '%s\n' "${OLD:-(empty)}"
say "--- after"
printf '%s\n' "$NEW"

if [ "$APPLY" != 1 ]; then
  say ""
  say "dry run: nothing changed. Add --apply to write it."
  exit 0
fi

if [ -e "$FILE" ]; then
  cp -p "$FILE" "$FILE.bak-diabloarb-$(date +%Y%m%d-%H%M%S)"
fi
printf '%s\n' "$NEW" > "$FILE.tmp"
mv -f "$FILE.tmp" "$FILE"
say ""
say "written."

if [ "$RELAYER" = 1 ]; then
  say "Relayer: make sure it starts with --staked-nodes-overrides $FILE, then restart it."
  exit 0
fi
[ -n "$VAL_PID" ] || { say "no running validator: start it with --staked-nodes-overrides $FILE"; exit 0; }
[ "$VAL_KIND" = agave ] || { say "Firedancer: ask DiabloArb how to load overrides in your version"; exit 0; }
"$VAL_BIN" staked-nodes-overrides --help >/dev/null 2>&1 || die "$(basename "$VAL_BIN") has no staked-nodes-overrides command: restart it with --staked-nodes-overrides $FILE"
[ -n "$LEDGER" ] || LEDGER=$(printf '%s\n' "$VAL_ARGS" | flag_values --ledger | head -n1)
[ -n "$LEDGER" ] || LEDGER=$(printf '%s\n' "$VAL_ARGS" | flag_values -l | head -n1)
[ -n "$LEDGER" ] || die "ledger path unknown: pass --ledger PATH"
"$VAL_BIN" -l "$LEDGER" staked-nodes-overrides "$FILE"
say "loaded into the running validator."
[ "$IN_USE" = 1 ] || say "Add to your start script so that it survives a restart:  --staked-nodes-overrides $FILE"
say "Undo: $0 --file $FILE$(for a in $ADDS; do printf ' --remove %s' "${a%%=*}"; done) --apply"
