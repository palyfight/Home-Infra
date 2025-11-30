# ==============================================================================

# Instructions to install the YT6801 Ethernet driver on Ubuntu Server

#

# If your Mini PC uses the Motorcomm YT6801 Gigabit Ethernet Controller (PCI ID 1f0a:6801),

# which is **not supported by default** in the Ubuntu Server 22.04 or 24.04 kernels.

# As a result, the installer will not detect the wired interface.

#

# Why this is needed:

# Motorcomm (a lesser-known vendor) released the YT6801 driver only recently,

# and it has not yet been merged into the mainline Linux kernel. Therefore, Ubuntu’s

# default kernel lacks built-in support for this controller.

# ==============================================================================

# https://github.com/dante1613/Motorcomm-YT6801/blob/e45f2fca4d8bac6445d3ed98b2973b7c1e42eb35/Ubuntu%20-%20instruction.md

After upgrade kernel (ONLY), you need to rebuild driver
Guide

1. Update headers
   sudo apt install linux-headers-$(uname -r)
2. Download driver
   wget https://github.com/dante1613/Motorcomm-YT6801/raw/main/tuxedo-yt6801/tuxedo-yt6801_1.0.28-1_all.deb
3. Install driver
   sudo dpkg -i tuxedo-yt6801_1.0.28-1_all.deb
4. Creates a list of module dependencies
   sudo depmod
5. Check load module
   lsmod | grep yt6801
6. Reboot
   reboot

#

# Install HWE kernel so QSV works:

# https://discourse.ubuntu.com/t/how-to-use-intel-n150-igpu-on-ubuntu-server/62895?utm_source=chatgpt.com
