#!/usr/bin/env python3
"""Render the vpn-stack architecture diagram to docs/diagrams/architecture.png.

Kept in the repo so the diagram is reproducible rather than a binary someone has
to trust. Run:  python3 docs/diagram.py
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "diagrams", "architecture.png")
os.makedirs(os.path.dirname(OUT), exist_ok=True)

BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

BG, PANEL, BORDER = "#0d1117", "#161b22", "#30363d"
TEXT, MUTED = "#c9d1d9", "#8b949e"
BLUE, PURPLE, GREEN, AMBER = "#58a6ff", "#bc8cff", "#3fb950", "#d29922"

W, H = 1200, 940
img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

f_title = ImageFont.truetype(BOLD, 30)
f_h = ImageFont.truetype(BOLD, 19)
f_b = ImageFont.truetype(REG, 16)
f_s = ImageFont.truetype(REG, 14)
f_m = ImageFont.truetype(MONO, 14)


def box(x1, y1, x2, y2, fill=PANEL, outline=BORDER, width=2, radius=10):
    d.rounded_rectangle([x1, y1, x2, y2], radius=radius, fill=fill,
                        outline=outline, width=width)


def text(x, y, s, font=f_b, fill=TEXT, anchor="la"):
    d.text((x, y), s, font=font, fill=fill, anchor=anchor)


def labelled(x, y, label, value, lab_font=f_h, val_font=f_m,
             lab_fill=TEXT, val_fill=MUTED, gap=18):
    """Label then value on one line, gap measured from the real label width.

    Hardcoded x offsets collide as soon as a label is a character longer than
    expected, and the overflow hides the start of the value.
    """
    text(x, y, label, font=lab_font, fill=lab_fill)
    w = d.textlength(label, font=lab_font)
    text(x + w + gap, y + (lab_font.size - val_font.size) / 2 + 2,
         value, font=val_font, fill=val_fill)


def arrow(x1, y1, x2, y2, fill=MUTED, width=2):
    d.line([x1, y1, x2, y2], fill=fill, width=width)
    import math
    ang = math.atan2(y2 - y1, x2 - x1)
    L, S = 12, math.radians(26)
    d.polygon([(x2, y2),
               (x2 - L * math.cos(ang - S), y2 - L * math.sin(ang - S)),
               (x2 - L * math.cos(ang + S), y2 - L * math.sin(ang + S))], fill=fill)


# ---------------------------------------------------------------- title
text(50, 30, "vpn-stack", font=f_title, fill=TEXT)
text(215, 42, "self-hosted WireGuard + AmneziaWG  ·  no third party in the path",
     font=f_b, fill=MUTED)

# ---------------------------------------------------------------- clients
box(50, 92, 1150, 212)
text(72, 108, "CLIENTS", font=f_h, fill=BLUE)
cw = 250
for i, (name, sub, col) in enumerate([
        ("iPhone · WireGuard", "port 51820 · full tunnel", BLUE),
        ("iPhone · AmneziaWG", "random UDP port · obfuscated", PURPLE),
        ("iPhone · split tunnel", "DNS + ads only", GREEN),
        ("Mac · WireGuard", "full tunnel", BLUE)]):
    x = 72 + i * (cw + 14)
    box(x, 140, x + cw, 194, fill="#0d1117")
    text(x + 14, 152, name, font=f_b, fill=col)
    text(x + 14, 173, sub, font=f_s, fill=MUTED)

arrow(600, 212, 600, 262)
text(614, 228, "encrypted UDP", font=f_s, fill=MUTED)

# ---------------------------------------------------------------- entry vps
box(50, 262, 1150, 686, outline=BLUE, width=3)
text(72, 280, "ENTRY VPS", font=f_h, fill=BLUE)
text(1150 - 20, 284, "kernel WireGuard · 1 public IPv4/IPv6", font=f_s, fill=MUTED, anchor="ra")

# two transports
box(80, 320, 560, 402)
labelled(100, 334, "wg0", "10.66.66.0/24 · fd42:42:42::/64", lab_fill=BLUE)
text(100, 366, "standard transport · in-tree kernel module", font=f_s, fill=TEXT)

box(640, 320, 1120, 402)
labelled(660, 334, "awg0", "10.77.77.0/24 · fd77:77:77::/64", lab_fill=PURPLE)
text(660, 366, "obfuscated · random port · H1-H4, Jc, S1/S2", font=f_s, fill=TEXT)
text(660, 382, "same crypto: Curve25519 · ChaCha20-Poly1305 · Noise IK", font=f_s, fill=MUTED)

arrow(320, 402, 320, 448)
arrow(880, 402, 880, 448)

# dns stack
box(80, 448, 560, 560, fill="#0d1117")
labelled(100, 462, "AdGuard Home", "10.66.66.1:53 · 10.77.77.1:53", lab_fill=GREEN)
text(100, 494, "194k+ ad and tracker rules, applied at the DNS layer", font=f_s, fill=TEXT)
text(100, 514, "so blocking covers every app, not just the browser", font=f_s, fill=MUTED)
text(100, 536, "tunnel IPs only — never an open resolver", font=f_s, fill=MUTED)

arrow(320, 560, 320, 596)

box(80, 596, 560, 664, fill="#0d1117")
labelled(100, 608, "unbound", "127.0.0.1:5335", lab_fill=AMBER)
text(100, 636, "recursive from the root nameservers · DNSSEC validating", font=f_s, fill=TEXT)

# nat / forward
box(640, 448, 1120, 560, fill="#0d1117")
text(660, 462, "NAT + forwarding", font=f_h, fill=TEXT)
text(660, 492, "MASQUERADE on both families, IPv6 included", font=f_s, fill=TEXT)
text(660, 512, "rules inserted at FORWARD position 1 — an appended", font=f_s, fill=MUTED)
text(660, 530, "ACCEPT lands after ufw's routed DROP and never runs", font=f_s, fill=MUTED)

box(640, 596, 1120, 664, fill="#0d1117")
text(660, 608, "Hardening", font=f_h, fill=TEXT)
text(660, 638, "SSH key-only · sysctl · fail2ban · unattended upgrades", font=f_s, fill=TEXT)

arrow(600, 686, 600, 736)

# ---------------------------------------------------------------- exit
box(50, 736, 1150, 830, outline=AMBER, width=2)
text(72, 752, "EXIT VPS  (optional second hop)", font=f_h, fill=AMBER)
text(460, 756, "not built — scripts included, needs a second machine", font=f_s, fill=MUTED)
text(72, 788, "clients exit from a second provider's IP; the entry sees the real client, the",
     font=f_s, fill=TEXT)
text(72, 806, "exit sees only the entry — nothing downstream can correlate the two.",
     font=f_s, fill=TEXT)

arrow(600, 830, 600, 878)
text(614, 846, "internet", font=f_b, fill=MUTED)

img.save(OUT)
print(f"wrote {OUT}  {img.width}x{img.height}")
