#!/usr/bin/env bash
set -euo pipefail

# ===== Logging (optional) =====
LOG="/root/arch-install.log"
exec > >(tee -a "$LOG") 2>&1

# ===== Helpers =====
err() { echo -e "\n[ERROR] $*\n" >&2; exit 1; }
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
    [[ "$p1" == "$p2" ]] || { echo "Passwords do not match. Try again."; continue; }
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
    read -rp "Enter number: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Please enter a number."; continue; }
    (( choice >= 1 && choice <= ${#options[@]} )) || { echo "Valid range: 1..${#options[@]}"; continue; }
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
  local f="/mnt/etc/pacman.conf"
  [[ -f "$f" ]] || return 0
  if grep -q "^\#\[multilib\]" "$f"; then
    sed -i '/^\#\[multilib\]/,/^\#Include = \/etc\/pacman\.d\/mirrorlist/ s/^#//' "$f"
  fi
}

# ===== Start =====
require_root

say "Pre-flight checks"
is_mountpoint /mnt || err "/mnt is not mounted. Mount your root partition to /mnt first."

if ! is_uefi; then
  err "You are NOT booted in UEFI mode. Reboot the ISO in UEFI mode, otherwise you won't get UEFI GRUB."
fi

EFI_DIR=""
if is_mountpoint /mnt/boot/efi; then
  EFI_DIR="/boot/efi"
elif is_mountpoint /mnt/efi; then
  EFI_DIR="/efi"
else
  err "UEFI is detected, but ESP (FAT32) is NOT mounted to /mnt/boot/efi or /mnt/efi.
Example:
  mkdir -p /mnt/boot/efi
  mount /dev/<esp-partition> /mnt/boot/efi"
fi

say "OK: /mnt and ESP are mounted. Continuing."

echo "Current mounts:"
mount | grep -E "on /mnt($|/)|on /mnt/boot/efi|on /mnt/efi" || true
echo
echo "Block devices:"
lsblk -f || true

CONFIRM="$(pick_one "Proceed with installation?" "Yes" "No")"
[[ "$CONFIRM" == "Yes" ]] || exit 0

# ===== User choices =====
say "Configuration"

prompt_nonempty HOSTNAME "Hostname: "
prompt_nonempty USERNAME "Username: "
prompt_password_twice USER_PASS "User password"

SET_ROOT="$(pick_one "Set root password?" "No" "Yes")"
ROOT_PASS=""
if [[ "$SET_ROOT" == "Yes" ]]; then
  prompt_password_twice ROOT_PASS "Root password"
fi

# Timezone
while true; do
  read -rp "Timezone (e.g. Europe/Amsterdam): " TZ
  TZ="${TZ//$'\r'/}"; TZ="${TZ//$'\n'/}"
  [[ -n "$TZ" ]] || { echo "Timezone cannot be empty."; continue; }
  if validate_timezone "$TZ"; then break; fi
  echo "Invalid timezone. Examples: Europe/Amsterdam, Europe/Moscow"
done

# Locales presets + custom
LOCALE_PRESET="$(pick_one "Locales" "EN only (en_US)" "EN+RU (en_US + ru_RU)" "Custom")"
case "$LOCALE_PRESET" in
  "EN only (en_US)")
    LOCALES_RAW="en_US.UTF-8 UTF-8"
    LANG_DEFAULT="en_US.UTF-8"
    KEYMAP_DEFAULT="us"
    ;;
  "EN+RU (en_US + ru_RU)")
    LOCALES_RAW="en_US.UTF-8 UTF-8,ru_RU.UTF-8 UTF-8"
    LANG_DEFAULT="en_US.UTF-8"
    KEYMAP_DEFAULT="us"
    ;;
  "Custom")
    read -rp "Locales to enable (comma-separated, example: en_US.UTF-8 UTF-8,ru_RU.UTF-8 UTF-8): " LOCALES_RAW
    LOCALES_RAW="${LOCALES_RAW//$'\r'/}"; LOCALES_RAW="${LOCALES_RAW//$'\n'/}"
    [[ -n "$LOCALES_RAW" ]] || LOCALES_RAW="en_US.UTF-8 UTF-8"
    read -rp "Default LANG (example: en_US.UTF-8): " LANG_DEFAULT
    LANG_DEFAULT="${LANG_DEFAULT//$'\r'/}"; LANG_DEFAULT="${LANG_DEFAULT//$'\n'/}"
    [[ -n "$LANG_DEFAULT" ]] || LANG_DEFAULT="en_US.UTF-8"
    KEYMAP_DEFAULT="us"
    ;;
esac

read -rp "Console KEYMAP (default: $KEYMAP_DEFAULT): " KEYMAP
KEYMAP="${KEYMAP//$'\r'/}"; KEYMAP="${KEYMAP//$'\n'/}"
[[ -n "$KEYMAP" ]] || KEYMAP="$KEYMAP_DEFAULT"

# Kernels
KERNELS="$(pick_one "Kernel(s)" \
  "linux" \
  "linux-lts" \
  "linux-zen" \
  "linux + linux-lts" \
  "linux + linux-zen" \
  "linux-lts + linux-zen" \
  "linux + linux-lts + linux-zen")"

# Desktop
DE="$(pick_one "Desktop Environment" "none" "GNOME" "KDE Plasma" "XFCE" "i3")"

# GPU
GPU_AUTO="$(gpu_detect)"
CPU_AUTO="$(cpu_detect)"
echo "Detected CPU: $CPU_AUTO"
echo "Detected GPU: $GPU_AUTO"

GPU="$(pick_one "GPU driver" \
  "auto ($GPU_AUTO)" \
  "intel" \
  "amd" \
  "nvidia (DKMS)" \
  "intel+nvidia (hybrid, DKMS)" \
  "nouveau (open)" \
  "skip")"
[[ "$GPU" == auto* ]] && GPU="$GPU_AUTO"
[[ "$GPU" == "intel+nvidia (hybrid, DKMS)" ]] && GPU="intel+nvidia"

# Microcode
UCODE="$(pick_one "CPU microcode" "auto ($CPU_AUTO)" "intel-ucode" "amd-ucode" "skip")"
if [[ "$UCODE" == auto* ]]; then
  if [[ "$CPU_AUTO" == "intel" ]]; then UCODE="intel-ucode"
  elif [[ "$CPU_AUTO" == "amd" ]]; then UCODE="amd-ucode"
  else UCODE="skip"
  fi
fi

# Swap
SWAP_OPT="$(pick_one "Swapfile" "no" "2G" "4G" "8G")"
SWAP_GB=0
case "$SWAP_OPT" in
  2G) SWAP_GB=2 ;;
  4G) SWAP_GB=4 ;;
  8G) SWAP_GB=8 ;;
esac

# Steam
INSTALL_STEAM="$(pick_one "Install Steam?" "No" "Yes")"
[[ "$INSTALL_STEAM" == "Yes" ]] && INSTALL_STEAM=1 || INSTALL_STEAM=0

# ===== Package list =====
say "Building package list"

PKGS=(base base-devel linux-firmware networkmanager sudo grub efibootmgr dosfstools mtools os-prober
      vim nano git wget curl)

# Kernels + headers
add_kernel() {
  local k="$1"
  PKGS+=("$k")
  case "$k" in
    linux) PKGS+=(linux-headers) ;;
    linux-lts) PKGS+=(linux-lts-headers) ;;
    linux-zen) PKGS+=(linux-zen-headers) ;;
  esac
}

case "$KERNELS" in
  linux) add_kernel linux ;;
  linux-lts) add_kernel linux-lts ;;
  linux-zen) add_kernel linux-zen ;;
  "linux + linux-lts") add_kernel linux; add_kernel linux-lts ;;
  "linux + linux-zen") add_kernel linux; add_kernel linux-zen ;;
  "linux-lts + linux-zen") add_kernel linux-lts; add_kernel linux-zen ;;
  "linux + linux-lts + linux-zen") add_kernel linux; add_kernel linux-lts; add_kernel linux-zen ;;
esac

# Microcode
[[ "$UCODE" != "skip" ]] && PKGS+=("$UCODE")

# Xorg base if DE chosen
if [[ "$DE" != "none" ]]; then
  PKGS+=(xorg-server xorg-xinit)
fi

# Mesa always
PKGS+=(mesa)

# GPU-specific
case "$GPU" in
  intel) PKGS+=(vulkan-intel) ;;
  amd)   PKGS+=(vulkan-radeon) ;;
  nvidia) PKGS+=(dkms nvidia-dkms nvidia-utils nvidia-settings) ;;
  intel+nvidia) PKGS+=(dkms nvidia-dkms nvidia-utils nvidia-settings vulkan-intel nvidia-prime) ;;
  nouveau) PKGS+=(xf86-video-nouveau) ;;
  skip|unknown) ;;
esac

# DE + Display manager
DM_SERVICE=""
case "$DE" in
  GNOME)
    PKGS+=(gnome gdm)
    DM_SERVICE="gdm"
    ;;
  "KDE Plasma")
    PKGS+=(plasma plasma-wayland-session sddm konsole dolphin)
    DM_SERVICE="sddm"
    ;;
  XFCE)
    PKGS+=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter)
    DM_SERVICE="lightdm"
    ;;
  i3)
    PKGS+=(i3-wm i3status i3lock dmenu lightdm lightdm-gtk-greeter xterm)
    DM_SERVICE="lightdm"
    ;;
  none)
    ;;
esac

say "Installing base system (pacstrap -> /mnt)"
pacstrap /mnt "${PKGS[@]}"

say "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Steam: enable multilib in target before chroot pacman
if [[ "$INSTALL_STEAM" -eq 1 ]]; then
  say "Enabling multilib (for Steam)"
  enable_multilib_in_target
fi

# ===== CHROOT =====
say "Configuring installed system (arch-chroot)"

arch-chroot /mnt /usr/bin/env \
  HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" USER_PASS="$USER_PASS" \
  SET_ROOT="$SET_ROOT" ROOT_PASS="$ROOT_PASS" \
  TZ="$TZ" LOCALES_RAW="$LOCALES_RAW" LANG_DEFAULT="$LANG_DEFAULT" KEYMAP="$KEYMAP" \
  EFI_DIR="$EFI_DIR" GPU="$GPU" DM_SERVICE="$DM_SERVICE" \
  SWAP_GB="$SWAP_GB" INSTALL_STEAM="$INSTALL_STEAM" \
  bash -e <<'CHROOT'
set -euo pipefail

echo "==> timezone"
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

echo "==> locale"
IFS=',' read -r -a LOCALES <<< "$LOCALES_RAW"
for L in "${LOCALES[@]}"; do
  L="$(echo "$L" | xargs)"
  [[ -n "$L" ]] || continue
  esc="$(printf '%s' "$L" | sed 's/[.[\*^$(){}?+|/]/\\&/g')"
  sed -i "s/^#\(${esc}\)$/\1/" /etc/locale.gen || true
done
locale-gen
cat > /etc/locale.conf <<EOF
LANG=$LANG_DEFAULT
EOF

cat > /etc/vconsole.conf <<EOF
KEYMAP=$KEYMAP
EOF

echo "==> hostname/hosts"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "==> users"
useradd -m -G wheel,audio,video,optical,storage "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd

if [[ "$SET_ROOT" == "Yes" ]]; then
  echo "root:$ROOT_PASS" | chpasswd
fi

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

echo "==> network"
systemctl enable NetworkManager

echo "==> swapfile"
if [[ "$SWAP_GB" -gt 0 ]]; then
  fallocate -l "${SWAP_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

echo "==> nvidia tweaks (if needed)"
if [[ "$GPU" == "nvidia" || "$GPU" == "intel+nvidia" ]]; then
  mkdir -p /etc/modprobe.d
  echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia.conf
fi

echo "==> initramfs"
mkinitcpio -P

echo "==> GRUB (UEFI)"
mountpoint -q "$EFI_DIR" || { echo "ESP is not mounted inside chroot at $EFI_DIR"; exit 1; }
grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "==> display manager"
if [[ -n "${DM_SERVICE:-}" ]]; then
  systemctl enable "$DM_SERVICE"
fi

echo "==> steam"
if [[ "$INSTALL_STEAM" -eq 1 ]]; then
  pacman -Syu --noconfirm
  pacman -S --noconfirm steam

  pacman -S --noconfirm lib32-mesa || true
  case "$GPU" in
    intel|intel+nvidia)
      pacman -S --noconfirm lib32-vulkan-intel || true
      ;;
    amd)
      pacman -S --noconfirm lib32-vulkan-radeon || true
      ;;
    nvidia|intel+nvidia)
      pacman -S --noconfirm lib32-nvidia-utils || true
      ;;
  esac
fi

echo
echo "===== DONE ====="
echo "Next (in live ISO):"
echo "  umount -R /mnt"
echo "  reboot"
CHROOT

say "Finished. Log file: $LOG"
echo "Next:"
echo "  umount -R /mnt"
echo "  reboot"
