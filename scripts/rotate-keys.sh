#!/usr/bin/env bash
# rotate-keys.sh [name ...] [--server]
#
# Issues fresh keypairs and re-registers the peers. Old keys stop working the
# moment the new peer is set, which is the point of a rotation.
#
#   with no arguments : rotate every client device
#   with names        : rotate only those devices
#   --server          : also rotate the SERVER keypair (all clients must be
#                       re-imported afterwards - it is not instant)
#
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need_root

ROTATE_SERVER=0; NAMES=()
for a in "$@"; do
  [ "$a" = "--server" ] && ROTATE_SERVER=1 || NAMES+=("$a")
done

rotate_one() {
  local iface="$1" name="$2" tool
  tool=$([ "$iface" = "$AWG_IFACE" ] && echo awg || echo wg)

  [ -f "$KEY_DIR/$name.key" ] || { warn "$name: no key on file, skipping"; return; }
  local old_pub new_pub
  old_pub=$(cat "$KEY_DIR/$name.pub")

  asroot "$tool" set "$iface" peer "$old_pub" remove 2>/dev/null || true
  gen_keypair "$name" "$tool"
  new_pub=$(cat "$KEY_DIR/$name.pub")

  # reuse the existing address for this device
  local cf ips ip4 ip6
  cf=$(cfg_file "$iface")
  ips=$(list_peers "$iface" | awk -F'|' -v k="$old_pub" '$2==k {print $3}')
  [ -n "$ips" ] || ips=$(asroot "$tool" show "$iface" 2>/dev/null | awk -v k="$old_pub" '$1==k{print $4}' | tr -d ' ')
  ip4=$(echo "$ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  ip6=$(echo "$ips" | grep -oE 'f[d]?[0-9a-f:]+/[0-9]+' | head -1)
  [ -n "$ip4" ] || ip4=$(next_ip "$WG_SUBNET4" "$(used_ip4 "$iface")")

  asroot "$tool" set "$iface" peer "$new_pub" allowed-ips "$ip4/32${ip6:+,$ip6}"
  ok "$name rotated -> new pubkey ${new_pub:0:12}..."
  info "  re-issue this device's config (add-device.sh will refuse: key exists)"
  info "  workaround: move $KEY_DIR/$name.key aside first, or use --force"
}

# Find which interface each named device currently lives on.
find_iface() {
  local name="$1"
  [ -f "$KEY_DIR/$name.pub" ] || { echo ""; return; }
  local pub; pub=$(cat "$KEY_DIR/$name.pub")
  if asroot wg show "$WG_IFACE" peers 2>/dev/null | grep -qxF "$pub"; then echo "$WG_IFACE"; return; fi
  if asroot awg show "$AWG_IFACE" peers 2>/dev/null | grep -qxF "$pub"; then echo "$AWG_IFACE"; return; fi
  echo ""
}

if [ ${#NAMES[@]} -eq 0 ]; then
  mapfile -t NAMES < <(ls "$KEY_DIR" 2>/dev/null | sed -n 's/\.key$//p' \
    | grep -vE '^(server|awg-server)$')
fi
[ ${#NAMES[@]} -gt 0 ] || die "no client keys found in $KEY_DIR"

echo
info "rotating ${#NAMES[@]} device(s)"
for n in "${NAMES[@]}"; do
  i=$(find_iface "$n")
  [ -n "$i" ] || { warn "$n: not registered on any interface, skipping"; continue; }
  rotate_one "$i" "$n"
done

if [ "$ROTATE_SERVER" = "1" ]; then
  echo
  warn "--server: rotating server keys."
  warn "EVERY client must be re-imported. They will stay connected until"
  warn "the interface reloads, then all handshakes will fail."
  for pair in "$WG_IFACE wg" "$AWG_IFACE awg"; do
    set -- $pair; i=$1; t=$2
    [ -f "$(cfg_file "$i")" ] || continue
    gen_keypair "server" "$t" 2>/dev/null || true
    case "$t" in
      wg)  gen_keypair "server" wg  ;;
      awg) gen_keypair "awg-server" awg ;;
    esac
    tmp=$(mktemp); asroot cat "$(cfg_file "$i")" > "$tmp"
    /usr/bin/python3 - "$tmp" "$KEY_DIR" "$t" <<'PY'
import sys, re
cfg, kd, t = sys.argv[1], sys.argv[2], sys.argv[3]
name = 'server' if t == 'wg' else 'awg-server'
key = open(f'{kd}/{name}.key').read().strip()
s = open(cfg).read()
s = re.sub(r'(?m)^PrivateKey\s*=.*$', f'PrivateKey = {key}', s, count=1)
open(cfg, 'w').write(s)
PY
    asroot install -m 600 -o root -g root "$tmp" "$(cfg_file "$i")"
    rm -f "$tmp"
    ok "$i server key replaced (reload to apply)"
  done
fi

echo
ok "rotation complete"
