# Arch Installer Script (UEFI, post-partitioning)

A simple interactive installer for Arch Linux that starts **after you have partitioned, formatted, and mounted** your target system.  
No `nano`/manual edits for locale/hosts/timezone — the script asks questions and configures everything automatically.

✅ What it does:
- Validates you booted in **UEFI** mode
- Validates `/mnt` is mounted (root) and **ESP** is mounted (`/mnt/boot/efi` or `/mnt/efi`)
- Installs base system via `pacstrap`
- Generates `fstab`
- Configures: timezone, locale(s), keymap, hostname, users, sudo, NetworkManager
- Installs and configures **GRUB UEFI**
- Optional: Desktop Environment, GPU drivers, swapfile, Steam (+ multilib)
- Creates a log: `/root/arch-install.log`

---

## Requirements

- Booted from **Arch ISO**
- **UEFI mode** (required)
- Internet connection during install

---

## Quick Start (recommended)

### 0) Boot Arch ISO in UEFI
Check:
```bash
ls /sys/firmware/efi
```
If the directory does not exist → reboot and pick the **UEFI** boot entry.

---

## Pre-Install Steps (manual)

### 1) Connect to the internet
Ethernet usually works automatically.  
For Wi‑Fi:
```bash
iwctl
# inside iwctl:
device list
station <device> scan
station <device> get-networks
station <device> connect "<SSID>"
exit
```

Test:
```bash
ping -c 3 archlinux.org
```

---

### 2) Partition the disk (example with fdisk)
List disks:
```bash
lsblk
```

Open partition tool (example):
```bash
fdisk /dev/nvme0n1
```

Minimal UEFI layout:
- **ESP** (EFI System Partition): `300–512M`, type **EFI System**
- **Root**: the rest (or whatever you want)

---

### 3) Format filesystems
**ESP must be FAT32**
```bash
mkfs.fat -F32 /dev/your_efi_partition
```

Root example (ext4):
```bash
mkfs.ext4 /dev/your_root_partition
```

If you created swap partition:
```bash
mkswap /dev/your_swap_partition
swapon /dev/your_swap_partition
```

---

### 4) Install basic tools in live ISO (git + keyring)
Sometimes Arch ISO keyring is outdated; install it early.

```bash
pacman -Sy archlinux-keyring git
```

> If pacman complains about signatures, see **Troubleshooting** below.

---

### 5) Mount target system to /mnt
Mount root:
```bash
mount /dev/your_root_partition /mnt
```

Mount ESP (required for UEFI GRUB):
```bash
mkdir -p /mnt/boot/efi
mount /dev/your_efi_partition /mnt/boot/efi
```

Verify:
```bash
mount | grep "on /mnt"
mount | grep "on /mnt/boot/efi"
```

---

## Run the installer

### Option A: Run from Git (recommended)
```bash
git clone https://github.com/<your-user>/<your-repo>.git
cd <your-repo>
chmod +x arch-installer-full.sh
sudo bash ./arch-installer-full.sh
```

### Option B: Run from a local file (Ventoy/USB)
Copy `arch-installer-full.sh` to your USB drive and run:
```bash
chmod +x /path/to/arch-installer-full.sh
sudo bash /path/to/arch-installer-full.sh
```

> If you edited the script on Windows and it has CRLF:
```bash
sed -i 's/\r$//' arch-installer-full.sh
```

---

## After the script finishes
The script will tell you what to do, but typically:

```bash
umount -R /mnt
reboot
```

Remove the USB stick so the system boots from disk.

---

## Troubleshooting

### 1) Keyring / signature errors (pacman)
If you see errors like:
- `invalid or corrupted package (PGP signature)`
- `keyring is not writable`
- `signature from ... is unknown trust`

Fix (in live ISO):
```bash
pacman -Sy archlinux-keyring
pacman-key --init
pacman-key --populate archlinux
```

Then retry:
```bash
pacman -Syu
```

---

### 2) Mirror issues (slow / 404 / timeouts)
If downloads are slow or fail, update mirrorlist.

Quick (simple):
- Re-run with a better network, or
- Use `reflector`:

```bash
pacman -Sy reflector
reflector --country Netherlands,Germany,France --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy
```

(Adjust countries to your region.)

---

### 3) Script refuses to run: “not booted in UEFI”
You booted the ISO in legacy mode.  
Fix: reboot and choose a boot entry that contains **UEFI**.

---

### 4) Script refuses to run: “ESP is not mounted”
You must mount the EFI partition inside `/mnt` before running:

```bash
mkdir -p /mnt/boot/efi
mount /dev/your_efi_partition /mnt/boot/efi
```

---

### 5) Where to find logs?
The installer writes a full log to:
- `/root/arch-install.log` (in live ISO)

If something fails, copy/paste the last 50 lines:
```bash
tail -n 50 /root/arch-install.log
```

---

## Notes / Assumptions

- This script is designed for **UEFI installs only**.
- You handle partitioning + formatting manually by design (more control, fewer surprises).
- If you use hybrid graphics (Intel + NVIDIA), choose the hybrid option when asked.

---

## License
GPL
