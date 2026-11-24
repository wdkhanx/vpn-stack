#!/usr/bin/env bash
# enable-multihop.sh --exit-ip <ip> --exit-pub <key> [--off]
#
# RUN ON THE ENTRY SERVER. Creates wg1 to the exit hop and moves client traffic
# onto it, so your clients exit from the second server's IP instead of this one.
#
#     before:  client -> ENTRY -> internet            (entry's IP is your exit)
#     after:   client -> ENTRY -> EXIT -> internet    (exit's IP is your exit)
#
# Reversible: --off tears wg1 down and restores direct routing. Nothing here
# touches the client configs, so devices never need re-importing.
#
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need_root

EXIT_IP=""; EXIT_PUB=""; TURN_OFF=0
EXIT_SUBNET4=${EXIT_SUBNET4:-10.99.99.0/24}
EXIT_ADDR=${EXIT_ADDR:-10.99.99.1}
ENTRY_ADDR=${ENTRY_ADDR:-10.99.99.2}
EXIT_PORT=${EXIT_PORT:-51820}
TABLE=100
WAN_IF=$(ip route show default | awk '{print $5; exit}')

while [ $# -gt 0 ]; do
  case "$1" in
    --exit-ip)  shift; EXIT_IP="$1" ;;
    --exit-pub) shift; EXIT_PUB="$1" ;;
    --off)      TURN_OFF=1 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

# ================================================================ tear down
if [ "$TURN_OFF" = "1" ]; then
  info "reverting to single-hop"
  asroot wg-quick down wg1 2>/dev/null || true
  for src in "$WG_SUBNET4" "$AWG_SUBNET4"; do
    asroot ip rule del from "$src" table $TABLE 2>/dev/null || true
  done
  asroot ip route flush table $TABLE 2>/dev/null || true
  # put the client NAT back on eth0
  for src in "$WG_SUBNET4" "$AWG_SUBNET4"; do
    asroot iptables -t nat -C POSTROUTING -s "$src" -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
      || asroot iptables -t nat -A POSTROUTING -s "$src" -o "$WAN_IF" -j MASQUERADE
  done
  ok "clients now exit directly from this server"
  exit 0
fi

[ -n "$EXIT_IP" ]  || die "--exit-ip is required (or use --off to disable)"
[ -n "$EXIT_PUB" ] || die "--exit-pub is required (or use --off to disable)"

info "entry:  $WAN_IF -> exit $EXIT_IP:$EXIT_PORT"

# ---------------------------------------------------------------- entry keypair
mount | grep -q "^tmpfs on $WG_DIR" 2>/dev/null || true
[ -f "$WG_DIR/wg1.key" ] || { umask 077; asroot sh -c "wg genkey > $WG_DIR/wg1.key"; }
asroot sh -c "wg pubkey < $WG_DIR/wg1.key" > /tmp/wg1.pub
info "entry pubkey: $(cat /tmp/wg1.pub)"
info "  ^ register this on the exit node if you have not already"

# ---------------------------------------------------------------- wg1 config
asroot tee "$WG_DIR/wg1.conf" > /dev/null <<EOF
# Second hop: the entry server dials the exit node.
# Table=off because routing into the tunnel is done by policy below, not by
# replacing the default route (which would cut off our own management access).
[Interface]
Address    = ${ENTRY_ADDR}/32
PrivateKey = $(asroot cat "$WG_DIR/wg1.key")
Table      = off
MTU        = 1380

# NAT the client subnets to our tunnel address before they enter the exit
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET4}  -o %i -j MASQUERADE
PostUp   = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET4} -o %i -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET4}  -o %i -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET4} -o %i -j MASQUERADE

[Peer]
PublicKey           = ${EXIT_PUB}
Endpoint            = ${EXIT_IP}:${EXIT_PORT}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
EOF
asroot chmod 600 "$WG_DIR/wg1.conf"
ok "wrote $WG_DIR/wg1.conf"

# ---------------------------------------------------------------- bring up
asroot wg-quick down wg1 >/dev/null 2>&1 || true
asroot wg-quick up wg1
ok "wg1 up"

# ---------------------------------------------------------------- policy routing
# Client traffic is sent to the exit's table; everything ORIGINATING on this
# server keeps the normal default route, so SSH and the agent never drop.
add_policy_routes() {
  for src in "$WG_SUBNET4" "$AWG_SUBNET4"; do
    ip rule del from "$src" table $TABLE 2>/dev/null || true
    ip rule add from "$src" table $TABLE
  done
  ip route replace default dev wg1 table $TABLE
  ip route replace "$EXIT_SUBNET4" dev wg1 table $TABLE 2>/dev/null || true
}
add_policy_routes
ok "policy routing installed (table $TABLE)"

# ---------------------------------------------------------------- swap the client NAT
# Client traffic now leaves via wg1, so the eth0 MASQUERADE from the first-hop
# setup would either miss or double-NAT. Point each client subnet at wg1.
for src in "$WG_SUBNET4" "$AWG_SUBNET4"; do
  asroot iptables -t nat -D POSTROUTING -s "$src" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
  asroot iptables -t nat -C POSTROUTING -s "$src" -o wg1 -j MASQUERADE 2>/dev/null \
    || asroot iptables -t nat -A POSTROUTING -s "$src" -o wg1 -j MASQUERADE
done
ok "client NAT now egresses through wg1"

# ---------------------------------------------------------------- persist
# wg1 is enabled at boot, so its own PostUp is the right place for the policy
# routing - that way `wg-quick up wg1` fully reconstructs the chain.
asroot tee "$WG_DIR/wg1.conf" > /dev/null <<EOF
# Second hop: the entry server dials the exit node.
# Table=off because routing into the tunnel is done by policy below, not by
# replacing the default route (which would cut off our own management access).
[Interface]
Address    = ${ENTRY_ADDR}/32
PrivateKey = $(asroot cat "$WG_DIR/wg1.key")
Table      = off
MTU        = 1380

PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET4}  -o %i -j MASQUERADE
PostUp   = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET4} -o %i -j MASQUERADE
PostUp   = ip rule add from ${WG_SUBNET4}  table ${TABLE}
PostUp   = ip rule add from ${AWG_SUBNET4} table ${TABLE}
PostUp   = ip route replace default dev %i table ${TABLE}
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET4}  -o %i -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET4} -o %i -j MASQUERADE
PostDown = ip rule del from ${WG_SUBNET4}  table ${TABLE}
PostDown = ip rule del from ${AWG_SUBNET4} table ${TABLE}
PostDown = ip route flush table ${TABLE}

[Peer]
PublicKey           = ${EXIT_PUB}
Endpoint            = ${EXIT_IP}:${EXIT_PORT}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
EOF
asroot chmod 600 "$WG_DIR/wg1.conf"
asroot systemctl enable wg-quick@wg1 >/dev/null 2>&1 || true
ok "multihop persisted (wg1 enabled at boot)"

echo
ok "MULTI-HOP ACTIVE"
info "your clients now exit from $EXIT_IP"
info "verify:  ./status.sh   then check a device reports the EXIT's IP"
info "revert:  ./enable-multihop.sh --off"
