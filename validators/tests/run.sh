#!/usr/bin/env bash
# Tests of the kit's scripts on fake processes, fake validator binaries and fake config files: nothing on the host is
# read or changed, no network. Run from anywhere:  bash tests/run.sh
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export PATH="$T/bin:$PATH"
mkdir -p "$T/bin"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { # name, needle, haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (wanted: $2)"; printf '%s\n' "$3" | sed 's/^/      | /' | head -20; fi
}
expect_not() {
  if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 (did not want: $2)"; else ok "$1"; fi
}

# a fake validator binary: help text as in jito-solana v4.4.1 (MULTI=1) or a single-address one, and a log of commands
cat > "$T/bin/agave-validator" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  --help) printf '        --shred-receiver-address <SHRED_RECEIVER_ADDRESS>...\n'
          if [ "${MULTI:-1}" = 1 ]; then printf '            Validator will mirror ... Up to 32 unique addresses are allowed.\n'; else printf '            Validator will mirror shreds to this address.\n'; fi ;;
  --version) echo "agave-validator 4.4.1 (src:00000000; feat:0, client:JitoLabs)" ;;
  *"set-shred-receiver-address --help"*|*"staked-nodes-overrides --help"*) exit 0 ;;
  *) echo "$*" >> "$CALLS" ;;
esac
EOF
chmod +x "$T/bin/agave-validator"
export CALLS="$T/calls"

ps_with() { printf '%s\n' "$@" > "$T/ps"; export DIABLOARB_PS_FILE="$T/ps"; }

# --- detect-setup ---
ps_with "100 /usr/local/bin/agave-validator --identity /k/id.json --ledger /mnt/ledger --block-engine-url https://ny.mainnet.block-engine.jito.wtf --bam-url http://ny.mainnet.bam.jito.wtf --shred-receiver-address 198.51.100.4:1002"
out=$(bash "$KIT/scripts/detect-setup.sh" --identity 11111111111111111111111111111111 --rpc http://127.0.0.1:1 2>&1)
expect "detect: BAM by --bam-url" "setup (from the processes):      bam" "$out"
expect "detect: BAM fits A only" "Fits: A (leader shred mirror)" "$out"
expect "detect: shred list read" "198.51.100.4:1002" "$out"
expect_not "detect: no URL path printed" "/api" "$out"

ps_with "100 /usr/local/bin/agave-validator --identity /k/id.json --ledger /mnt/ledger --enable-scheduler-bindings --shred-receiver-address 192.0.2.10:8001" \
        "101 /usr/local/bin/harmonic-scheduler -l /mnt/ledger --remote-tpu-url https://x.tpu.harmonic.gg"
out=$(bash "$KIT/scripts/detect-setup.sh" --identity 11111111111111111111111111111111 --rpc http://127.0.0.1:1 2>&1)
expect "detect: Harmonic Salsa" "setup (from the processes):      harmonic" "$out"

ps_with "100 /home/sol/bin/agave-validator --identity /k/id.json -l /mnt/ledger --block-engine-url https://mainnet.block-engine.jito.wtf --relayer-url http://127.0.0.1:11226" \
        "200 /opt/relayer/jito-transaction-relayer --block-engine-url https://mainnet.block-engine.jito.wtf --keypair-path /opt/relayer/auth.json"
out=$(bash "$KIT/scripts/detect-setup.sh" --identity 11111111111111111111111111111111 --rpc http://127.0.0.1:1 2>&1)
expect "detect: Jito with relayer" "setup (from the processes):      jito_with_relayer" "$out"
expect "detect: relayer process" "relayer process: 200" "$out"
expect "detect: summary line" "relayer=yes" "$out"

ps_with "100 /home/sol/bin/agave-validator --identity /k/id.json --ledger /mnt/ledger --block-engine-url https://mainnet.block-engine.jito.wtf"
out=$(bash "$KIT/scripts/detect-setup.sh" --identity 11111111111111111111111111111111 --rpc http://127.0.0.1:1 2>&1)
expect "detect: Jito" "setup (from the processes):      jito" "$out"

ps_with "100 /home/sol/bin/agave-validator --identity /k/id.json --ledger /mnt/ledger"
out=$(bash "$KIT/scripts/detect-setup.sh" --identity 11111111111111111111111111111111 --rpc http://127.0.0.1:1 2>&1)
expect "detect: Agave" "setup (from the processes):      agave" "$out"

cat > "$T/fd.toml" <<'EOF'
[tiles.bundle]
    enabled = true
    url = "https://fra.auction.harmonic.gg"
    tpu_url = "https://fra.tpu.harmonic.gg"
[tiles.shred]
    additional_shred_destinations_retransmit = []
    additional_shred_destinations_leader = [
        "192.0.2.10:8001",
    ]
EOF
ps_with "300 /opt/fd/fdctl run --config $T/fd.toml"
out=$(bash "$KIT/scripts/detect-setup.sh" --identity 11111111111111111111111111111111 --rpc http://127.0.0.1:1 2>&1)
expect "detect: Harmonic Samba from config" "setup (from the processes):      harmonic" "$out"
expect "detect: multi-line TOML array" "shred receivers (leader):        192.0.2.10:8001" "$out"

# --- shred-mirror ---
ps_with "100 $T/bin/agave-validator --identity /k/id.json --ledger /mnt/ledger --shred-receiver-address 198.51.100.4:1002"
out=$(bash "$KIT/scripts/shred-mirror.sh" --add 203.0.113.7:20001 2>&1)
expect "mirror: keeps the old address and adds ours" "new receivers:     198.51.100.4:1002,203.0.113.7:20001" "$out"
expect "mirror: dry run" "dry run" "$out"
: > "$CALLS"
bash "$KIT/scripts/shred-mirror.sh" --add 203.0.113.7:20001 --apply >/dev/null 2>&1
expect "mirror: applied with the full list" "-l /mnt/ledger set-shred-receiver-address --shred-receiver-address 198.51.100.4:1002,203.0.113.7:20001" "$(cat "$CALLS")"
out=$(bash "$KIT/scripts/shred-mirror.sh" --existing "198.51.100.4:1002,203.0.113.7:20001" --remove 203.0.113.7:20001 2>&1)
expect "mirror: undo keeps the old address" "new receivers:     198.51.100.4:1002" "$out"
out=$(bash "$KIT/scripts/shred-mirror.sh" --existing "198.51.100.4:1002,203.0.113.7:20001" --add 203.0.113.7:20001 2>&1)
expect "mirror: adding twice changes nothing" "nothing to change" "$out"
: > "$CALLS"
out=$(MULTI=0 bash "$KIT/scripts/shred-mirror.sh" --add 203.0.113.7:20001 --apply 2>&1)
expect "mirror: refuses a single-address binary" "does not say it takes several" "$out"
if [ -s "$CALLS" ]; then bad "mirror: a command ran on a single-address binary"; else ok "mirror: no command on a single-address binary"; fi
out=$(bash "$KIT/scripts/shred-mirror.sh" --add 'bad;rm' 2>&1)
expect "mirror: rejects a malformed address" "address must be HOST:PORT" "$out"
ps_with "300 /opt/fd/fdctl run --config $T/fd.toml"
out=$(bash "$KIT/scripts/shred-mirror.sh" --add 203.0.113.7:20001 2>&1)
expect "mirror: Firedancer line keeps Harmonic's receiver" 'additional_shred_destinations_leader = ["192.0.2.10:8001", "203.0.113.7:20001"]' "$out"

# --- staked-overrides ---
K1=Vote111111111111111111111111111111111111111
K2=Stake11111111111111111111111111111111111111
K3=Config1111111111111111111111111111111111111
printf 'staked_map_id:\n  %s: 5000000000\n' "$K3" > "$T/over.yml"
ps_with "100 $T/bin/agave-validator --identity /k/id.json --ledger /mnt/ledger --staked-nodes-overrides $T/over.yml"
: > "$CALLS"
bash "$KIT/scripts/staked-overrides.sh" --add "$K1=100000000000000" --add "$K2=7" --apply >/dev/null 2>&1
expect "overrides: keeps the existing entry" "  $K3: 5000000000" "$(cat "$T/over.yml")"
expect "overrides: adds ours" "  $K1: 100000000000000" "$(cat "$T/over.yml")"
expect "overrides: loaded into the validator" "-l /mnt/ledger staked-nodes-overrides $T/over.yml" "$(cat "$CALLS")"
if ls "$T"/over.yml.bak-diabloarb-* >/dev/null 2>&1; then ok "overrides: backup kept"; else bad "overrides: backup kept"; fi
bash "$KIT/scripts/staked-overrides.sh" --add "$K1=200" --apply >/dev/null 2>&1
n=$(grep -c "$K1" "$T/over.yml")
if [ "$n" = 1 ]; then ok "overrides: a key is replaced, not doubled"; else bad "overrides: $K1 appears $n times"; fi
bash "$KIT/scripts/staked-overrides.sh" --remove "$K1" --remove "$K2" --apply >/dev/null 2>&1
expect_not "overrides: undo removes ours" "$K1" "$(cat "$T/over.yml")"
expect "overrides: undo keeps theirs" "$K3" "$(cat "$T/over.yml")"
printf 'staked_map_id:\n  %s: 5\nother: 1\n' "$K3" > "$T/odd.yml"
out=$(bash "$KIT/scripts/staked-overrides.sh" --file "$T/odd.yml" --add "$K1=1" --apply 2>&1)
expect "overrides: refuses a file it does not understand" "does not understand" "$out"
out=$(bash "$KIT/scripts/staked-overrides.sh" --add "notakey=1" 2>&1)
expect "overrides: rejects a bad key" "not a public key" "$out"

# --- relayer-install argument checks (no install) ---
out=$(bash "$KIT/scripts/relayer-install.sh" --endpoint http://203.0.113.7:20000 --identity "$K1" --public-ip 198.51.100.4 --cluster mainnet 2>&1)
expect "install: mainnet needs a testnet trial" "only after a testnet trial" "$out"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
