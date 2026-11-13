#!/usr/bin/env bash
# Which validator setup runs on this host and which integration paths fit it. Read only: looks at the running
# processes, their config file and the cluster's gossip table. Prints a report and a summary to send to DiabloArb.
#
#   detect-setup.sh [--identity PUBKEY] [--rpc URL]
#
# --identity  your validator identity public key (default: asked from the local RPC with getIdentity)
# --rpc       RPC for getClusterNodes (default: the local RPC on 127.0.0.1:8899, then the public mainnet RPC)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

IDENTITY="" RPC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY=${2:?}; shift 2 ;;
    --rpc) RPC=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
need curl jq awk sed

say "DiabloArb validator kit $KIT_VERSION: detect-setup"
say ""

# --- the processes ---------------------------------------------------------------------------------------------
find_validator
find_relayer
HARMONIC_PID=$(find_pid 'harmonic-scheduler')
SETUP="" SHRED_LIST="" OVERRIDES="" BLOCK_ENGINE="" RELAYER_URL="" FD_CONFIG="" LEDGER=""

if [ -z "$VAL_PID" ]; then
  warn "no running validator found (agave-validator, solana-validator, fdctl or firedancer with 'run')"
else
  say "validator process: $VAL_PID ($VAL_KIND, $(basename "$VAL_BIN"))"
  if [ "$VAL_KIND" = agave ]; then
    LEDGER=$(printf '%s\n' "$VAL_ARGS" | flag_values --ledger | head -n1)
    [ -n "$LEDGER" ] || LEDGER=$(printf '%s\n' "$VAL_ARGS" | flag_values -l | head -n1)
    SHRED_LIST=$(printf '%s\n' "$VAL_ARGS" | flag_values --shred-receiver-address | paste -sd, -)
    OVERRIDES=$(printf '%s\n' "$VAL_ARGS" | flag_values --staked-nodes-overrides | head -n1)
    BLOCK_ENGINE=$(printf '%s\n' "$VAL_ARGS" | flag_values --block-engine-url | head -n1)
    RELAYER_URL=$(printf '%s\n' "$VAL_ARGS" | flag_values --relayer-url | head -n1)
    if printf '%s\n' "$VAL_ARGS" | has_flag --bam-url; then SETUP=bam
    elif [ -n "$HARMONIC_PID" ] || printf '%s\n' "$VAL_ARGS" | has_flag --enable-scheduler-bindings; then SETUP=harmonic
    elif [ -n "$RELAYER_URL" ]; then SETUP=jito_with_relayer
    elif [ -n "$BLOCK_ENGINE" ]; then SETUP=jito
    else SETUP=agave
    fi
  else
    FD_CONFIG=$(printf '%s\n' "$VAL_ARGS" | flag_values --config | head -n1)
    if [ -n "$FD_CONFIG" ] && [ -r "$FD_CONFIG" ]; then
      bam=$(toml_get "$FD_CONFIG" tiles.bam enabled || true)
      tpu_url=$(toml_get "$FD_CONFIG" tiles.bundle tpu_url | tr -d '"' || true)
      BLOCK_ENGINE=$(toml_get "$FD_CONFIG" tiles.bundle url | tr -d '"' || true)
      SHRED_LIST=$(toml_get "$FD_CONFIG" tiles.shred additional_shred_destinations_leader | toml_array_items | paste -sd, - || true)
      if [ "$bam" = true ]; then SETUP=bam
      elif printf '%s' "$tpu_url$BLOCK_ENGINE" | grep -q 'harmonic'; then SETUP=harmonic
      else SETUP=firedancer
      fi
    else
      warn "Firedancer config not found or not readable (pass it with --config to the validator, or run as its user)"
      SETUP=firedancer
    fi
  fi
fi
[ -n "$REL_PID" ] && say "relayer process: $REL_PID ($(printf '%s\n' "$REL_ARGS" | head -n1 | xargs basename))"
[ -n "$HARMONIC_PID" ] && say "harmonic-scheduler process: $HARMONIC_PID"

# --- the network's view ----------------------------------------------------------------------------------------
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(rpc_call "http://127.0.0.1:8899" '{"jsonrpc":"2.0","id":1,"method":"getIdentity"}' 2>/dev/null | jq -r '.result.identity // empty' 2>/dev/null || true)
fi
CLIENT="" TPU="" GOSSIP=""
if [ -n "$IDENTITY" ]; then
  for url in ${RPC:+"$RPC"} "http://127.0.0.1:8899" "$PUBLIC_RPC"; do
    nodes=$(rpc_call "$url" '{"jsonrpc":"2.0","id":1,"method":"getClusterNodes"}' 2>/dev/null || true)
    if printf '%s' "$nodes" | jq -e '.result' >/dev/null 2>&1; then
      row=$(printf '%s' "$nodes" | jq -r --arg id "$IDENTITY" '.result[] | select(.pubkey == $id) | [(.clientId // "?"), (.tpuQuic // ""), (.gossip // "")] | @tsv')
      IFS=$'\t' read -r CLIENT TPU GOSSIP <<< "$row" || true
      break
    fi
  done
else
  warn "identity unknown: pass --identity PUBKEY to compare with the gossip table"
fi

# --- the report ------------------------------------------------------------------------------------------------
say ""
say "setup (from the processes):      ${SETUP:-unknown}"
say "client announced in gossip:      ${CLIENT:-unknown}"
if [ -n "$TPU" ] && [ -n "$GOSSIP" ]; then
  if [ "${TPU%%:*}" = "${GOSSIP%%:*}" ]; then
    say "TPU advertised:                  on this node's address (${TPU#*:} is the port)"
  else
    say "TPU advertised:                  on another machine (${TPU%%:*}), not on this node"
  fi
fi
say "block engine:                    $( [ -n "$BLOCK_ENGINE" ] && url_host "$BLOCK_ENGINE" || echo none)"
say "relayer url:                     $( [ -n "$RELAYER_URL" ] && url_host "$RELAYER_URL" || echo none)"
say "shred receivers (leader):        ${SHRED_LIST:-none}"
say "staked nodes overrides file:     ${OVERRIDES:-none}"

case "$CLIENT" in
  AgaveBam|FireBAM) [ "$SETUP" = bam ] || warn "gossip says BAM, the processes say $SETUP: check which client is running" ;;
  HarmonicAgave|HarmonicFiredancer) [ "$SETUP" = harmonic ] || warn "gossip says Harmonic, the processes say $SETUP" ;;
esac

say ""
case "$SETUP" in
  bam)
    say "Your users' transactions go to a Jito BAM node, not to this machine."
    say "Fits: A (leader shred mirror): scripts/shred-mirror.sh. Not B, not C." ;;
  harmonic)
    say "Your users' transactions go to Harmonic's Remote TPU, not to this machine."
    say "Fits: A (leader shred mirror) if your client takes a second shred address: scripts/shred-mirror.sh checks it."
    say "Keep Harmonic's own receiver in the list." ;;
  jito_with_relayer)
    say "Your users' transactions arrive at your relayer."
    say "Fits: C1 (point your relayer at DiabloArb): scripts/relayer-switch.sh; A: scripts/shred-mirror.sh;"
    say "B on the relayer: scripts/staked-overrides.sh --relayer." ;;
  jito)
    say "Your users' transactions arrive at this validator."
    say "Fits: A: scripts/shred-mirror.sh; B: scripts/staked-overrides.sh; C2 (add a relayer, testnet first): scripts/relayer-install.sh." ;;
  firedancer)
    say "Your users' transactions arrive at this validator."
    say "Fits: A: scripts/shred-mirror.sh (prints the config change). For B ask DiabloArb." ;;
  agave)
    say "Your users' transactions arrive at this validator."
    say "Fits: B: scripts/staked-overrides.sh. Agave has no shred mirror option." ;;
  *)
    say "Setup not recognised. Send the summary below to DiabloArb." ;;
esac

say ""
say "Summary to send to info@diabloarb.com (no secrets in it):"
say "kit=$KIT_VERSION identity=${IDENTITY:-?} setup=${SETUP:-?} client=${CLIENT:-?} version=$( [ "$VAL_KIND" = agave ] && "$VAL_BIN" --version 2>/dev/null | head -n1 | tr ' ' '_' || echo ?) tpu_on_node=$( [ -n "$TPU" ] && [ "${TPU%%:*}" = "${GOSSIP%%:*}" ] && echo yes || echo no) relayer=$( [ -n "$REL_PID" ] && echo yes || echo no) shred_receivers=$(printf '%s' "$SHRED_LIST" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ') overrides=$( [ -n "$OVERRIDES" ] && echo yes || echo no)"
