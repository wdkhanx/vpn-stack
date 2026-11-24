#!/usr/bin/env bash
# deploy-exit-node.sh - RUN THIS ON THE SECOND VPS (the exit hop)
#
# Turns a fresh Debian/Ubuntu box into the far end of a two-hop chain:
#
#     client -> ENTRY (your main server) -> EXIT (this box) -> internet
#
# Why bother: your entry server sees the client's real IP, and this box sees only
# the entry's tunnel address. Nobody downstream can correlate who you are with
# where you exit - not the exit provider, not a site, not your VPS host.
#
# Usage, on the NEW box:
#     sudo ./deploy-exit-node.sh --entry-pub "<entry-tunnel-pubkey>"
#
# It prints the [Peer] block to paste into the ENTRY's wg1.conf, plus the exact
# command to finish the job there.
#
set -euo pipefail

EXIT_SUBNET4=${EXIT_SUBNET4:-10.99.99.0/24}
EXIT_PORT=${EXIT_PORT:-51820}
EXIT_ADDR=${EXIT_ADDR:-10.99.99.1}
ENTRY_ADDR=${ENTRY_ADDR:-10.99.99.2}
ENTRY_PUB=""
WAN_IF=$(ip route show default | awk '{print $5; exit}')

while [ $# -gt 0 ]; do
  case "$1" in
    --entry-pub) shift; ENTRY_PUB="$1" ;;
    --port)      shift; EXIT_PORT="$1" ;;
    --wan)       shift; WAN_IF="$1" ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

say() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$(systemd-detect-virt 2>/dev/null || echo none)" != "docker" ] \
  || die "this needs a real VM, not a container"
[ -n "$WAN_IF" ] || die "could not detect the default interface"
[ -n "$ENTRY_PUB" ] || die "--entry-pub is required (from: wg pubkey < entry.key)"

say "exit node setup"
say "  wan interface : $WAN_IF"
say "  tunnel subnet : $EXIT_SUBNET4"
say "  listen port   : $EXIT_PORT"
echo

# ---------------------------------------------------------------- packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools qrencode >/dev/null
say "wireguard installed"

# ---------------------------------------------------------------- firewall backup
iptables-save > "$HOME/iptables-backup-$(date +%F-%H%M).rules"
say "firewall state backed up"

# ---------------------------------------------------------------- keys
umask 077
mkdir -p /etc/wireguard
[ -f /etc/wireguard/exit.key ] || wg genkey > /etc/wireguard/exit.key
wg pubkey < /etc/wireguard/exit.key > /etc/wireguard/exit.pub
EXIT_PRIV=$(cat /etc/wireguard/exit.key)
EXIT_PUB=$(cat /etc/wireguard/exit.pub)

# ---------------------------------------------------------------- forwarding
sysctl -q -w net.ipv4.ip_forward=1
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-exit-node.conf

# ---------------------------------------------------------------- config
cat > "/etc/wireguard/wg-exit.conf" <<EOF
# Exit node - the far end of a two-hop chain.
[Interface]
Address    = ${EXIT_ADDR}/24
ListenPort = ${EXIT_PORT}
PrivateKey = ${EXIT_PRIV}

PostUp   = iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -s ${EXIT_SUBNET4} -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${EXIT_SUBNET4} -o ${WAN_IF} -j MASQUERADE

[Peer]
# entry hop
PublicKey  = ${ENTRY_PUB}
AllowedIPs = ${ENTRY_ADDR}/32
EOF
chmod 600 /etc/wireguard/wg-exit.conf

systemctl enable --now "wg-quick@wg-exit" >/dev/null 2>&1

# open the port if ufw is in charge
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${EXIT_PORT}"/udp >/dev/null 2>&1 || true
  say "ufw: allowed ${EXIT_PORT}/udp"
fi

EXIT_PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me || true)

# ---------------------------------------------------------------- hand-off
cat <<EOF

  ================================================================
  EXIT NODE IS UP
  ================================================================
  public IP     : ${EXIT_PUBLIC_IP}
  public key    : ${EXIT_PUB}
  listen port   : ${EXIT_PORT}
  tunnel address: ${EXIT_ADDR}

  Now generate the entry-side key ON THE ENTRY and register it here:

    # --- on the ENTRY server ---
    sudo wg genkey > /etc/wireguard/wg1.key
    sudo wg pubkey < /etc/wireguard/wg1.key > /etc/wireguard/wg1.pub
    sudo cat /etc/wireguard/wg1.pub
    # paste that value back here:

    # --- back on THIS exit node ---
    sudo wg set wg-exit peer <ENTRY_PUBKEY> allowed-ips ${ENTRY_ADDR}/32
    sudo wg-quick save wg-exit

    # --- then on the ENTRY, finish the chain ---
    sudo ./enable-multihop.sh --exit-ip ${EXIT_PUBLIC_IP} --exit-pub ${EXIT_PUB}

  Remember to open ${EXIT_PORT}/udp in the exit provider's OWN cloud firewall
  (Hetzner/DO/AWS all have one in front of the VM, separate from ufw).
  ================================================================
EOF
