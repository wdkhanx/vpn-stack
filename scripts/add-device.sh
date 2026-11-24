#!/usr/bin/env bash
# add-device.sh <name> [--awg] [--dns <ip>] [--split]
#
# Adds a client to the LIVE server - no restart, existing clients stay connected -
# then writes clients/<name>.conf and clients/<name>.png (QR) on the operator's
# machine. The private key never leaves the server.
#
#   --awg    put the client on the obfuscated AmneziaWG interface
#   --split  route only the VPN subnet (no full tunnel)
#
set -euo pipefail
source "$(dirname "$0")/lib.sh"

NAME=""; TRANSPORT=wg; DNS_OVERRIDE=""; SPLIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --awg)   TRANSPORT=awg ;;
    --split) SPLIT=1 ;;
    --dns)   shift; DNS_OVERRIDE="$1" ;;
    -*)      die "unknown flag: $1" ;;
    *)       NAME="$1" ;;
  esac
  shift
done
[ -n "$NAME" ] || die "usage: add-device.sh <name> [--awg] [--dns <ip>] [--split]"
need_root

if [ "$TRANSPORT" = "awg" ]; then
  IFACE="$AWG_IFACE"; SUBNET4="$AWG_SUBNET4"; SUBNET6="$AWG_SUBNET6"; TOOL=awg
  DNS_DEFAULT="${AWG_SUBNET4%.*}.1"
else
  IFACE="$WG_IFACE";  SUBNET4="$WG_SUBNET4";  SUBNET6="$WG_SUBNET6";  TOOL=wg
  DNS_DEFAULT="${WG_SUBNET4%.*}.1"
fi
DNS=${DNS_OVERRIDE:-$DNS_DEFAULT}
SERVER_IP=$(public_ip4)
[ -n "$SERVER_IP" ] || die "could not determine the public IPv4 for the Endpoint"

[ -f "$(cfg_file "$IFACE")" ] || die "no config for $IFACE - is the server installed?"

info "device:    $NAME"
info "interface: $IFACE ($TRANSPORT)"
info "server:    $SERVER_IP"

# ---- refuse duplicates -------------------------------------------------
if [ -f "$KEY_DIR/$NAME.key" ]; then
  die "a key named '$NAME' already exists - use rotate-keys.sh or pick another name"
fi

# ---- addresses ---------------------------------------------------------
USED4=$(used_ip4 "$IFACE")
IP4=$(next_ip "$SUBNET4" "$USED4") || die "no free IPv4 addresses left in $SUBNET4"
IP6="${SUBNET6%::*}::$(echo "$IP4" | awk -F. '{print $NF}')"
info "assigning: $IP4, $IP6"

# ---- keys --------------------------------------------------------------
gen_keypair "$NAME" "$TOOL"
PUB=$(cat "$KEY_DIR/$NAME.pub")
ok "keypair generated"

# ---- register the peer on the RUNNING interface ------------------------
asroot "$TOOL" set "$IFACE" peer "$PUB" allowed-ips "$IP4/32,$IP6/128"
ok "peer registered live (no disruption to connected clients)"

# ---- persist it in the config -----------------------------------------
CFG=$(cfg_file "$IFACE")
TMP=$(mktemp)
asroot cat "$CFG" > "$TMP"
{
  echo ""
  echo "# $NAME"
  echo "[Peer]"
  echo "PublicKey  = $PUB"
  echo "AllowedIPs = $IP4/32, $IP6/128"
} >> "$TMP"
asroot install -m 600 -o root -g root "$TMP" "$CFG"
rm -f "$TMP"
ok "peer persisted to $CFG (survives reboot)"

# ---- client config -----------------------------------------------------
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
CONF="$OUT_DIR/$NAME.conf"

{
  echo "[Interface]"
  echo "PrivateKey = $(cat "$KEY_DIR/$NAME.key")"
  echo "Address    = $IP4/32, $IP6/128"
  echo "DNS        = $DNS"
  # Kill switch: fail closed rather than fall back to open routing.
  echo "includeAllNetworks = true"
  echo "excludeLocalNetworks = false"

  if [ "$TRANSPORT" = "awg" ]; then
    echo ""
    echo "# --- obfuscation: must match the server exactly ---"
    awk '/^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[ \t]*=/' "$AWG_DIR/$AWG_IFACE.conf" 2>/dev/null || true
  fi

  echo ""
  echo "[Peer]"
  echo "PublicKey  = $SERVER_PUB"
  echo "Endpoint   = $SERVER_IP:$PORT"
  if [ "$SPLIT" = "1" ]; then
    echo "# split tunnel: only the VPN subnet is routed, everything else is direct"
    echo "AllowedIPs = $SUBNET4, $SUBNET6"
  else
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
  fi
  echo "PersistentKeepalive = 25"
} > "$CONF"

chmod 600 "$CONF"
qrencode -t png -o "$OUT_DIR/$NAME.png" -r "$CONF"
chmod 600 "$OUT_DIR/$NAME.png"

echo
ok "wrote $CONF"
ok "wrote $OUT_DIR/$NAME.png  (QR)"
warn "the config is the credential - delete it from any chat after importing"
warn "revoke later with: remove-device.sh $NAME"
