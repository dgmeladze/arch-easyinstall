#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Arch Installer (post-partitioning)
# You DO manually BEFORE running:
#   - partitioning, mkfs
#   - mount root to /mnt
#   - (UEFI) mount ESP (FAT32) to /mnt/boot/efi OR /mnt/efi
# ============================================

err() { echo -e "\nERROR: $*\n" >&2; exit 1; }
say() { echo -e "\n==> $*\n"; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || err "Run as root (use sudo)."
}

is_uefi() { [[ -d /sys/firmware/efi ]]; }

is_mountpoint() { mountpoint -q "$1"; }

prompt_nonempty() {
  local __var="$1"; shift
  local prompt="$1"; shift
  local v=""
  while true; do
    read -rp "$prompt" v
    v="${v//$'\r'/}"
    v="${v//$'\n'/}"
    [[ -n "$v" ]] && { printf -v "$__var" "%s" "$v"; return 0; }
    echo "Value cannot be empty."
  done
}

prompt_password_twice() {
  local __var="$1"; shift
  local label="$1"; shift
  local p1 p2
  while true; do
    read -rsp "$label: " p1; echo
    read -rsp "Repeat $label: " p2; echo
    [[ -n "$p1" ]] || { echo "Password cannot be empty."; continue; }
    [[ "$p1" == "$p2" ]] || { echo "Passwords do not match."; continue; }
    printf -v "$__var" "%s" "$p1"
    return 0
  done
}

pick_one() {
  local title="$1"; shift
  local -a options=("$@")
  echo
  echo "$title"
  local i=1
  for o in "${options[@]}"; do
    echo "  $i) $o"
    ((i++))
  done
  local choice
  while true; do
    read -rp "> " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( choice >= 1 && choice <= ${#options[@]} )) || { echo "Choose 1..${#options[@]}"; continue; }
    echo "${options[$((choice-1))]}"
    return 0
  done
}

validate_timezone() {
  local tz="$1"
  timedatectl list-timezones | grep -qx "$tz"
}

cpu_detect() {
  if grep -qi intel /proc/cpuinfo; then echo "intel"; return; fi
  if grep -qi amd /proc/cpuinfo; then echo "amd"; return; fi
  echo "unknown"
}

gpu_detect() {
  local vga
  vga="$(lspci -nn | grep -Ei 'VGA|3D|Display' || true)"
  if echo "$vga" | grep -qi nvidia; then echo "nvidia"; return; fi
  if echo "$vga" | grep -qi amd; then echo "amd"; return; fi
  if echo "$vga" | grep -qi intel; then echo "intel"; return; fi
  echo "unknown"
}

enable_multilib_in_target() {
  # Enable multilib in /mnt/etc/pacman.conf
  local f="/mnt/etc/pacman.conf"
  [[ -f "$f" ]] || return 0
  if grep -q "^\#\[multilib\]" "$f"; then
    sed -i '/^\#\[multilib\]/,/^\#Include = \/etc\/pacman\.d\/mirrorlist/ s/^#//' "$f"
  fi
}

# ----------------------------
# START
# ----------------------------
require_root

say "Pre-flight checks"
is_mountpoint /mnt || err "/mnt is not mounted. You must mount your root partition to /mnt first."

if is_uefi; then
  say "Boot mode: UEFI"
  # For UEFI we REQUIRE ESP mounted inside /mnt
  if is_mountpoint /mnt/boot/efi; then
    EFI_DIR="/boot/efi"
  elif is_mountpoint /mnt/efi; then
    EFI_DIR="/efi"
  else
    echo "UEFI detected, but ESP is NOT mounted to /mnt/boot/efi or /mnt/efi."
    echo "Mount your EFI partition (FAT32) and re-run."
    echo "Example:"
    echo "  mkdir -p /mnt/boot/efi"
    echo "  mount /dev/<esp-partition> /mnt/boot/efi"
    exit 1
  fi
else
  say "Boot mode: BIOS/Legacy (UEFI not detected)"
  EFI_DIR=""
fi

# ----------------------------
# User choices
# ----------------------------
say "User choices"

prompt_nonempty HOSTNAME "Hostname: "
prompt_nonempty USERNAME "Username: "
prompt_password_twice USER_PASS "User password"

ROOT_SET="$(pick_one "Set root password?" "no" "yes")"
ROOT_PASS=""
if [[ "$ROOT_SET" == "yes" ]]; then
  prompt_password_twice ROOT_PASS "Root password"
fi

# timezone
while true; do
  read -rp "Timezone (e.g. Europe/Moscow): " TZ
  TZ="${TZ//$'\r'/}"
  TZ="${TZ//$'\n'/}"
  [[ -n "$TZ" ]] || { echo "Timezone cannot be empty."; continue; }
  if validate_timezone "$TZ"; then break; fi
  echo "Invalid timezone. Example: Europe/Moscow, Europe/Amsterdam"
done

# locales: user provides like: "en_US.UTF-8 UTF-8,ru_RU.UTF-8 UTF-8"
read -rp "Locales to enable (comma-separated, default: en_US.UTF-8 UTF-8,ru_RU.UTF-8 UTF-8): " LOCALES_RAW
LOCALES_RAW="${LOCALES_RAW//$'\r'/}"
LOCALES_RAW="${LOCALES_RAW//$'\n'/}"
[[ -n "$LOCALES_RAW" ]] || LOCALES_RAW="en_US.UTF-8 UTF-8,ru_RU.UTF-8 UTF-8"

read -rp "Default LANG (default: en_US.UTF-8): " LANG_DEFAULT
LANG_DEFAULT="${LANG_DEFAULT//$'\r'/}"
LANG_DEFAULT="${LANG_DEFAULT//$'\n'/}"
[[ -n "$LANG_DEFAULT" ]] || LANG_DEFAULT="en_US.UTF-8"

read -rp "Console KEYMAP (default: us): " KEYMAP
KEYMAP="${KEYMAP//$'\r'/}"
KEYMAP="${KEYMAP//$'\n'/}"
[[ -n "$KEYMAP" ]] || KEYMAP="us"

# kernels
KERNELS_CHOICE="$(pick_one "Choose kernel(s)" \
  "linux" \
  "linux-lts" \
  "linux-zen" \
  "linux + linux-lts" \
  "linux + linux-zen" \
  "linux-lts + linux-zen" \
  "linux + linux-lts + linux-zen")"

# desktop
DE_CHOICE="$(pick_one "Choose Desktop Environment" \
  "none" \
  "GNOME" \
  "KDE Plasma" \
  "XFCE" \
  "i3")"

# gpu
GPU_AUTO="$(gpu_detect)"
CPU_AUTO="$(cpu_detect)"
echo "Detected CPU: $CPU_AUTO"
echo "Detected GPU: $GPU_AUTO"

GPU_CHOICE="$(pick_one "Choose GPU driver" \
  "auto ($GPU_AUTO)" \
  "intel" \
  "amd" \
  "nvidia (DKMS)" \
  "nouveau (open)" \
  "skip")"
[[ "$GPU_CHOICE" == auto* ]] && GPU_CHOICE="$GPU_AUTO"

UCODE_CHOICE="$(pick_one "Install CPU microcode?" \
  "auto ($CPU_AUTO)" \
  "intel-ucode" \
  "amd-ucode" \
  "skip")"
if [[ "$UCODE_CHOICE" == auto* ]]; then
  if [[ "$CPU_AUTO" == "intel" ]]; then UCODE_CHOICE="intel-ucode"
  elif [[ "$CPU_AUTO" == "amd" ]]; then UCODE_CHOICE="amd-ucode"
  else UCODE_CHOICE="skip"
  fi
fi

SWAP_CHOICE="$(pick_one "Create swapfile?" "no" "yes (2G)" "yes (4G)" "yes (8G)")"
STEAM_CHOICE="$(pick_one "Install Steam?" "no" "yes")"

say "Building package list..."

PKGS=(base base-devel linux-firmware networkmanager sudo grub os-prober vim nano git wget curl)
# UEFI tools if needed
if is_uefi; then
  PKGS+=(efibootmgr dosfstools mtools)
fi

add_kernel() {
  local k="$1"
  PKGS+=("$k")
  case "$k" in
    linux) PKGS+=(linux-headers) ;;
    linux-lts) PKGS+=(linux-lts linux-lts-headers) ;;
    linux-zen) PKGS+=(linux-zen linux-zen-headers) ;;
  esac
}

case "$KERNELS_CHOICE" in
  linux) add_kernel linux ;;
  linux-lts) add_kernel linux-lts ;;
  linux-zen) add_kernel linux-zen ;;
  "linux + linux-lts") add_kernel linux; add_kernel linux-lts ;;
  "linux + linux-zen") add_kernel linux; add_kernel linux-zen ;;
  "linux-lts + linux-zen") add_kernel linux-lts; add_kernel linux-zen ;;
  "linux + linux-lts + linux-zen") add_kernel linux; add_kernel linux-lts; add_kernel linux-zen ;;
esac

# microcode
if [[ "$UCODE_CHOICE" != "skip" ]]; then PKGS+=("$UCODE_CHOICE"); fi

# Xorg base if any DE except none
if [[ "$DE_CHOICE" != "none" ]]; then
  PKGS+=(xorg-server xorg-xinit)
fi

# Mesa always
PKGS+=(mesa)

# GPU-specific
case "$GPU_CHOICE" in
  intel) PKGS+=(vulkan-intel) ;;
  amd)   PKGS+=(vulkan-radeon) ;;
  nvidia) PKGS+=(dkms nvidia-dkms nvidia-utils nvidia-settings) ;;
  nouveau) PKGS+=(xf86-video-nouveau) ;;
  skip|unknown) ;;
esac

# DE packages + display manager
DM_SERVICE=""
case "$DE_CHOICE" in
  GNOME)
    PKGS+=(gnome gdm)
    DM_SERVICE="gdm"
    ;;
  "KDE Plasma")
    PKGS+=(plasma sddm)
    DM_SERVICE="sddm"
    ;;
  XFCE)
    PKGS+=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter)
    DM_SERVICE="lightdm"
    ;;
  i3)
    PKGS+=(i3-wm i3status dmenu lightdm lightdm-gtk-greeter)
    DM_SERVICE="lightdm"
    ;;
  none)
    DM_SERVICE=""
    ;;
esac

say "Installing base system to /mnt (pacstrap)"
pacstrap /mnt "${PKGS[@]}"

say "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# multilib + steam needs to be configured in target before installing steam in chroot
if [[ "$STEAM_CHOICE" == "yes" ]]; then
  say "Enabling multilib in target (/mnt/etc/pacman.conf)"
  enable_multilib_in_target
fi

# ----------------------------
# CHROOT CONFIG
# ----------------------------
say "Configuring installed system (arch-chroot)"

arch-chroot /mnt /bin/bash -e <<CHROOT
set -euo pipefail

# ---- timezone ----
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

# ---- locale ----
# enable requested locales in /etc/locale.gen
IFS=',' read -r -a LOCALES <<< "$LOCALES_RAW"
for L in "\${LOCALES[@]}"; do
  L="\$(echo "\$L" | xargs)"
  [[ -n "\$L" ]] || continue
  # escape for sed
  esc="\$(printf '%s\n' "\$L" | sed 's/[.[\*^$(){}?+|/]/\\\\&/g')"
  sed -i "s/^#\\(\$esc\\)\$/\\1/" /etc/locale.gen || true
done
locale-gen

cat > /etc/locale.conf <<EOF
LANG=$LANG_DEFAULT
EOF

cat > /etc/vconsole.conf <<EOF
KEYMAP=$KEYMAP
EOF

# ---- hostname + hosts ----
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# ---- users ----
useradd -m -G wheel,audio,video,optical,storage "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd

if [[ "$ROOT_SET" == "yes" ]]; then
  echo "root:$ROOT_PASS" | chpasswd
fi

# sudo for wheel
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# ---- networking ----
systemctl enable NetworkManager

# ---- swapfile (optional) ----
case "$SWAP_CHOICE" in
  "yes (2G)")
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
    ;;
  "yes (4G)")
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
    ;;
  "yes (8G)")
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
    ;;
esac

# ---- NVIDIA tweaks (if chosen) ----
if [[ "$GPU_CHOICE" == "nvidia" ]]; then
  mkdir -p /etc/modprobe.d
  echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia.conf
fi

# rebuild initramfs
mkinitcpio -P

# ---- bootloader ----
if [[ -d /sys/firmware/efi ]]; then
  # UEFI install
  grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=GRUB --recheck
else
  # BIOS install requires disk, but you didn't ask for BIOS flow here.
  echo "WARNING: Not in UEFI mode. Skipping BIOS GRUB install (by design)."
fi
grub-mkconfig -o /boot/grub/grub.cfg

# ---- display manager ----
if [[ -n "$DM_SERVICE" ]]; then
  systemctl enable "$DM_SERVICE"
fi

# ---- Steam (optional) ----
if [[ "$STEAM_CHOICE" == "yes" ]]; then
  pacman -Sy --noconfirm
  pacman -S --noconfirm steam

  # lib32 graphics bits (useful for Steam/Proton)
  pacman -S --noconfirm lib32-mesa || true
  case "$GPU_CHOICE" in
    intel) pacman -S --noconfirm lib32-vulkan-intel || true ;;
    amd)   pacman -S --noconfirm lib32-vulkan-radeon || true ;;
    nvidia) pacman -S --noconfirm lib32-nvidia-utils || true ;;
  esac
fi

echo
echo "DONE."
echo "Next:"
echo "  exit"
echo "  umount -R /mnt"
echo "  reboot"
CHROOT

say "All finished. Now run:"
echo "  umount -R /mnt"
echo "  reboot"
