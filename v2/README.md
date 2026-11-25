# Server Update / Upgrade Runbook

This is the runbook to follow whenever the Ubuntu Server host (`homeserver`,
Motorcomm YT6801 ethernet) needs a system update, kernel upgrade, or full
release upgrade.

The tricky part: **a kernel upgrade can leave the ethernet port without a driver.**
HWE 7.0 kernels include a built-in driver (`dwmac-motorcomm`), so no rebuild should
be needed, but we keep Wi-Fi as a fallback in case wired doesn't come back.

The runbook below walks through the full cycle: stack down → Wi-Fi → upgrade →
check the driver → ethernet back → stack up → verify → clean up old kernels.

---

## 0. Prerequisites

- sudo access on the server
- `wpasupplicant` installed (`sudo apt install wpasupplicant` — only needed
  the first time; after that, Wi-Fi via netplan works out of the box)
- These files in [../ubuntu-server/](../ubuntu-server/):
  - `ethernet-netplan.yaml` — static-IP wired config for `enp1s0`
  - `wifi-netplan.yaml` — Wi-Fi fallback template
  - `tuxedo-apt-pin.pref` — limits what apt takes from the TUXEDO repo
  - `tuxedo-yt6801_1.0.28-1_all.deb` — older driver package, for offline use only
- Wi-Fi SSID and password ready

### One-time host setup

The TUXEDO repo must match the Ubuntu release. This should list `noble`, not
`resolute`:

```bash
apt-cache policy tuxedo-yt6801
```

If it's wrong, see
[TUXEDO kernel packages fail to install](#tuxedo-kernel-packages-fail-to-install).

Pin the repo so it only supplies `tuxedo-*` packages and never a TUXEDO kernel:

```bash
sudo cp ~/Home-Infra/ubuntu-server/tuxedo-apt-pin.pref /etc/apt/preferences.d/tuxedo
sudo apt update
apt-cache policy libva2 linux-tuxedo   # libva2 candidate is Ubuntu's; linux-tuxedo has none
```

Allow the built-in NIC driver to load automatically
([why](../ubuntu-server/README.md#built-in-driver-and-the-tuxedo-blacklist)):

```bash
sudo ln -s /dev/null /etc/modprobe.d/tuxedo-yt6801-backlist-upstream-conflicts.conf
sudo update-initramfs -u
```

---

## 1. Take the Docker stack down cleanly

```bash
cd ~/Home-Infra/v2
./stack.sh down
```

Check nothing is still running that shouldn't be:

```bash
docker ps
```

---

## 2. Switch to the Wi-Fi netplan

A kernel upgrade may break ethernet — get Wi-Fi ready **before** you upgrade,
while wired still works.

```bash
# Fill in SSID and password in the template, then copy into /etc/netplan
sudoedit ~/Home-Infra/ubuntu-server/wifi-netplan.yaml
sudo cp ~/Home-Infra/ubuntu-server/wifi-netplan.yaml /etc/netplan/60-wifi.yaml
sudo chmod 600 /etc/netplan/60-wifi.yaml

# Disable the ethernet netplan (netplan ignores files not ending in .yaml)
sudo mv /etc/netplan/50-ethernet-netplan.yaml /etc/netplan/50-ethernet-netplan.yaml.disabled
# (adjust the filename to whatever you currently have in /etc/netplan/)

sudo netplan apply
```

Verify Wi-Fi is actually up and the internet works:

```bash
ip -4 a show wlp2s0       # should show a DHCP-assigned address
ping -c 3 1.1.1.1
```

> **Note**: Wi-Fi will give you a different IP than the wired static
> `192.168.1.176`. If you're SSH'ing in, find the new address with `ip a`
> on the console first, or use the hostname.

---

## 3. Run the upgrade

Preview first. **Stop if the output includes a `linux-*tuxedo*` package**, or
packages you didn't expect from the TUXEDO repo: the repo or pin from section 0 is
wrong.

```bash
sudo apt update
sudo apt dist-upgrade --dry-run
```

Then upgrade. If apt ends with `dpkg returned an error code`, deal with that before
continuing, and don't reboot until you've checked `sudo dpkg --audit`.

```bash
sudo apt upgrade
sudo apt dist-upgrade
sudo dpkg --audit         # should print nothing
```

Don't run `autoremove` yet. Old kernels are your fallback until
[section 11](#11-clean-up-old-kernels).

For a full Ubuntu release upgrade (e.g. 22.04 → 24.04):

```bash
sudo do-release-upgrade
```

Reboot when done. Check that GRUB's default is the kernel you expect first:

```bash
sudo grep -E "^\s*(menuentry|submenu) " /boot/grub/grub.cfg | cut -d"'" -f2
sudo reboot
```

---

## 4. Reconnect after reboot

SSH back in over Wi-Fi. The ethernet netplan is still disabled, so wired won't have
an address yet, even if the driver is fine.

---

## 5. Check the YT6801 ethernet driver

```bash
uname -r
lspci -k -d 1f0a:6801
```

| Result | What to do |
|---|---|
| `Kernel driver in use: dwmac-motorcomm` | The built-in driver is working. Go to step 6. |
| `Kernel driver in use: yt6801` | The out-of-tree driver is working. Go to step 6. |
| No `Kernel driver in use` line | Run `sudo modprobe dwmac-motorcomm` and check again. If that works, make sure the blacklist override from section 0 is in place. |
| Still no driver | Reboot into `6.8.0-*-generic` from the GRUB menu, which has the out-of-tree driver built. |

The 6.8 kernel is only a temporary fallback, because QSV needs the HWE kernel.

Background and manual driver install:
[../ubuntu-server/README.md](../ubuntu-server/README.md).

---

## 6. Switch back to the ethernet netplan

Keep Wi-Fi enabled until a reboot has proven wired works, so you can't lose remote
access.

```bash
# Re-enable wired config
sudo mv /etc/netplan/50-ethernet-netplan.yaml.disabled /etc/netplan/50-ethernet-netplan.yaml
sudo chmod 600 /etc/netplan/50-ethernet-netplan.yaml
sudo netplan apply

ip -4 a show enp1s0              # should show 192.168.1.176/24
ping -c 3 -I enp1s0 1.1.1.1
sudo reboot
```

Reconnect to `palyfight@192.168.1.176` (or the hostname) and confirm the driver
loaded by itself:

```bash
lspci -k -d 1f0a:6801
ip -4 a show enp1s0
ping -c 3 -I enp1s0 1.1.1.1
```

Then retire Wi-Fi. Make sure you're connected through the wired IP first, because
this drops any session using the Wi-Fi IP:

```bash
sudo mv /etc/netplan/60-wifi.yaml /etc/netplan/60-wifi.yaml.disabled
sudo netplan apply
ip route | grep default          # should only show enp1s0
ping -c 3 1.1.1.1
```

---

## 7. Verify the NAS mount

NFS to the NAS is an automount (`x-systemd.automount`), so it should come up on
first access. Poke it:

```bash
ls /mnt/nas
findmnt /mnt/nas
```

You should see the real NAS contents (`media/`, `torrents/`, `immich/`, etc.)
and `findmnt` should show the NFS source at `192.168.1.105:/volume1/data`.

If it's not mounted, recover with:

```bash
sudo systemctl reset-failed mnt-nas.mount
sudo mount -a
```

---

## 8. Bring the Docker stack back up

```bash
cd ~/Home-Infra/v2
./stack.sh up
./stack.sh status
```

`stack.sh up` refuses to start if `/mnt/nas` isn't a real mountpoint — that's
the guard that stops Plex/Jellyfin/arrs from silently serving an empty dir.
If it errors, go back to step 7.

It also stops at the first stack that fails, so later stacks won't have started.
See [Common gotchas](#common-gotchas).

---

## 9. Tailscale IP sanity check

If the `tailscale` container had to re-authenticate, its tailnet IP may have
changed, which breaks DNS for `*.ts.paly-home.work`.

```bash
docker exec tailscale tailscale ip -4
```

If the IP is different from what's in Cloudflare's A record for
`*.ts.paly-home.work`, update the record (or pin the IP in the Tailscale admin
console so it can't drift).

---

## 10. Smoke-test the services

From a Tailscale-connected client:

```bash
curl -I https://jellyfin.ts.paly-home.work
curl -I https://plex.ts.paly-home.work
curl -I https://immich.ts.paly-home.work
curl -I https://n8n.ts.paly-home.work
```

Or just open the homepage dashboard: `https://homepage.ts.paly-home.work`.

---

## 11. Clean up old kernels

Only once everything above works. Check the preview doesn't remove the running
kernel or your 6.8 fallback:

```bash
uname -r
sudo apt autoremove --purge --dry-run
sudo apt autoremove --purge
```

---

## Related references

- Hardware-specific driver notes: [../ubuntu-server/README.md](../ubuntu-server/README.md)
- Netplan examples: [../ubuntu-server/ethernet-netplan.yaml](../ubuntu-server/ethernet-netplan.yaml),
  [../ubuntu-server/wifi-netplan.yaml](../ubuntu-server/wifi-netplan.yaml)
- Stack orchestration: [stack.sh](stack.sh)
- Intel N150 iGPU / QSV: https://discourse.ubuntu.com/t/how-to-use-intel-n150-igpu-on-ubuntu-server/62895

---

## Common gotchas

- **Docker Hub rate limits** on the first `stack.sh up` after a kernel/image
  refresh. See the header comment in [stack.sh](stack.sh) — wait a few minutes
  and re-run, or `docker login` with a free account.
- **NFS mount silently empty** — if `mountpoint -q /mnt/nas` fails, the stack
  won't start. Fix the mount first, don't work around the guard.
- **Tailscale IP drift** after re-auth — pin it in the admin console, or point
  Cloudflare at the MagicDNS name (`traefik.<tailnet>.ts.net`) via CNAME to
  eliminate the manual step entirely.
- **`netplan apply` hangs** if a wifi password is wrong — it keeps retrying.
  Check with `journalctl -u systemd-networkd -f` in another session.
- **One failed stack blocks the rest** — `stack.sh up` stops at the first error. To
  start the remaining stacks while you debug, run `docker compose up -d` in each
  stack's directory, in the order listed in [stack.sh](stack.sh).
- **MongoDB won't start on kernel 6.19+** — `mongodb` restarts in a loop, logging
  `MongoDB cannot start: Linux kernel versions 6.19 and newer has a known
  incompatibility`, which fails `extras` and stops `stack.sh up`. As of 2026-11-04,
  MongoDB's table lists 8.3.14+ and 8.0.35+ as working on fixed kernels, but
  `mongo:8` is still 8.3.13. Its check reads `uname -r`, which Ubuntu reports as
  `7.0.0` even on kernels with the upstream fix. Don't look for a bypass. See
  [SERVER-125742](https://jira.mongodb.org/browse/SERVER-125742) and
  [SERVER-136848](https://jira.mongodb.org/browse/SERVER-136848).

### TUXEDO kernel packages fail to install

Symptom: `run-parts: missing operand`, then `dpkg returned an error code (1)`, on
`linux-headers-*-tuxedo` or `linux-image-*-tuxedo`.

Cause: the host is on the 26.04 (`resolute`) TUXEDO repo. Those packages' scripts
pass `run-parts` two directories, and 24.04's version only accepts one.

Fix:

```bash
# 1. See what's affected and whether any kernel is half-installed
dpkg -l | grep -E 'linux-.*tuxedo'
sudo dpkg --audit

# 2. Purge every linux-*tuxedo* package from that list. Use dpkg, because apt tries
#    to reinstall a half-installed package first, which fails the same way.
sudo dpkg --purge --force-remove-reinstreq <packages>

# 3. Switch the repo by installing the matching tuxedo-repository build. Check the
#    SHA256 against the repo's noble Packages index first. A downgrade warning is
#    expected.
cd /tmp
curl -fsSLO 'https://deb.tuxedocomputers.com/ubuntu/pool/main/t/tuxedo-repository/tuxedo-repository_1.0.3+24.04_all.deb'
sudo dpkg -i 'tuxedo-repository_1.0.3+24.04_all.deb'

# 4. Confirm
sudo apt update
sudo dpkg --configure -a
sudo dpkg --audit         # should print nothing
```

Then install the pin from section 0 so this can't come back.
