#!/usr/bin/env bash
# lib.sh - shared config and helpers for vpn-stack
# Sourced by every script. Never contains secrets.

set -euo pipefail

# ---------------------------------------------------------------- paths
WG_DIR=${WG_DIR:-/etc/wireguard}
AWG_DIR=${AWG_DIR:-/etc/amnezia/amneziawg}
KEY_DIR=${KEY_DIR:-$HOME/.wg-keys}
OUT_DIR=${OUT_DIR:-$HOME/wg-clients}
STATE_DIR=${STATE_DIR:-/var/lib/vpn-stack}

WG_IFACE=${WG_IFACE:-wg0}
AWG_IFACE=${AWG_IFACE:-awg0}

# ---------------------------------------------------------------- subnets
# Deliberately clear of Docker (172.16/12) and Tailscale (100.64/10).
WG_SUBNET4=${WG_SUBNET4:-10.66.66.0/24}
WG_SUBNET6=${WG_SUBNET6:-fd42:42:42::/64}
AWG_SUBNET4=${AWG_SUBNET4:-10.77.77.0/24}
AWG_SUBNET6=${AWG_SUBNET6:-fd77:77:77::/64}

WG_PORT=${WG_PORT:-51820}
AWG_PORT=${AWG_PORT:-41777}

DRY_RUN=${DRY_RUN:-0}

# ---------------------------------------------------------------- output
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
info()    { printf '  %s\n' "$*"; }
ok()      { c_green "  ok  $*"; }
warn()    { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
die()     { c_red "error: $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null \
    || die "this script needs root (or passwordless sudo)"
}

# Run a command as root, honouring DRY_RUN.
asroot() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
  elif [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

# ---------------------------------------------------------------- config I/O
# Read the live config for an interface (handles both wg and awg layouts).
cfg_file() {
  case "$1" in
    "$WG_IFACE")  echo "$WG_DIR/$1.conf" ;;
    "$AWG_IFACE") echo "$AWG_DIR/$1.conf" ;;
    *)            echo "$WG_DIR/$1.conf" ;;
  esac
}

# Print the value of a key from the [Interface] section.
iface_value() {
  local iface="$1" key="$2" f
  f=$(cfg_file "$iface")
  asroot cat "$f" 2>/dev/null | awk -v k="$key" '
    /^\[/      { s = ($0 ~ /^\[Interface\]/) ? "i" : "p" }
    s == "i"   { n = index($0, "=")
                 if (n) { kk = $0; sub(/=.*/, "", kk); gsub(/[ \t]/, "", kk)
                          if (kk == k) { v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/[ \t]+$/, "", v); print v } } }
  ' | tail -1
}

# ---------------------------------------------------------------- peers
# List "name|pubkey|ip4|ip6" for every peer, derived from the config file.
list_peers() {
  local iface="$1" f
  f=$(cfg_file "$iface")
  asroot cat "$f" 2>/dev/null | awk '
    /^#/                                    { name = substr($0, 3); sub(/^[ \t]+/, "", name); next }
    /^\[Peer\]/                             { pk=""; ips=""; next }
    /^[ \t]*PublicKey[ \t]*=/               { v=$0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/[ \t]+$/,"",v); pk=v }
    /^[ \t]*AllowedIPs[ \t]*=/              { if (pk != "") { v=$0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/[ \t]+$/,"",v)
                                                nm = (name == "") ? "unnamed" : name; gsub(/^# /,"",nm)
                                                print nm "|" pk "|" v; pk=""; name="" } }
  '
}

# Is a pubkey already registered on the interface?
peer_exists() {
  local iface="$1" pub="$2"
  asroot wg show "$iface" peers 2>/dev/null | grep -qxF "$pub" && return 0
  asroot awg show "$iface" peers 2>/dev/null | grep -qxF "$pub" && return 0
  return 1
}

# Next free host address in a /24 (or /64) given a list of used ones.
next_ip() {
  local subnet="$1" used_csv="$2" base n
  base=$(echo "$subnet" | cut -d/ -f1)
  base=${base%.*}
  for n in $(seq 2 254); do
    case ",$used_csv," in
      *",${base}.${n},"*) continue ;;
      *) echo "${base}.${n}"; return 0 ;;
    esac
  done
  return 1
}

used_ip4() {
  local iface="$1"
  list_peers "$iface" | cut -d'|' -f3 | tr ',' '\n' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd, -
}

# ---------------------------------------------------------------- keys
gen_keypair() {   # gen_keypair <name> <wg|awg>  -> writes $KEY_DIR/<name>.key/.pub
  local name="$1" tool="${2:-wg}"
  ( umask 077
    "$tool" genkey > "$KEY_DIR/$name.key"
    "$tool" pubkey < "$KEY_DIR/$name.key" > "$KEY_DIR/$name.pub" )
  chmod 600 "$KEY_DIR/$name.key" "$KEY_DIR/$name.pub"
}

# ---------------------------------------------------------------- misc
public_ip4() {
  curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || true
}

reload_iface() {   # reload_iface <iface>
  local iface="$1"
  if [ "$iface" = "$AWG_IFACE" ]; then
    asroot awg-quick strip "$iface" > "/tmp/$iface.stripped" 2>/dev/null \
      && asroot awg setconf "$iface" "/tmp/$iface.stripped" \
      && ok "applied live to $iface"
  else
    asroot wg-quick strip "$iface" > "/tmp/$iface.stripped" 2>/dev/null \
      && asroot wg setconf "$iface" "/tmp/$iface.stripped" \
      && ok "applied live to $iface"
  fi
}
