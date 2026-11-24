# Verification and benchmarks

Every number here was produced by a command in this repo, on a real deployment.
Methods are included so anyone can reproduce them — the method is the useful part.

## Egress proof (no client required)

The cheapest real proof that forwarding and NAT work: egress from the tunnel's own
source address and see which address the internet reports.

```bash
curl -4 --interface 10.66.66.1    -s --max-time 12 ifconfig.me   # -> server public IPv4
curl -6 --interface fd42:42:42::1 -s --max-time 12 ifconfig.me   # -> server public IPv6
curl -4 --interface 10.77.77.1    -s --max-time 12 ifconfig.me   # AmneziaWG subnet
curl -6 --interface fd77:77:77::1 -s --max-time 12 ifconfig.me
```

**Run both families.** The IPv4 test passes happily while IPv6 is still wide open — an
IPv4-only `AllowedIPs` leaks the client's IPv6 traffic straight out the local network.
A tunnel that looks healthy and silently leaks is the single most common
self-hosted VPN fault.

Observed: all four return the server's public addresses. Pass.

## Confirming the obfuscation is actually applied

```bash
awg show awg0 | grep -E 'jc|jmin|jmax|s1|s2'
```

Observed:

```
jc 7 · jmin 59 · jmax 86 · s1 132 · s2 150
```

Plain WireGuard sends a handshake of a fixed 148 bytes with a message-type byte of
`1`, and every data packet carries a type in 1–4. One DPI rule matches that. AmneziaWG
draws those values from ranges unique to the deployment, so **there is no universal rule
to write** — two installations do not look alike.

## Client-side proof

The only definitive test is a real device. `wg show` / `awg show` on the server gives it:

```bash
sudo wg show wg0 dump | awk 'NR>1 {print $1, $5, $6, $7}'   # peer, handshake, rx, tx
```

A non-zero `latest handshake` plus a growing transfer counter means the tunnel is live.
Observed on the AmneziaWG profile: ~991 MiB carried without a reconnect.

## MTU and the padding cost

AmneziaWG pads packet content, so WireGuard's default MTU of 1420 can exceed the path MTU
once padding is added. The outer packet is:

```
outer = inner MTU + 20 (IPv4) + 8 (UDP) + 16 (WG tag) + AWG padding
```

The cost of lowering it, measured:

```
MTU   on-wire/pkt   packets per GB   wire per GB   efficiency
1420     1464 B        704,225         1.031 GB      96.99%
1380     1424 B        724,638         1.032 GB      96.91%

throughput cost of 1420 -> 1380 : 0.087%
extra packets                   : +2.90%
IPv6 floor (1280) headroom      : 100 B
```

**0.087% is the entire downside.** Symptom that justifies doing it: small transfers fine,
large downloads or video stall with no error — the "PMTU blackhole" pattern.

## DNS resolution path

```bash
dig +short @10.66.66.1 example.com A            # resolves
dig +short @10.66.66.1 ads.doubleclick.net A    # -> 0.0.0.0, blocked
dig @127.0.0.1 -p 5335 dnssec-failed.org A      # SERVFAIL, DNSSEC is validating
dig @127.0.0.1 -p 5335 cloudflare.com A         # NOERROR
```

Proving no third party is in the path:

```bash
ss -tnp | grep -E '1\.1\.1\.1|8\.8\.8\.8|1\.0\.0\.1'   # expect nothing
unbound-control stats_noreset | grep total.num.queries # counter moves on each query
```

Observed: no established connections to any public DoH endpoint, and unbound's query
counter increments with each lookup — so the recursive resolver is the one answering.

## What was NOT measured

Stated plainly rather than implied:

- **Throughput on a real client path.** Measured on the server, not across a mobile
  network, so the 0.087% figure is arithmetic on packet sizes, not an iperf result over LTE.
- **Whether fragmentation is actually occurring.** Depends on the path between a given
  phone and the server, which cannot be probed from the server side.
- **Multi-hop latency.** Not built (needs a second VPS).
