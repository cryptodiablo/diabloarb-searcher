#!/usr/bin/env bash
# Checks after each path. Read only.
#
#   verify.sh shreds --to HOST:PORT [--identity PUBKEY] [--rpc URL]   path A: are shreds leaving for the receiver?
#   verify.sh relayer [--unit NAME]                                   path C: is the relayer up, logged in, attached?
#   verify.sh tpu [--identity PUBKEY] [--rpc URL]                     where the network sends your users' transactions
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

WHAT=${1:-}; [ $# -gt 0 ] && shift
TO="" IDENTITY="" RPC="" UNIT=diabloarb-relayer
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO=${2:?}; shift 2 ;;
    --identity) IDENTITY=${2:?}; shift 2 ;;
    --rpc) RPC=${2:?}; shift 2 ;;
    --unit) UNIT=${2:?}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
need curl jq

rpc_url() {
  local u
  for u in ${RPC:+"$RPC"} "http://127.0.0.1:8899" "$PUBLIC_RPC"; do
    if rpc_call "$u" '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' 2>/dev/null | jq -e '.result' >/dev/null 2>&1; then
      printf '%s\n' "$u"; return 0
    fi
  done
  return 1
}
identity() {
  [ -n "$IDENTITY" ] && { printf '%s\n' "$IDENTITY"; return 0; }
  rpc_call "http://127.0.0.1:8899" '{"jsonrpc":"2.0","id":1,"method":"getIdentity"}' 2>/dev/null | jq -r '.result.identity // empty'
}

case "$WHAT" in
  shreds)
    need tcpdump
    printf '%s' "$TO" | grep -Eq '^[0-9.]+:[0-9]+$' || die "--to IP:PORT (numeric IP)"
    id=$(identity); [ -n "$id" ] || die "identity unknown: pass --identity PUBKEY"
    url=$(rpc_url) || die "no RPC answers: pass --rpc URL"
    info=$(rpc_call "$url" '{"jsonrpc":"2.0","id":1,"method":"getEpochInfo"}')
    slot=$(printf '%s' "$info" | jq -r '.result.absoluteSlot'); index=$(printf '%s' "$info" | jq -r '.result.slotIndex')
    sched=$(rpc_call "$url" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLeaderSchedule\",\"params\":[null,{\"identity\":\"$id\"}]}")
    next=$(printf '%s' "$sched" | jq -r --arg id "$id" --argjson i "$index" '[.result[$id][]? | select(. > $i)] | min // empty')
    [ -n "$next" ] || die "no leader slot of $id left in this epoch"
    wait_s=$(( (next - index) * 2 / 5 ))
    say "next leader slot: $((slot - index + next)), in about $wait_s s"
    [ "$wait_s" -le 1800 ] || die "more than 30 minutes away: run this again closer to it"
    say "listening for UDP to $TO for $((wait_s + 20)) s (needs root)…"
    n=$(timeout $((wait_s + 20)) tcpdump -ni any -q "udp and dst host ${TO%:*} and dst port ${TO#*:}" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "${n:-0}" -gt 0 ]; then say "OK: $n packets to $TO around your leader slot"; else say "FAIL: no packets to $TO. See the troubleshooting table in the README"; fi ;;
  relayer)
    need systemctl journalctl
    systemctl is-active --quiet "$UNIT" || die "$UNIT is not running: journalctl -u $UNIT -n 50"
    say "OK: $UNIT is running"
    log=$(journalctl -u "$UNIT" --since '-10 min' --no-pager 2>/dev/null || true)
    say "last 10 minutes: $(printf '%s\n' "$log" | grep -ci 'error') lines with 'error', $(printf '%s\n' "$log" | grep -ci 'auth') with 'auth'"
    printf '%s\n' "$log" | grep -iE 'error|auth|connect' | tail -n 8 | sed -E 's#(https?://[^/ ]+)[^ ]*#\1#g'
    say "Is the validator attached? Its TPU should now be this host's port 11228:  $0 tpu" ;;
  tpu)
    id=$(identity); [ -n "$id" ] || die "identity unknown: pass --identity PUBKEY"
    url=$(rpc_url) || die "no RPC answers: pass --rpc URL"
    row=$(rpc_call "$url" '{"jsonrpc":"2.0","id":1,"method":"getClusterNodes"}' | jq -r --arg id "$id" '.result[] | select(.pubkey == $id) | "client \(.clientId // "?"), TPU \(.tpuQuic // "none"), gossip \(.gossip // "none")"')
    say "${row:-$id is not in the gossip table}" ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
