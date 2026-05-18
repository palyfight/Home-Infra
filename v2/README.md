# Server Update / Upgrade Runbook

This is the runbook to follow whenever the Ubuntu Server host (`homeserver`,
Motorcomm YT6801 ethernet) needs a system update, kernel upgrade, or full
release upgrade.

The tricky part: **any kernel upgrade breaks the ethernet driver** until the
out-of-tree YT6801 module is rebuilt against the new kernel. So we lose wired
internet mid-upgrade and have to fall back to Wi-Fi to finish the job.

The runbook below walks through the full cycle: stack down → Wi-Fi → upgrade →
driver rebuild → ethernet back → stack up → verify.

---

## 0. Prerequisites

- sudo access on the server
- `wpasupplicant` installed (`sudo apt install wpasupplicant` — only needed
  the first time; after that, Wi-Fi via netplan works out of the box)
- These files in [../ubuntu-server/](../ubuntu-server/):
  - `ethernet-netplan.yaml` — static-IP wired config for `enp1s0`
  - `wifi-netplan.yaml` — Wi-Fi fallback template
  - `tuxedo-yt6801_1.0.28-1_all.deb` — the YT6801 driver package
- Wi-Fi SSID and password ready

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

Kernel upgrade will break ethernet — get Wi-Fi ready **before** you upgrade,
while wired still works.

```bash
# Fill in SSID and password in the template, then copy into /etc/netplan
sudoedit ~/Home-Infra/ubuntu-server/wifi-netplan.yaml
sudo cp ~/Home-Infra/ubuntu-server/wifi-netplan.yaml /etc/netplan/60-wifi.yaml
sudo chmod 600 /etc/netplan/60-wifi.yaml

# Disable the ethernet netplan (netplan ignores files not ending in .yaml)
sudo mv /etc/netplan/50-ethernet.yaml /etc/netplan/50-ethernet.yaml.disabled
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

Apt update/upgrade:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt dist-upgrade -y
sudo apt autoremove --purge -y
```

For a full Ubuntu release upgrade (e.g. 22.04 → 24.04):

```bash
sudo do-release-upgrade
```

Reboot when done:

```bash
sudo reboot
```

---

## 4. Reconnect after reboot

SSH back in over Wi-Fi. The wired interface will be dead until the driver is
rebuilt in the next step.

---

## 5. Rebuild the YT6801 ethernet driver

The YT6801 is not in the mainline kernel, so the driver must be reinstalled
against the new kernel every time the kernel changes. Source and context:
[../ubuntu-server/README.md](../ubuntu-server/README.md).

```bash
# 1. Matching kernel headers for the running kernel
sudo apt install linux-headers-$(uname -r)

# 2. Install the driver package (ships as a .deb in this repo)
cd ~/Home-Infra/ubuntu-server
sudo dpkg -i tuxedo-yt6801_1.0.28-1_all.deb

# 3. Rebuild module dependency list
sudo depmod

# 4. Confirm the module is loaded
lsmod | grep yt6801
```

If `lsmod` shows `yt6801`, the driver is in place. Reboot so the interface
comes up cleanly:

```bash
sudo reboot
```

> If a newer `.deb` exists upstream, grab it first:
> `wget https://github.com/dante1613/Motorcomm-YT6801/raw/main/tuxedo-yt6801/tuxedo-yt6801_*.deb`

---

## 6. Switch back to the ethernet netplan

```bash
# Re-enable wired config
sudo mv /etc/netplan/50-ethernet.yaml.disabled /etc/netplan/50-ethernet.yaml

# Retire the Wi-Fi config (or keep it disabled for the next upgrade)
sudo mv /etc/netplan/60-wifi.yaml /etc/netplan/60-wifi.yaml.disabled

sudo chmod 600 /etc/netplan/50-ethernet.yaml
sudo netplan apply
```

Verify wired is up at the expected static IP and the internet works:

```bash
ip -4 a show enp1s0        # should show 192.168.1.176/24
ping -c 3 1.1.1.1
```

SSH sessions over the Wi-Fi IP will drop when you apply — reconnect to
`palyfight@192.168.1.176` (or the hostname).

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
