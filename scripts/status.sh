#!/usr/bin/env bash
# status.sh - one-screen health report for the whole stack.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

hr() { printf '%s\n' "------------------------------------------------------------"; }

echo
c_blue "vpn-stack status"
hr

# ---------------------------------------------------------------- services
printf '%-22s %-10s %s\n' "SERVICE" "STATE" "ENABLED AT BOOT"
for u in "wg-quick@$WG_IFACE" "awg-quick@$AWG_IFACE" "AdGuardHome" "unbound" "fail2ban" "unattended-upgrades"; do
  st=$(systemctl is-active "$u" 2>/dev/null || true)
  en=$(systemctl is-enabled "$u" 2>/dev/null || true)
  [ "$st" = "active" ] && st=$(printf '\033[32m%s\033[0m' "$st") || st=$(printf '\033[31m%s\033[0m' "${st:-missing}")
  printf '%-22s %-19b %s\n' "$u" "$st" "$en"
done
hr

# ---------------------------------------------------------------- interfaces
for pair in "$WG_IFACE wg" "$AWG_IFACE awg"; do
  set -- $pair; IFACE=$1; TOOL=$2
  [ -d "/sys/class/net/$IFACE" ] || { warn "$IFACE: not present"; continue; }
  echo
  c_blue "$IFACE"
  ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print "  addr4: "$2}'
  ip -6 addr show "$IFACE" 2>/dev/null | awk '/inet6/{print "  addr6: "$2}'
  asroot $TOOL show "$IFACE" 2>/dev/null | sed -n 's/^  listening port: /  port:  /p' | sed 's/^/  /'
  # obfuscation proof for the AmneziaWG side
  if [ "$TOOL" = "awg" ]; then
    asroot awg show "$IFACE" 2>/dev/null | awk '/^  (jc|jmin|jmax|s1|s2):/{printf "  obf%s: %s\n", $1, $2}' | tr -d ':' | sed 's/obf  /obf /'
  fi
done
hr

# ---------------------------------------------------------------- peers
for IFACE in "$WG_IFACE" "$AWG_IFACE"; do
  [ -d "/sys/class/net/$IFACE" ] || continue
  echo
  c_blue "peers on $IFACE"
  printf '  %-22s %-16s %-22s %s\n' "NAME" "INNER IP" "LAST HANDSHAKE" "TRANSFER"
  live=$([ "$IFACE" = "$AWG_IFACE" ] && echo awg || echo wg)
  list_peers "$IFACE" | while IFS='|' read -r nm pk ips; do
    ip4=$(echo "$ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    hs=$(asroot $live show "$IFACE" dump 2>/dev/null | awk -v k="$pk" '$1==k {
           if ($5 == 0) print "never"; else {
             d = systime() - $5
             if (d < 60)   printf "%ds ago\n", d
             else if (d < 3600) printf "%dm ago\n", int(d/60)
             else printf "%dh ago\n", int(d/3600)
           }}')
    tr_=$(asroot $live show "$IFACE" dump 2>/dev/null | awk -v k="$pk" '$1==k {printf "%.1f/%.1f MiB", $6/1048576, $7/1048576}')
    printf '  %-22s %-16s %-22s %s\n' "$nm" "${ip4:--}" "${hs:-?}" "${tr_:-0/0 MiB}"
  done
done
hr

# ---------------------------------------------------------------- DNS
echo
c_blue "DNS / blocking"
if systemctl is-active --quiet AdGuardHome 2>/dev/null; then
  info "listening: $(ss -ulpnH 2>/dev/null | awk '/AdGuardHome/ && /:53 /{print $4}' | paste -sd' ' -)"
  PW=$(cat "$KEY_DIR/agh-password.txt" 2>/dev/null || true)
  UI=$(tailscale ip -4 2>/dev/null | head -1 || true)
  UI=${UI:-127.0.0.1}
  if [ -n "$PW" ]; then
    curl -s -u "admin:$PW" "http://${UI}:3000/control/stats" 2>/dev/null \
      | /usr/bin/python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('  queries:      %s' % d.get('num_dns_queries', 0))
    print('  blocked:      %s (%.1f%%)' % (d.get('num_blocked_filtering', 0),
          100.0 * d.get('num_blocked_filtering',0) / max(d.get('num_dns_queries',1),1)))
    print('  avg latency:  %sms' % (d.get('avg_processing_time', 0) / 1e6).__round__(1))
except Exception:
    print('  (stats endpoint on the tailnet address only)')
" 2>/dev/null || info "(stats unavailable over loopback - UI is bound to the tailnet IP)"
  fi
else
  warn "AdGuardHome not running"
fi
hr

# ---------------------------------------------------------------- firewall
echo
c_blue "firewall"
sudo -n ufw status 2>/dev/null | grep -E "^(To|--|[0-9])" | head -14 | sed 's/^/  /'
hr
echo
info "web UI:  http://$(tailscale ip -4 2>/dev/null | head -1):3000  (tailnet only)"
echo
