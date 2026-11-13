#!/usr/bin/env bash
# Path C1: point the relayer you already run at DiabloArb's endpoint, through a systemd drop-in that is easy to
# remove. The validator is not touched. Dry run by default.
#
#   relayer-switch.sh --endpoint URL [--unit NAME] [--apply]
#   relayer-switch.sh --revert [--unit NAME] [--apply]
#
# --endpoint  the endpoint DiabloArb sent you, e.g. http://<IP>:<PORT>
# --unit      the relayer's systemd unit (default: found from the running relayer process)
# --apply     write the drop-in, reload systemd and restart the relayer (needs root)
#
# Before you run it: tell DiabloArb what your relayer's --block-engine-url is today (the script prints it).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ENDPOINT="" UNIT="" APPLY=0 REVERT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT=${2:?}; shift 2 ;;
    --unit) UNIT=${2:?}; shift 2 ;;
    --revert) REVERT=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ "$REVERT" = 1 ] || printf '%s' "$ENDPOINT" | grep -Eq '^https?://[^/[:space:]]+$' || die "--endpoint must look like http://HOST:PORT"
need systemctl

find_relayer
[ -n "$REL_PID" ] || [ -n "$UNIT" ] || die "no running relayer found; pass --unit NAME"
if [ -z "$UNIT" ]; then
  UNIT=$(ps -o unit= -p "$REL_PID" 2>/dev/null | tr -d ' ' || true)
  [ -n "$UNIT" ] && [ "$UNIT" != "-" ] || die "the relayer (PID $REL_PID) is not a systemd unit; pass --unit NAME or change its start script by hand"
fi
case "$UNIT" in
  *.scope) die "the relayer runs in $UNIT (a container): set BLOCK_ENGINE_URL=$ENDPOINT in its compose file or run command by hand" ;;
esac
DROPIN_DIR=/etc/systemd/system/$UNIT.d
DROPIN=$DROPIN_DIR/diabloarb.conf

if [ "$REVERT" = 1 ]; then
  [ -e "$DROPIN" ] || { say "no DiabloArb drop-in for $UNIT: nothing to revert"; exit 0; }
  say "will remove $DROPIN, reload systemd and restart $UNIT"
  if [ "$APPLY" = 1 ]; then
    rm -f "$DROPIN" /etc/diabloarb/relayer.env
    systemctl daemon-reload
    systemctl restart "$UNIT"
    say "reverted; $UNIT runs with its own settings again"
  else
    say "dry run: add --apply"
  fi
  exit 0
fi

# where the current block engine URL comes from: the command line, or the environment (only these two keys are read)
ARG_URL=$(printf '%s\n' "$REL_ARGS" | flag_values --block-engine-url | head -n1)
ARG_AUTH=$(printf '%s\n' "$REL_ARGS" | flag_values --block-engine-auth-service-url | head -n1)
ENV_URL="" ENV_AUTH=""
if [ -n "$REL_PID" ] && [ -r "/proc/$REL_PID/environ" ]; then
  ENV_URL=$(tr '\0' '\n' < "/proc/$REL_PID/environ" | sed -n 's/^BLOCK_ENGINE_URL=//p' | head -n1)
  ENV_AUTH=$(tr '\0' '\n' < "/proc/$REL_PID/environ" | sed -n 's/^BLOCK_ENGINE_AUTH_SERVICE_URL=//p' | head -n1)
fi
KEYPAIR=$(printf '%s\n' "$REL_ARGS" | flag_values --keypair-path | head -n1)

say "relayer unit:              $UNIT"
say "block engine url now:      $( [ -n "$ARG_URL$ENV_URL" ] && url_host "${ARG_URL:-$ENV_URL}" || echo none) (from $( [ -n "$ARG_URL" ] && echo 'the command line' || echo 'the environment'))"
say "auth service url now:      $( [ -n "$ARG_AUTH$ENV_AUTH" ] && url_host "${ARG_AUTH:-$ENV_AUTH}" || echo 'same as block engine')"
if [ -n "$KEYPAIR" ] && command -v solana-keygen >/dev/null 2>&1; then
  say "relayer login public key:  $(solana-keygen pubkey "$KEYPAIR" 2>/dev/null || echo '(could not read; run: solana-keygen pubkey <its --keypair-path>)')"
  say "                           send this public key to DiabloArb before you apply"
fi

if [ -n "$ARG_URL$ARG_AUTH" ]; then
  # the URL is on the command line: the drop-in replaces ExecStart with the same arguments and the new URL, but only
  # when the unit starts the relayer binary itself (not a wrapper script)
  exec_path=$(systemctl show "$UNIT" -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n1)
  bin=$(printf '%s\n' "$REL_ARGS" | head -n1)
  if [ "$exec_path" != "$bin" ]; then
    die "$UNIT starts '$exec_path', not the relayer binary '$bin' (a wrapper script). Change --block-engine-url there by hand:
    --block-engine-url $ENDPOINT$( [ -n "$ARG_AUTH" ] && printf ' (and --block-engine-auth-service-url %s)' "$ENDPOINT")
then restart $UNIT. Undo: put the old value back."
  fi
  line=""
  skip=0
  while IFS= read -r a; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      --block-engine-url|--block-engine-auth-service-url) line="$line $a $ENDPOINT"; skip=1; continue ;;
      --block-engine-url=*) a="--block-engine-url=$ENDPOINT" ;;
      --block-engine-auth-service-url=*) a="--block-engine-auth-service-url=$ENDPOINT" ;;
    esac
    # systemd's own quoting: plain words as they are, anything else in double quotes
    if printf '%s' "$a" | grep -Eq '^[A-Za-z0-9_./:=,@+-]+$'; then
      line="$line $a"
    else
      line="$line \"$(printf '%s' "$a" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/$$/g' -e 's/%/%%/g')\""
    fi
  done <<< "$REL_ARGS"
  CONTENT="[Service]
ExecStart=
ExecStart=${line# }"
else
  # the URL comes from the environment: an environment file read after the unit's own (Environment= would lose to an
  # EnvironmentFile= of the unit)
  ENVFILE=/etc/diabloarb/relayer.env
  ENVCONTENT="BLOCK_ENGINE_URL=$ENDPOINT$( [ -n "$ENV_AUTH" ] && printf '\nBLOCK_ENGINE_AUTH_SERVICE_URL=%s' "$ENDPOINT")"
  CONTENT="[Service]
EnvironmentFile=$ENVFILE"
fi

say ""
say "drop-in $DROPIN:"
printf '%s\n' "$CONTENT" | sed 's/^/    /'
if [ -n "${ENVFILE:-}" ]; then
  say "environment file $ENVFILE:"
  printf '%s\n' "$ENVCONTENT" | sed 's/^/    /'
fi
say ""
say "The validator keeps using the relayer as before. If the relayer stops, the validator falls back to its own TPU."
if [ "$APPLY" = 1 ]; then
  mkdir -p "$DROPIN_DIR"
  if [ -n "${ENVFILE:-}" ]; then
    mkdir -p "$(dirname "$ENVFILE")"
    printf '%s\n' "$ENVCONTENT" > "$ENVFILE"
  fi
  printf '%s\n' "$CONTENT" > "$DROPIN"
  systemctl daemon-reload
  systemctl restart "$UNIT"
  say "applied and restarted $UNIT."
  say "Check: scripts/verify.sh relayer --unit $UNIT"
  say "Undo:  $0 --revert --unit $UNIT --apply"
else
  say "dry run: nothing changed. Add --apply to do it."
fi
