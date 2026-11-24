#!/usr/bin/env bash
# test-device.sh [name ...] [--all] [--keep]
#
# Proves a device config ACTUALLY PASSES TRAFFIC, from the server, without the
# device. It builds that device's tunnel inside an isolated network namespace,
# routes through it, and checks the internet reports the server's address.
#
#   status.sh  -> "this peer is registered and last handshook 4m ago"
#   test-device.sh -> "this config exits through this server, right now"
#
# Those are different claims. A peer can be registered, handshake, and still not
# forward - a broken NAT rule, a missing sysctl, an appended FORWARD rule that
# lands after ufw's DROP. This catches that. Run it before handing anyone a QR.
#
# The namespace is destroyed on exit, including on failure or Ctrl-C.
#
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need_root

KEEP=0; NAMES=()
for a in "$@"; do
  case "$a" in
    --all)  ;;
    --keep) KEEP=1 ;;
    -*)     die "unknown flag: $a" ;;
    *)      NAMES+=("$a") ;;
  esac
done

# ---------------------------------------------------------------- pick devices
if [ ${#NAMES[@]} -eq 0 ]; then
  mapfile -t NAMES < <(ls "$OUT_DIR"/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
fi
[ ${#NAMES[@]} -gt 0 ] || die "no configs in $OUT_DIR - generate one with add-device.sh first"

WAN_IF=$(ip route show default | awk '{print $5; exit}')
PUB4=$(public_ip4)
[ -n "$PUB4" ] || die "cannot determine the public IPv4"
PUB6=$(curl -6 -s --max-time 10 ifconfig.me 2>/dev/null || true)

NS_BASE=vpnst
VETH_H=vpnst-h
HOST_ADDR=10.200.99.1
NS_ADDR=10.200.99.2
FAILED=0

cleanup() {
  [ "$KEEP" = "1" ] && { warn "keeping namespaces for inspection"; return; }
  for ns in $(ip netns list 2>/dev/null | awk '{print $1}' | grep "^${NS_BASE}" || true); do
    ip netns del "$ns" 2>/dev/null || true
  done
  ip link del "$VETH_H" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- one device
test_one() {
  local name="$1"
  local conf="$OUT_DIR/$name.conf"
  [ -f "$conf" ] || { warn "$name: no config at $conf"; return 1; }

  # transport is implied by the config content
  local tool iface stage_dir ns
  if grep -qE '^\s*(Jc|Jmin|Jmax|S1|S2|H[1-4])\s*=' "$conf"; then
    tool=awg; stage_dir="$AWG_DIR"; iface="awgt"
  else
    tool=wg;  stage_dir="$WG_DIR";  iface="wgt"
  fi
  ns="${NS_BASE}-$(echo "$name" | tr -c 'a-zA-Z0-9' '-' | cut -c1-12)"

  echo
  c_blue "$name  ($tool, interface $iface in netns $ns)"

  # --- config must be readable by root from a system path ---
  # (wg setconf as root cannot read from a user's home directory: fopen permission denied)
  asroot mkdir -p "$stage_dir"
  asroot install -m 600 -o root -g root "$conf" "$stage_dir/$iface.conf"

  local cfg_addr cfg_dns cfg_allowed full_tunnel
  cfg_addr=$(awk -F= '/^Address/{gsub(/ /,"",$2); print $2; exit}' "$conf")
  cfg_dns=$(awk -F= '/^DNS/{gsub(/ /,"",$2); print $2; exit}' "$conf")
  cfg_allowed=$(awk -F= '/^AllowedIPs/{gsub(/ /,"",$2); print $2; exit}' "$conf")
  # A split-tunnel profile deliberately routes only the VPN subnet, so a general
  # egress check would fail on a config that is behaving exactly as designed.
  case "$cfg_allowed" in
    *0.0.0.0/0*) full_tunnel=1 ;;
    *)           full_tunnel=0 ;;
  esac
  [ "$full_tunnel" = "1" ] || info "split tunnel (AllowedIPs=$cfg_allowed) - checking reachability only"

  # --- isolated namespace + a path back to this host ---
  ip netns del "$ns" 2>/dev/null || true
  ip netns add "$ns"
  ip link del "$VETH_H" 2>/dev/null || true
  ip link add "$VETH_H" type veth peer name "${VETH_H}-n"
  ip link set "${VETH_H}-n" netns "$ns"
  ip addr add "$HOST_ADDR/24" dev "$VETH_H"
  ip link set "$VETH_H" up
  ip netns exec "$ns" ip addr add "$NS_ADDR/24" dev "${VETH_H}-n"
  ip netns exec "$ns" ip link set "${VETH_H}-n" up
  ip netns exec "$ns" ip link set lo up
  # specific route to the server's public IP over the veth, so the tunnel's own
  # endpoint does not get captured by the default route we are about to add
  ip netns exec "$ns" ip route add "$PUB4/32" via "$HOST_ADDR"

  # --- per-namespace resolv.conf so DNS is tested through the tunnel, not the host's ---
  mkdir -p "/etc/netns/$ns"
  [ -n "$cfg_dns" ] && echo "nameserver ${cfg_dns%%,*}" > "/etc/netns/$ns/resolv.conf"

  # --- build the client tunnel inside the namespace ---
  # setconf accepts ONLY wg-native keys. Address, DNS, MTU and Table are wg-quick
  # directives and make it fail with a hard parse error - use `strip`, which
  # converts the one form to the other. That is what wg-quick does internally.
  "${tool}-quick" strip "$stage_dir/$iface.conf" > "$stage_dir/$iface-native.conf"
  chmod 600 "$stage_dir/$iface-native.conf"

  # AmneziaWG registers its own rtnl link kind (`rtnl-link-amneziawg`). Creating
  # a plain `wireguard` interface and then calling `awg setconf` fails with
  # "Unable to modify interface: Operation not supported" - the obfuscation
  # attributes do not exist on a stock wireguard device.
  local linkkind=wireguard
  [ "$tool" = "awg" ] && linkkind=amneziawg

  ip netns exec "$ns" ip link add "$iface" type "$linkkind"
  ip netns exec "$ns" $tool setconf "$iface" "$stage_dir/$iface-native.conf"

  # bring the link up FIRST: routes added while it is down are rejected
  local cfg_addr6
  cfg_addr6=$(echo "$cfg_addr" | cut -d, -f2)
  ip netns exec "$ns" ip link set "$iface" up
  ip netns exec "$ns" ip -4 addr add "${cfg_addr%%,*}" dev "$iface"
  if [ -n "$cfg_addr6" ]; then
    ip netns exec "$ns" ip -6 addr add "$cfg_addr6" dev "$iface"
  fi
  ip netns exec "$ns" ip route add default dev "$iface"
  if [ -n "$cfg_addr6" ]; then
    ip netns exec "$ns" ip -6 route add default dev "$iface" 2>/dev/null \
      || info "no IPv6 default route in the namespace"
  fi

  local ok=0

  # ---------------------------------------------------------- check 1: handshake
  local hs=""
  for _ in $(seq 1 10); do
    sleep 1
    hs=$(ip netns exec "$ns" $tool show "$iface" 2>/dev/null | awk '/latest handshake/{print $3, $4, $5}')
    [ -n "$hs" ] && break
  done
  if [ -n "$hs" ]; then ok "handshake completed ($hs)"
  else warn "no handshake after 10s"; fi

  # ---------------------------------------------------------- check 2: egress
  if [ "$full_tunnel" = "1" ]; then
    local seen
    seen=$(ip netns exec "$ns" curl -4 -s --max-time 15 ifconfig.me 2>/dev/null || true)
    if [ "$seen" = "$PUB4" ]; then
      ok "traffic exits through this server ($seen)"
    else
      warn "egress mismatch: got '${seen:-nothing}', expected $PUB4"
      ok=1
    fi
  else
    # split tunnel: prove the tunnel itself is reachable, which is its whole job
    local srv_inner
    srv_inner=$(awk -F= '/^Address/{gsub(/ /,"",$2); print $2; exit}' \
                "$(cfg_file "$WG_IFACE")" | cut -d/ -f1)
    if ip netns exec "$ns" ping -c 2 -W 3 "$srv_inner" >/dev/null 2>&1; then
      ok "tunnel reachable inside the namespace (ping $srv_inner)"
    else
      warn "cannot reach the server's tunnel address ($srv_inner)"
      ok=1
    fi
  fi

  # ---------------------------------------------------------- check 3: DNS + blocking
  # Only accept something that actually looks like an answer - dig can put an
  # error string on stdout, and a non-empty check would score that as a pass.
  if [ -n "$cfg_dns" ]; then
    local resolved blocked
    resolved=$(ip netns exec "$ns" dig +short +timeout=6 +tries=1 example.com A 2>/dev/null \
               | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1 || true)
    if [ -n "$resolved" ]; then
      ok "DNS resolves via ${cfg_dns%%,*} ($resolved)"
    else
      warn "DNS did not resolve via ${cfg_dns%%,*}"; ok=1
    fi

    blocked=$(ip netns exec "$ns" dig +short +timeout=6 +tries=1 ads.doubleclick.net A 2>/dev/null \
              | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1 || true)
    if [ "$blocked" = "0.0.0.0" ]; then
      ok "blocklist active (ads.doubleclick.net -> 0.0.0.0)"
    elif [ -z "$blocked" ]; then
      info "ads.doubleclick.net returned no answer - blocked or unreachable"
    else
      info "blocklist not filtering this name (-> $blocked) - expected if AdGuard is absent"
    fi
  fi

  # ---------------------------------------------------------- check 4: IPv6
  if [ -n "$PUB6" ]; then
    local seen6
    seen6=$(ip netns exec "$ns" curl -6 -s --max-time 12 ifconfig.me 2>/dev/null || true)
    if [ "$seen6" = "$PUB6" ]; then ok "IPv6 also exits here ($seen6)"
    elif [ -z "$seen6" ]; then info "no IPv6 through the tunnel (acceptable if unused)"
    else warn "IPv6 exit mismatch: got '$seen6', expected $PUB6"; ok=1; fi
  fi

  # transfer counters are the tie-breaker when egress failed
  local rx tx
  rx=$(ip netns exec "$ns" $tool show "$iface" transfer 2>/dev/null | awk '{print $2; exit}')
  tx=$(ip netns exec "$ns" $tool show "$iface" transfer 2>/dev/null | awk '{print $3; exit}')
  info "client counters: rx=${rx:-0} tx=${tx:-0} bytes"

  [ "$ok" = "0" ] && c_green "  PASS" || { c_red "  FAIL"; FAILED=1; }

  if [ "$KEEP" = "0" ]; then
    ip netns del "$ns" 2>/dev/null || true
    ip link del "$VETH_H" 2>/dev/null || true
    asroot rm -f "$stage_dir/$iface.conf"
    rmdir "/etc/netns/$ns" 2>/dev/null || true
  fi
  return "$ok"
}

# ---------------------------------------------------------------- run
echo
c_blue "vpn-stack device test"
info "server:   $PUB4  (via $WAN_IF)"
info "devices:  ${NAMES[*]}"
info "method:   a real tunnel in an isolated network namespace"
hr() { printf '%s\n' "------------------------------------------------------------"; }
hr

for n in "${NAMES[@]}"; do
  test_one "$n" || true
done

hr
if [ "$FAILED" = "0" ]; then
  c_green "all devices pass"
else
  c_red "one or more devices FAILED"
  echo "  see docs/troubleshooting.md - 'Peers handshake fine, zero traffic flows'"
fi
echo
exit "$FAILED"
