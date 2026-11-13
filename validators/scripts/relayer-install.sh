#!/usr/bin/env bash
# Path C2: install a relayer in front of the validator's TPU, copying DEX transactions to DiabloArb. Testnet first:
# on mainnet it refuses to run without --tested-on-testnet. Installs and starts the relayer only; attaching the
# validator to it is one command it prints, which you run yourself. Dry run by default.
#
#   relayer-install.sh --endpoint URL --identity PUBKEY --public-ip IP [--cluster testnet|mainnet]
#                      [--rpc URL] [--ws URL] [--delay-ms N] [--prefix DIR] [--user NAME] [--tested-on-testnet] [--apply]
#   relayer-install.sh --uninstall [--prefix DIR] [--apply]
#
# --endpoint   the endpoint DiabloArb sent you
# --identity   your validator identity public key: the only validator allowed to attach to the relayer
# --public-ip  the address your validator will advertise as its TPU (this host's public IP)
# --rpc, --ws  your own RPC (default http://127.0.0.1:8899 and ws://127.0.0.1:8900)
# --delay-ms   how long every packet waits before it reaches the validator (relayer default 50; agree it with us)
# --prefix     where it goes (default /opt/diabloarb-relayer); --user the service user (default sol)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

VERSION=v0.4.2
URL="https://github.com/jito-foundation/jito-relayer/releases/download/$VERSION/jito-transaction-relayer-x86_64-unknown-linux-gnu"
SHA256=62a64239211e00821cd891505326820133873a3119f04c71504c2e4391b282da
UNIT=diabloarb-relayer

ENDPOINT="" IDENTITY="" PUBLIC_IP="" CLUSTER=testnet RPC=http://127.0.0.1:8899 WS=ws://127.0.0.1:8900 DELAY=50
PREFIX=/opt/diabloarb-relayer RUSER=sol TESTED=0 APPLY=0 UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT=${2:?}; shift 2 ;;
    --identity) IDENTITY=${2:?}; shift 2 ;;
    --public-ip) PUBLIC_IP=${2:?}; shift 2 ;;
    --cluster) CLUSTER=${2:?}; shift 2 ;;
    --rpc) RPC=${2:?}; shift 2 ;;
    --ws) WS=${2:?}; shift 2 ;;
    --delay-ms) DELAY=${2:?}; shift 2 ;;
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --user) RUSER=${2:?}; shift 2 ;;
    --tested-on-testnet) TESTED=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
need systemctl

if [ "$UNINSTALL" = 1 ]; then
  say "will: stop and disable $UNIT, remove /etc/systemd/system/$UNIT.service and $PREFIX/bin/jito-transaction-relayer (keys in $PREFIX/keys are kept)"
  say "First detach the validator:  agave-validator -l <LEDGER> set-relayer-config --relayer-url \"\"  and remove --relayer-url from its start script."
  if [ "$APPLY" = 1 ]; then
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/$UNIT.service" "$PREFIX/bin/jito-transaction-relayer"
    systemctl daemon-reload
    say "removed."
  else
    say "dry run: add --apply"
  fi
  exit 0
fi

need curl openssl sha256sum
printf '%s' "$ENDPOINT" | grep -Eq '^https?://[^/[:space:]]+$' || die "--endpoint must look like http://HOST:PORT"
printf '%s' "$IDENTITY" | grep -Eq '^[1-9A-HJ-NP-Za-km-z]{32,44}$' || die "--identity must be your validator identity public key"
printf '%s' "$PUBLIC_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "--public-ip must be an IPv4 address"
printf '%s' "$DELAY" | grep -Eq '^[0-9]+$' || die "--delay-ms must be a number"
# the Solana Foundation Delegation Program: TPU transactions may not be delayed beyond 50 ms (solana.org/delegation-criteria)
[ "$DELAY" -le 50 ] || warn "--delay-ms $DELAY is over 50 ms: the Solana Foundation Delegation Program does not allow delaying TPU transactions beyond 50 ms"
case "$CLUSTER" in
  testnet) ;;
  mainnet) [ "$TESTED" = 1 ] || die "on mainnet only after a testnet trial with DiabloArb: add --tested-on-testnet when you have done it" ;;
  *) die "--cluster is testnet or mainnet" ;;
esac
[ "$(uname -m)" = x86_64 ] || die "the released relayer binary is for x86_64 Linux only"
id "$RUSER" >/dev/null 2>&1 || die "user '$RUSER' does not exist: pass --user"
for p in 11226/tcp 11228/udp 11229/udp; do
  port=${p%/*}
  if ss -lun 2>/dev/null | awk '{print $5}' | grep -q ":$port\$" || ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"; then
    die "port $port is in use on this host"
  fi
done

say "plan:"
say "  1. download jito-transaction-relayer $VERSION to $PREFIX/bin and check its SHA-256 ($SHA256)"
say "  2. make in $PREFIX/keys (mode 700): an RSA key pair for the relayer's tokens (private.pem, public.pem)"
say "     and a Solana keypair for the relayer's login to DiabloArb (relayer-auth.json); none of your keys is used"
say "  3. write /etc/systemd/system/$UNIT.service (template: templates/diabloarb-relayer.service) and start it"
say "  4. you: open UDP 11228-11229 to the internet, keep TCP 11226 closed to everyone but this host"
say "  5. you: attach the validator (command printed at the end)"
[ "$APPLY" = 1 ] || { say ""; say "dry run: nothing changed. Add --apply to do steps 1-3."; exit 0; }

mkdir -p "$PREFIX/bin" "$PREFIX/keys"
chmod 700 "$PREFIX/keys"
curl -sSL -m 300 -o "$PREFIX/bin/jito-transaction-relayer.part" "$URL"
got=$(sha256sum "$PREFIX/bin/jito-transaction-relayer.part" | cut -c1-64)
[ "$got" = "$SHA256" ] || { rm -f "$PREFIX/bin/jito-transaction-relayer.part"; die "SHA-256 mismatch: got $got"; }
chmod 755 "$PREFIX/bin/jito-transaction-relayer.part"
mv -f "$PREFIX/bin/jito-transaction-relayer.part" "$PREFIX/bin/jito-transaction-relayer"
"$PREFIX/bin/jito-transaction-relayer" --version

[ -e "$PREFIX/keys/private.pem" ] || openssl genrsa -out "$PREFIX/keys/private.pem" 2048 2>/dev/null
[ -e "$PREFIX/keys/public.pem" ] || openssl rsa -in "$PREFIX/keys/private.pem" -pubout -out "$PREFIX/keys/public.pem" 2>/dev/null
if [ ! -e "$PREFIX/keys/relayer-auth.json" ]; then
  need solana-keygen
  solana-keygen new --no-bip39-passphrase --silent -o "$PREFIX/keys/relayer-auth.json" >/dev/null
fi
chmod 600 "$PREFIX/keys/"*
chown -R "$RUSER" "$PREFIX/keys"

sed -e "s#@USER@#$RUSER#g" -e "s#@PREFIX@#$PREFIX#g" -e "s#@ENDPOINT@#$ENDPOINT#g" -e "s#@PUBLIC_IP@#$PUBLIC_IP#g" \
    -e "s#@RPC@#$RPC#g" -e "s#@WS@#$WS#g" -e "s#@IDENTITY@#$IDENTITY#g" -e "s#@DELAY_MS@#$DELAY#g" \
    "$DIR/../templates/diabloarb-relayer.service" > "/etc/systemd/system/$UNIT.service"
systemctl daemon-reload
systemctl enable --now "$UNIT"
sleep 3
systemctl is-active --quiet "$UNIT" || die "$UNIT did not start: journalctl -u $UNIT -n 50"

say ""
say "relayer running. Its login public key (send it to DiabloArb): $(solana-keygen pubkey "$PREFIX/keys/relayer-auth.json")"
say ""
say "Now attach the validator, at a moment away from your leader slots:"
say "    agave-validator -l <LEDGER> set-relayer-config --relayer-url http://127.0.0.1:11226"
say "and add to its start script:  --relayer-url http://127.0.0.1:11226"
say "Check:  scripts/verify.sh relayer --unit $UNIT   and   scripts/detect-setup.sh (TPU should move to port 11228)"
say "Detach: agave-validator -l <LEDGER> set-relayer-config --relayer-url \"\""
