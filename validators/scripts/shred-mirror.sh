#!/usr/bin/env bash
# Path A: add (or remove) DiabloArb's receiver to the addresses your validator mirrors its own leader shreds to,
# keeping every address already there. Dry run by default: prints what it would do.
#
#   shred-mirror.sh --add HOST:PORT    [--existing LIST] [--ledger PATH] [--apply]
#   shred-mirror.sh --remove HOST:PORT [--existing LIST] [--ledger PATH] [--apply]
#
# Agave based clients (jito-solana, BAM, Harmonic Salsa): applied at run time with set-shred-receiver-address, no
# restart; you also need to put the printed flag into your start script.
# Firedancer based clients (Firedancer, FireBAM, Harmonic Samba): prints the config.toml line; restart needed.
#
# --existing  the receiver list as it is now, comma-separated, if it was changed at run time since the validator
#             started (the script otherwise reads it from the validator's command line)
# --ledger    the ledger path (default: from the validator's command line)
# --apply     do it (Agave based clients only)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ACTION="" ADDR="" EXISTING="" EXISTING_SET=0 LEDGER="" APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --add) ACTION=add; ADDR=${2:?}; shift 2 ;;
    --remove) ACTION=remove; ADDR=${2:?}; shift 2 ;;
    --existing) EXISTING=${2-}; EXISTING_SET=1; shift 2 ;;
    --ledger) LEDGER=${2:?}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ACTION" ] || die "say --add HOST:PORT or --remove HOST:PORT"
printf '%s' "$ADDR" | grep -Eq '^[A-Za-z0-9.-]+:[0-9]{1,5}$' || die "address must be HOST:PORT, got '$ADDR'"

find_validator
[ -n "$VAL_PID" ] || die "no running validator found"

if [ "$EXISTING_SET" = 1 ]; then
  CURRENT=$EXISTING
elif [ "$VAL_KIND" = agave ]; then
  CURRENT=$(printf '%s\n' "$VAL_ARGS" | flag_values --shred-receiver-address | paste -sd, -)
else
  FD_CONFIG=$(printf '%s\n' "$VAL_ARGS" | flag_values --config | head -n1)
  [ -n "$FD_CONFIG" ] && [ -r "$FD_CONFIG" ] || die "Firedancer config not readable: run as the validator's user, or pass --existing"
  CURRENT=$(toml_get "$FD_CONFIG" tiles.shred additional_shred_destinations_leader | toml_array_items | paste -sd, - || true)
fi

# the new list: the current one with the address added once, or taken out; order kept
NEW=$(printf '%s\n' "$CURRENT" | tr ',' '\n' | sed '/^$/d' | awk -v a="$ADDR" -v act="$ACTION" '
  $0 == a { seen = 1; if (act == "remove") next }
  { print }
  END { if (act == "add" && !seen) print a }' | paste -sd, -)

say "current receivers: ${CURRENT:-none}"
say "new receivers:     ${NEW:-none}"
if [ "$NEW" = "$CURRENT" ]; then
  say "nothing to change"
  exit 0
fi
COUNT=$(printf '%s\n' "$NEW" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ')
[ "$COUNT" -le 32 ] || die "more than 32 addresses"

if [ "$VAL_KIND" = firedancer ]; then
  items=$(printf '%s\n' "$NEW" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')
  say ""
  say "Firedancer: set this in $FD_CONFIG, section [tiles.shred], then restart the validator away from your leader slots:"
  say ""
  say "    additional_shred_destinations_leader = [${items}]"
  say ""
  say "Use numeric IPs. Undo: put back the list printed as 'current receivers' and restart."
  exit 0
fi

# Agave based: the binary must take several addresses, or adding ours would replace another
help=$("$VAL_BIN" --help 2>/dev/null | grep -A12 -- '--shred-receiver-address' || true)
if ! printf '%s' "$help" | grep -q 'Up to 32'; then
  die "$(basename "$VAL_BIN") does not say it takes several shred receiver addresses. Do not continue: setting the list could replace your current receiver. Upgrade to jito-solana v4.4.1-jito or later, or write to info@diabloarb.com"
fi
"$VAL_BIN" set-shred-receiver-address --help >/dev/null 2>&1 || die "$(basename "$VAL_BIN") has no set-shred-receiver-address command"

[ -n "$LEDGER" ] || LEDGER=$(printf '%s\n' "$VAL_ARGS" | flag_values --ledger | head -n1)
[ -n "$LEDGER" ] || LEDGER=$(printf '%s\n' "$VAL_ARGS" | flag_values -l | head -n1)
[ -n "$LEDGER" ] || die "ledger path unknown: pass --ledger PATH"

say ""
say "run-time command:"
say "    $VAL_BIN -l $LEDGER set-shred-receiver-address --shred-receiver-address \"$NEW\""
say "start script, so that it survives a restart (replace the --shred-receiver-address you have, if any):"
say "    --shred-receiver-address $NEW"

if [ "$APPLY" = 1 ]; then
  state=/var/tmp/diabloarb-shred-receivers.$(date +%Y%m%d-%H%M%S)
  printf '%s\n' "$CURRENT" > "$state" 2>/dev/null || state=""
  "$VAL_BIN" -l "$LEDGER" set-shred-receiver-address --shred-receiver-address "$NEW"
  say ""
  say "applied. Previous list saved in ${state:-(not saved)}."
  say "Undo: $0 --existing \"$NEW\" --$( [ "$ACTION" = add ] && echo remove || echo add ) $ADDR --apply"
  say "Check during your next leader slot: scripts/verify.sh shreds --to $ADDR"
else
  say ""
  say "dry run: nothing changed. Add --apply to do it."
fi
