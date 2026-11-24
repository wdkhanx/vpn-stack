#!/usr/bin/env bash
# remove-device.sh <name> [--keep-key]
#
# Revokes a device: removes the peer from BOTH the live interface and the config,
# then optionally deletes the local key material. Use this when a device is lost,
# sold, or its config leaked.
#
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need_root

NAME=""; KEEP_KEY=0
for a in "$@"; do
  case "$a" in
    --keep-key) KEEP_KEY=1 ;;
    *)          NAME="$a" ;;
  esac
done
[ -n "$NAME" ] || die "usage: remove-device.sh <name> [--keep-key]"

[ -f "$KEY_DIR/$NAME.pub" ] || die "no key named '$NAME' in $KEY_DIR"
PUB=$(cat "$KEY_DIR/$NAME.pub")

REMOVED=0
for pair in "$WG_IFACE wg" "$AWG_IFACE awg"; do
  set -- $pair; IFACE=$1; TOOL=$2
  [ -f "$(cfg_file "$IFACE")" ] || continue

  if asroot "$TOOL" show "$IFACE" peers 2>/dev/null | grep -qxF "$PUB"; then
    asroot "$TOOL" set "$IFACE" peer "$PUB" remove
    ok "revoked live on $IFACE"
    REMOVED=1
  fi

  # strip the peer block from the config, however it is labelled
  CFG=$(cfg_file "$IFACE")
  TMP=$(mktemp)
  asroot cat "$CFG" > "$TMP"
  /usr/bin/python3 - "$TMP" "$PUB" <<'PY'
import sys
path, pub = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
out, buf, drop = [], [], False
for ln in lines:
    if ln.strip() == '[Peer]':
        if buf and not drop:
            out.extend(buf)
        buf, drop = [ln], False
    elif buf is not None and ln.startswith('#') and not buf:
        buf.append(ln)
    else:
        buf.append(ln)
        if ln.strip().startswith('PublicKey') and pub in ln:
            drop = True
if buf and not drop:
    out.extend(buf)
# collapse the trailing blank lines left behind
text = '\n'.join(out)
while '\n\n\n\n' in text:
    text = text.replace('\n\n\n\n', '\n\n\n')
open(path, 'w').write(text.strip('\n') + '\n')
PY
  asroot install -m 600 -o root -g root "$TMP" "$CFG"
  rm -f "$TMP"
  ok "removed from $CFG"
done

[ "$REMOVED" = "1" ] || warn "peer was not active on any interface (already gone?)"

if [ "$KEEP_KEY" = "0" ]; then
  for f in "$KEY_DIR/$NAME.key" "$KEY_DIR/$NAME.pub" "$OUT_DIR/$NAME.conf" "$OUT_DIR/$NAME.png"; do
    [ -e "$f" ] && mv "$f" "$f.revoked.$(date +%s)" && info "retired $(basename "$f")"
  done
  info "(moved aside rather than deleted, in case you need them)"
fi

echo
ok "device '$NAME' revoked"
warn "if that config leaked, rotate the SERVER key too - it is the only way to"
warn "invalidate a config that is already in someone else's hands"
