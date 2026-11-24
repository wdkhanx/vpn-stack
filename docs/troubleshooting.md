# Troubleshooting

Failures that cost real time. Each one presents as something other than its cause.

## The client rejects a config that looks correct

**Symptom:** the WireGuard app says "not a valid configuration" on a config that was
working previously.

**Cause:** an app-level key was added to the `[Interface]` block. `includeAllNetworks`
and `excludeLocalNetworks` are **Apple NetworkExtension API properties**, not WireGuard
config-file keys — they appear in every iOS VPN tutorial and in Apple's own docs, which
makes them look like config options. They are not. The app parses the file, hits the
unknown key, and refuses the whole profile.

**Fix:** ship the minimal form. Enable leak protection in the app's own settings if needed.

```ini
[Interface]
PrivateKey = ...
Address    = 10.66.66.2/32, fd42:42:42::2/128
DNS        = 10.66.66.1
```

**Diagnostic instinct:** if the config worked and then you added a line for a feature the
user did not ask for, revert to the last known-good shape *before* investigating anything
else. The diff is the answer.

## The tunnel dies after a reboot, and the config looks perfect

**Symptom:** everything works, then after a reboot the tunnel is gone with no error.

**Two independent causes — check both.**

**1. The unit was never enabled.** `wg-quick up` does not persist:

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl is-enabled wg-quick@wg0   # must say "enabled", verify it as a step
```

**2. AmneziaWG's DKMS module is built for the wrong kernel.** This is the subtler one.
`apt-get install amneziawg-dkms` pulls headers for the *newest available* kernel, which is
often not the running one and may not be the one that boots:

```bash
dkms status                                    # shows which kernels got a build
uname -r                                       # what is running
grep GRUB_DEFAULT /etc/default/grub; ls /boot/vmlinuz-*   # what will BOOT
```

If those disagree, the tunnel survives today and vanishes on reboot:

```bash
sudo apt-get install -y linux-headers-$(uname -r)
sudo dkms install amneziawg/1.0.0 -k $(uname -r) --force
sudo depmod -a $(uname -r)     # REQUIRED - without it modprobe cannot find the .ko
```

Then verify **every** kernel that has an image in `/boot`, not just the running one:

```bash
for k in $(ls /lib/modules/); do
  sudo modinfo -k "$k" amneziawg >/dev/null 2>&1 && echo "$k OK" || echo "$k MISSING"
done
```

Stale `/lib/modules/*` directories with no matching image never boot and can be ignored.
`autoinstall_all_kernels="yes"` in `/etc/dkms/framework.conf.d/` covers future kernels.

## Peers handshake fine, zero traffic flows

**Cause:** ufw's default `routed` policy is DROP and its own chain jump sits in `FORWARD`.
An **appended** ACCEPT rule lands *after* that DROP and never runs.

**Fix:** insert at position 1 so it preempts the jump.

```bash
iptables -I FORWARD 1 -i wg0 -j ACCEPT      # -I ... 1, never -A
```

`wg show` looks healthy in this state, which is what makes it confusing. This is exactly
the failure `test-device.sh` exists to catch — it builds the client tunnel in a network
namespace and passes real traffic through it, so "registered" and "working" stop being the
same claim.

## The port is open internally but unreachable from outside

**Cause:** a **cloud provider firewall** in front of the VM. Hetzner, DigitalOcean and AWS
all offer one; it is enforced outside the machine and is invisible from inside. `ufw status`
will show the port allowed while nothing arrives.

**Fix:** check the provider's console for an inbound rule before debugging the box.

## unbound will not start

**Cause:** `auto-trust-anchor-file` declared twice — the distro package already sets one in
its own drop-in, so adding it again is fatal:

```
error: trust anchor for '.' presented twice
fatal error: bad config during init for validator module
```

**Fix:** remove your declaration and let the package's own drop-in provide it.

## AdGuard Home v1.0.0 rejects its own migrated config

**Cause:** the config migrator converts

```yaml
bootstrap_dns:
  - 1.1.1.1
  - 8.8.8.8
```

into a **list-of-lists** that its own parser then refuses:

```
failed to parse configuration file err="yaml: construct errors: line 14:
cannot construct !!seq into string"
```

**Fix:** flatten it back to a list of strings. Also note the v1.0.0 schema moved several
keys — `filtering_enabled` is now `filtering:`, and unknown keys fail the whole file.

## A resolver on the tunnel IP dies when the interface restarts

**Cause:** the resolver holds a socket bound to an address that briefly ceases to exist. It
does not rebind on its own.

**Fix:** restart it in the same step as the interface, then re-test resolution on the tunnel
address. The VPN will look perfectly healthy while DNS is broken for every client.

## The server is in a "sane" state but the systemd units say `inactive`

**Cause:** the interface was brought up with `wg-quick up` rather than through systemd, so
the unit never ran. The tunnel works, but `systemctl restart` will fail because it tries to
`up` an interface that already exists.

**Fix:** bring it down, then start the unit, so systemd owns the lifecycle:

```bash
sudo systemctl stop wg-quick@wg0; sudo wg-quick down wg0 2>/dev/null
sudo systemctl start wg-quick@wg0
```
