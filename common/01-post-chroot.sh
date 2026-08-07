#!/bin/bash
#
# 01-post-chroot.sh - runs INSIDE the arch-chroot of the freshly installed
# system. Normally invoked automatically by 00-pre-chroot.sh via:
#   arch-chroot /mnt /root/install/01-post-chroot.sh
#
# Expects lib.sh, defaults.env, host.env and state.env next to itself
# (staged there by 00-pre-chroot.sh).

# Variables referenced below are assigned in the sourced env files.
# shellcheck disable=SC2154
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=defaults.env
source "$SCRIPT_DIR/defaults.env"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/host.env"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/state.env"

require_root
require_vars USERNAME VG_NAME TIMEZONE KEYMAP LOCALE_LANG GEN_LOCALES \
  CACHE_SERVER REFLECTOR_COUNTRIES COMMON_PKGS HOSTNAME SWAP_SIZE ROOT_SIZE \
  GPU TIMESYNC POWER MODULES_EXTRA EXTRA_PKGS CMDLINE_EXTRA TARGET_DISK HOST

verbose "Running post-chroot setup for host '$HOST' ($HOSTNAME) on $TARGET_DISK."

# --- host switches -> concrete settings --------------------------------------
case "$GPU" in
  nvidia)
    GPU_PKGS=(nvidia-open-dkms)
    GPU_MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
    GPU_CMDLINE="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
    # The kms hook must be omitted with the NVIDIA driver.
    USE_KMS_HOOK=0
    ;;
  amdgpu)
    GPU_PKGS=(mesa)
    GPU_MODULES=(amdgpu)
    GPU_CMDLINE=""
    USE_KMS_HOOK=1
    ;;
  *)
    die "Unknown GPU '$GPU' (expected nvidia or amdgpu)."
    ;;
esac

case "$POWER" in
  ppd) POWER_PKGS=(power-profiles-daemon) ;;
  tlp) POWER_PKGS=(tlp) ;;
  *)   die "Unknown POWER '$POWER' (expected ppd or tlp)." ;;
esac

case "$TIMESYNC" in
  timesyncd) TIMESYNC_PKGS=() ;;
  chrony)    TIMESYNC_PKGS=(chrony) ;;
  *)         die "Unknown TIMESYNC '$TIMESYNC' (expected timesyncd or chrony)." ;;
esac

# --- timezone / clock / locale / hostname ------------------------------------
verbose "Setting timezone and hardware clock."
run ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
run hwclock --utc --systohc

verbose "Generating locales."
for locale in "${GEN_LOCALES[@]}"; do
  run sed -i "/^#${locale} UTF-8/s/^#//" /etc/locale.gen
done
run locale-gen

echo "LANG=$LOCALE_LANG" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
verbose "Locale, keymap and hostname ($HOSTNAME) set."

verbose "Configuring /etc/hosts."
cat >> /etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME
EOF

# --- root password -----------------------------------------------------------
verbose "Setting root password."
run passwd

# --- pacman / mirrors on the target system -----------------------------------
verbose "Adding CacheServer entries to pacman.conf."
add_cache_server /etc/pacman.conf

verbose "Updating mirrorlist with reflector."
run reflector --save /etc/pacman.d/mirrorlist --protocol https \
  --country "$REFLECTOR_COUNTRIES" --latest 5 --sort age

verbose "Refreshing package databases..."
run pacman -Syy

# --- bootloader --------------------------------------------------------------
verbose "Installing systemd-boot."
run bootctl install

LUKS_UUID=$(blkid -s UUID -o value "${TARGET_DISK}p3")
SWAP_UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/swap")
verbose "LUKS partition UUID: $LUKS_UUID"
verbose "Swap LV UUID: $SWAP_UUID"

CMDLINE="rd.luks.name=$LUKS_UUID=cryptlvm root=/dev/$VG_NAME/root resume=UUID=$SWAP_UUID rd.luks.options=timeout=0 rootflags=x-systemd.device-timeout=0 vt.global_cursor_default=0"
if [[ -n "$GPU_CMDLINE" ]]; then
  CMDLINE+=" $GPU_CMDLINE"
fi
CMDLINE+=" ipv6.disable=1 quiet"
if [[ -n "$CMDLINE_EXTRA" ]]; then
  CMDLINE+=" $CMDLINE_EXTRA"
fi

cat > /boot/loader/loader.conf <<EOF
default  arch.conf
timeout  4
console-mode max
editor   no
EOF

cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options $CMDLINE
EOF

cat > /boot/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux-fallback.img
options $CMDLINE
EOF
verbose "Bootloader installed and configured."

verbose "Creating pacman hook for systemd-boot updates."
run install -d -m 755 /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/95-systemd-boot.hook <<'EOF'
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
EOF

# --- package installation (single interactive transaction) -------------------
verbose "Installing packages (interactive, answer pacman's prompts)."
pkgs=("${COMMON_PKGS[@]}" "${GPU_PKGS[@]}" "${POWER_PKGS[@]}" "${TIMESYNC_PKGS[@]}" "${EXTRA_PKGS[@]}")
run pacman -S "${pkgs[@]}"

# --- initramfs (write all configs first, rebuild once) -----------------------
verbose "Configuring mkinitcpio."
hooks=(base systemd autodetect microcode modconf)
if [[ "$USE_KMS_HOOK" -eq 1 ]]; then
  hooks+=(kms)
fi
hooks+=(keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)
run sed -i "s/^HOOKS=.*/HOOKS=(${hooks[*]})/" /etc/mkinitcpio.conf

modules=("${MODULES_EXTRA[@]}" "${GPU_MODULES[@]}" vfat fat)
run sed -i "s/^MODULES=.*/MODULES=(${modules[*]})/" /etc/mkinitcpio.conf

if [[ "$GPU" == "nvidia" ]]; then
  echo "options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp" \
    > /etc/modprobe.d/nvidia-power-management.conf
  verbose "NVIDIA power management modprobe options written."
fi

verbose "Generating initramfs (single pass)."
run mkinitcpio -P

# --- services ----------------------------------------------------------------
verbose "Configuring services."
run systemctl enable sshd.service NetworkManager.service fstrim.timer \
  avahi-daemon.service cups.service bluetooth.service firewalld.service \
  plasmalogin.service

# reflector: enable only the timer (the service would also run on every boot).
run sed -i 's/^#\s*--country/--country/' /etc/xdg/reflector/reflector.conf
run systemctl enable reflector.timer

# mDNS via avahi/nss-mdns instead of systemd-resolved.
run sed -i '/^hosts:/ s/resolve/mdns_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf
run systemctl disable systemd-resolved.service

case "$TIMESYNC" in
  timesyncd)
    run systemctl enable systemd-timesyncd.service
    ;;
  chrony)
    run systemctl disable systemd-timesyncd.service
    run systemctl enable chronyd.service
    ;;
esac

case "$POWER" in
  ppd)
    run systemctl enable power-profiles-daemon.service
    ;;
  tlp)
    run systemctl enable tlp.service
    # Per TLP docs: mask rfkill units to avoid conflicts with radio switching.
    run systemctl mask systemd-rfkill.service systemd-rfkill.socket
    ;;
esac

if [[ "$GPU" == "nvidia" ]]; then
  run systemctl enable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service
fi
verbose "Services configured."

# --- sudo --------------------------------------------------------------------
verbose "Configuring sudo (wheel group) via /etc/sudoers.d/ drop-in."
sudoers_tmp=$(mktemp)
echo '%wheel ALL=(ALL:ALL) ALL' > "$sudoers_tmp"
run visudo -cf "$sudoers_tmp"
run install -m 0440 "$sudoers_tmp" /etc/sudoers.d/10-wheel
rm -f "$sudoers_tmp"

# --- user --------------------------------------------------------------------
verbose "Creating user '$USERNAME'."
run useradd -m -g users -G wheel,audio,video,games,power -s /bin/zsh "$USERNAME"
verbose "Setting password for '$USERNAME'."
run passwd "$USERNAME"

# Create the XDG user directories (~/Downloads etc.) deterministically now.
# setpriv avoids PAM (unlike runuser/su), which keeps this chroot-safe.
verbose "Creating XDG user directories for '$USERNAME'."
run setpriv --reuid "$USERNAME" --regid users --init-groups \
  env HOME="/home/$USERNAME" LC_ALL="$LOCALE_LANG" xdg-user-dirs-update

# --- environment -------------------------------------------------------------
verbose "Setting XDG base directory variables in /etc/security/pam_env.conf."
cat >> /etc/security/pam_env.conf <<'EOF'
XDG_CONFIG_HOME  DEFAULT=@{HOME}/.config
XDG_CACHE_HOME   DEFAULT=@{HOME}/.cache
XDG_DATA_HOME    DEFAULT=@{HOME}/.local/share
XDG_STATE_HOME   DEFAULT=@{HOME}/.local/state
EOF

# --- per-user KDE defaults ---------------------------------------------------
verbose "Creating /home/$USERNAME/.config."
run install -d -m 755 -o "$USERNAME" -g users "/home/$USERNAME/.config"

verbose "Creating kxkbrc keyboard layout configuration."
install -m 600 -o "$USERNAME" -g users /dev/stdin "/home/$USERNAME/.config/kxkbrc" <<'EOF'
[Layout]
LayoutList=at
Model=pc105
Use=true
VariantList=nodeadkeys
EOF

verbose "Creating plasma-localerc."
install -m 600 -o "$USERNAME" -g users /dev/stdin "/home/$USERNAME/.config/plasma-localerc" <<'EOF'
[Formats]
LANG=en_US.UTF-8
LC_ADDRESS=de_AT.UTF-8
LC_MEASUREMENT=de_AT.UTF-8
LC_MONETARY=de_AT.UTF-8
LC_NAME=de_AT.UTF-8
LC_NUMERIC=de_AT.UTF-8
LC_PAPER=de_AT.UTF-8
LC_TELEPHONE=de_AT.UTF-8
LC_TIME=de_AT.UTF-8
EOF

# --- ssh hardening -----------------------------------------------------------
verbose "Writing SSH hardening drop-in (key-only login)."
run install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF

verbose "Post-chroot setup complete."
verbose "Reminder: SSH allows key-based logins only. Deploy your public key to"
verbose "/home/$USERNAME/.ssh/authorized_keys before relying on remote access."
verbose "plasmalogin.service is enabled; the system boots into the greeter."
