#!/usr/bin/env bash

# ==============================================================================
# Script to install the YT6801 Ethernet driver on Ubuntu Server
#
# If your Mini PC uses the Motorcomm YT6801 Gigabit Ethernet Controller (PCI ID 1f0a:6801),
# which is **not supported by default** in the Ubuntu Server 22.04 or 24.04 kernels.
# As a result, the installer will not detect the wired interface, but Wi-Fi worked.
#
# Why this script is needed:
# Motorcomm (a lesser-known vendor) released the YT6801 driver only recently,
# and it has not yet been merged into the mainline Linux kernel. Therefore, Ubuntu’s
# default kernel lacks built-in support for this controller.
#
# This script automates the process of downloading, building, installing (via DKMS),
# and activating the out-of-tree YT6801 kernel module from Motorcomm’s repository,
# so that your wired Ethernet interface will be correctly recognized and usable.
# ==============================================================================

# Instructions found here: https://github.com/dante1613/Motorcomm-YT6801/blob/e45f2fca4d8bac6445d3ed98b2973b7c1e42eb35/Ubuntu%20-%20instruction.md
set -euo pipefail

echo "==> Installing prerequisites for YT6801 driver..."

sudo apt update
sudo apt install -y build-essential dkms git linux-headers-$(uname -r) || {
  echo "ERROR: failed to install prerequisites. Exiting."
  exit 1
}

echo "==> Cloning Motorcomm YT6801 driver repository..."
git clone https://github.com/dante1613/Motorcomm-YT6801.git
cd "Motorcomm-YT6801/Ubuntu - instruction.md" 2>/dev/null || cd Motorcomm-YT6801

echo "==> Adding driver to DKMS..."
sudo dkms add ./ || {
  echo "ERROR: dkms add failed."
  exit 1
}

echo "==> Building driver via DKMS..."
sudo dkms build -m YT6801 -v 1.0 || {
  echo "ERROR: dkms build failed."
  exit 1
}

echo "==> Installing built driver via DKMS..."
sudo dkms install -m YT6801 -v 1.0 || {
  echo "ERROR: dkms install failed."
  exit 1
}

echo "==> Loading the module now..."
sudo modprobe yt6801 || {
  echo "ERROR: modprobe yt6801 failed."
  exit 1
}

echo "==> Ensuring the module loads at boot..."
echo "yt6801" | sudo tee /etc/modules-load.d/yt6801.conf >/dev/null

echo "==> Driver installation complete. Checking interface..."
ip link show

echo "If you see a wired interface (e.g., enp1s0, eth0) you’re good to go!"
echo "Rebooting is recommended."
sudo reboot
