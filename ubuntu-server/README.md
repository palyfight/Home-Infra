# Ubuntu Server hardware notes

## Motorcomm YT6801 ethernet (PCI ID `1f0a:6801`)

Which driver you need depends on the kernel:

| Kernel | Driver | What to do |
|---|---|---|
| HWE 7.0 (`7.0.0-*-generic`) | Built-in `dwmac-motorcomm` | Override the TUXEDO blacklist (below). No rebuild needed. |
| GA 6.8 (`6.8.0-*-generic`), or the 22.04/24.04 installer | Out-of-tree `yt6801` | The NIC isn't supported by default, so the installer won't detect it. Use the DKMS driver (below). |

Check which driver has the NIC:

```bash
lspci -k -d 1f0a:6801
```

Look for the `Kernel driver in use:` line. If only `Kernel modules:` appears, the
NIC has no driver bound.

### Built-in driver and the TUXEDO blacklist

`tuxedo-yt6801` 1.0.32 ships
`/usr/lib/modprobe.d/tuxedo-yt6801-backlist-upstream-conflicts.conf`, which
contains `blacklist dwmac-motorcomm`. If the out-of-tree module isn't built for
the running kernel, neither driver loads automatically and `enp1s0` doesn't exist.

Override that one file. A same-named file in `/etc` takes priority over `/usr/lib`:

```bash
sudo ln -s /dev/null /etc/modprobe.d/tuxedo-yt6801-backlist-upstream-conflicts.conf
sudo update-initramfs -u
```

Delete the link to undo this. To test the driver without changing anything
permanently, run `sudo modprobe dwmac-motorcomm`. A blacklist doesn't block
loading by name.

### Out-of-tree driver (6.8 kernels)

`tuxedo-yt6801` comes from the TUXEDO apt repo and uses DKMS. Installing headers
for a kernel builds the module automatically:

```bash
sudo apt install linux-headers-$(uname -r)
dkms status
lsmod | grep yt6801
```

It's currently built for `6.8.0-147-generic`, which is the fallback kernel if the
built-in driver ever fails. Building 1.0.32 on 7.0 kernels hasn't been tested.

The older `tuxedo-yt6801_1.0.28-1_all.deb` in this directory is only for a host
without the TUXEDO repo, such as a fresh install with no network:

```bash
sudo apt install linux-headers-$(uname -r)
sudo dpkg -i tuxedo-yt6801_1.0.28-1_all.deb
sudo depmod
lsmod | grep yt6801
sudo reboot
```

Don't install it over a newer version, because it would downgrade the driver.

Upstream instructions:
https://github.com/dante1613/Motorcomm-YT6801/blob/e45f2fca4d8bac6445d3ed98b2973b7c1e42eb35/Ubuntu%20-%20instruction.md

## TUXEDO apt repo

The repo must match the Ubuntu release. It's configured by the `tuxedo-repository`
package, through a symlink at `/etc/apt/sources.list.d/tuxedo-computers.sources`.
Don't edit that file with `sed -i`, which replaces the symlink with a regular file.
To change release, install the matching `tuxedo-repository` build instead.

[`tuxedo-apt-pin.pref`](tuxedo-apt-pin.pref) limits the repo to `tuxedo-*` packages
and blocks TUXEDO kernels. Install steps are in
[../v2/README.md](../v2/README.md#0-prerequisites).

## Intel N150 iGPU / QSV

Install the HWE kernel so QSV works:
https://discourse.ubuntu.com/t/how-to-use-intel-n150-igpu-on-ubuntu-server/62895
