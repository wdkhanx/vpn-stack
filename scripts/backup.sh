#!/usr/bin/env bash
# backup.sh [--out DIR] [--no-secrets]
#
# Snapshots everything needed to rebuild the server: interface configs, keys,
# sysctl/ssh drop-ins, the AdGuard config, and the firewall rules.
#
# Default output DOES contain private keys. That is deliberate - a backup you
# cannot restore from is not a backup - so it is written 0600 into a 0700 tree
# and you are told to move it somewhere safe. --no-secrets emits a redacted
# copy suitable for archiving next to a repo.
#
set -euo pipefail
source "$(dirname "$0")/lib.sh"

OUT_BASE=${OUT_BASE:-$HOME/vpn-backups}
NO_SECRETS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT_BASE="$1" ;;
    --no-secrets) NO_SECRETS=1 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

STAMP=$(date +%Y%m%d-%H%M%S)
SUFFIX=$([ "$NO_SECRETS" = "1" ] && echo ".redacted" || echo "")
DEST="$OUT_BASE/$STAMP$SUFFIX"
mkdir -p "$DEST"; chmod 700 "$OUT_BASE" "$DEST"

info "destination: $DEST"

# ---------------------------------------------------------------- collect
collect() {   # collect <dest-relative-path> <source>
  local rel="$1" src="$2"
  [ -e "$src" ] || { warn "skip (absent): $src"; return; }
  mkdir -p "$DEST/$(dirname "$rel")"
  if [ "$NO_SECRETS" = "1" ]; then
    asroot cat "$src" 2>/dev/null | sed -E \
      -e 's/^(PrivateKey|PresharedKey)[[:space:]]*=.*/\1 = [REDACTED]/' \
      -e 's/^(password:).*/\1 "[REDACTED]"/' \
      -e 's/(H[1-4]|S[12]|Jc|Jmin|Jmax)[[:space:]]*=.*/\1 = [REDACTED]/' > "$DEST/$rel"
  else
    asroot cat "$src" > "$DEST/$rel"
  fi
  chmod 600 "$DEST/$rel"
}

collect "wireguard/$WG_IFACE.conf"     "$WG_DIR/$WG_IFACE.conf"
collect "amneziawg/$AWG_IFACE.conf"    "$AWG_DIR/$AWG_IFACE.conf"
collect "sysctl/99-wireguard.conf"     "/etc/sysctl.d/99-wireguard.conf"
collect "sysctl/99-hardening.conf"     "/etc/sysctl.d/99-hardening.conf"
collect "ssh/99-vpn-hardening.conf"    "/etc/ssh/sshd_config.d/99-vpn-hardening.conf"
collect "adguard/AdGuardHome.yaml"     "/opt/AdGuardHome/AdGuardHome.yaml"
collect "unbound/99-vpn-recursive.conf" "/etc/unbound/unbound.conf.d/99-vpn-recursive.conf"
collect "fail2ban/jail.local"          "/etc/fail2ban/jail.local"

# keys (never written in the redacted form)
if [ "$NO_SECRETS" = "0" ]; then
  mkdir -p "$DEST/keys"; chmod 700 "$DEST/keys"
  for f in "$KEY_DIR"/*.key "$KEY_DIR"/awg-params.env "$KEY_DIR/agh-password.txt"; do
    [ -e "$f" ] && install -m 600 "$f" "$DEST/keys/$(basename "$f")"
  done
  ok "keys included"
fi

# firewall state - the rollback artefact
asroot iptables-save  > "$DEST/iptables.v4.rules" 2>/dev/null || true
asroot ip6tables-save > "$DEST/iptables.v6.rules" 2>/dev/null || true
asroot ufw status numbered > "$DEST/ufw.status.txt" 2>/dev/null || true
chmod 600 "$DEST"/iptables.* "$DEST"/ufw.* 2>/dev/null || true

# ---------------------------------------------------------------- manifest
{
  echo "vpn-stack backup"
  echo "taken:     $(date -Is)"
  echo "host:      $(hostname)"
  echo "kernel:    $(uname -r)"
  echo "os:        $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "interfaces: $WG_IFACE $AWG_IFACE"
  echo "redacted:  $NO_SECRETS"
  echo
  echo "files:"
  ( cd "$DEST" && find . -type f | sort | sed 's/^/  /' )
} > "$DEST/MANIFEST.txt"
chmod 600 "$DEST/MANIFEST.txt"

echo
ok "backup complete: $DEST"
info "size: $(du -sh "$DEST" | cut -f1)"
[ "$NO_SECRETS" = "0" ] && \
  warn "this copy contains private keys - move it off this host, do not commit it"
exit 0
