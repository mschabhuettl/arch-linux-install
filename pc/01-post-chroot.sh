#!/bin/bash

# Exit on error
set -e

# Function to print verbose messages
verbose() {
  echo -e "\033[1;32m[INFO]\033[0m $1"
}

# Set timezone and hardware clock
verbose "Setting timezone and hardware clock."
ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime
hwclock --systohc
verbose "Timezone and hardware clock set."

# Generate locales
verbose "Generating locales."
sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#de_AT.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
verbose "Locales generated."

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=de-latin1-nodeadkeys" > /etc/vconsole.conf
echo "PC-Matthias" > /etc/hostname
verbose "Locale, keymap, and hostname set."

# Edit /etc/hosts
verbose "Editing /etc/hosts."
echo "127.0.0.1       localhost" >> /etc/hosts
echo "::1             localhost" >> /etc/hosts
echo "127.0.1.1       PC-Matthias" >> /etc/hosts
verbose "/etc/hosts configured."

# Generate initramfs
verbose "Editing /etc/mkinitcpio.conf and generating initramfs."
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
verbose "Initramfs generated."

# Set root password
verbose "Setting root password."
passwd

# Add a CacheServer entry after the Include line in the [core] and [extra] sections
verbose "Adding CacheServer entries to pacman.conf."
sed -i '/^\[core\]/,/^Include/ s|^Include.*|&\nCacheServer = http://192.168.112.103:9129/repo/archlinux/$repo/os/$arch|' /etc/pacman.conf
sed -i '/^\[extra\]/,/^Include/ s|^Include.*|&\nCacheServer = http://192.168.112.103:9129/repo/archlinux/$repo/os/$arch|' /etc/pacman.conf
verbose "CacheServer entries added."

# Disk selection
verbose "Reading target disk from target_disk.txt..."
TARGET_DISK=$(cat target_disk.txt)
verbose "Target disk set to $TARGET_DISK. Proceeding with the setup."

# Install and configure bootloader
verbose "Installing bootloader and configuring entries."
bootctl install

UUID=$(blkid -s UUID -o value ${TARGET_DISK}p3)
SWAP_UUID=$(blkid -s UUID -o value /dev/mapper/vg-swap)
verbose "UUID of LUKS partition: $UUID"
verbose "UUID of swap partition: $SWAP_UUID"

echo -e "default  arch.conf
timeout  4
console-mode max
editor   no" > /boot/loader/loader.conf

echo -e "title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=$UUID=cryptlvm root=/dev/vg/root resume=UUID=$SWAP_UUID rd.luks.options=timeout=0 rootflags=x-systemd.device-timeout=0 vt.global_cursor_default=0 nvidia_drm.modeset=1 nvidia_drm.fbdev=1 ipv6.disable=1 quiet" > /boot/loader/entries/arch.conf

echo -e "title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux-fallback.img
options rd.luks.name=$UUID=cryptlvm root=/dev/vg/root resume=UUID=$SWAP_UUID rd.luks.options=timeout=0 rootflags=x-systemd.device-timeout=0 vt.global_cursor_default=0 nvidia_drm.modeset=1 nvidia_drm.fbdev=1 ipv6.disable=1 quiet" > /boot/loader/entries/arch-fallback.conf

verbose "Bootloader installed and configured."

# Create pacman hook for systemd-boot
verbose "Creating pacman hook for systemd-boot."
mkdir -p /etc/pacman.d/hooks
echo -e "[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service" > /etc/pacman.d/hooks/95-systemd-boot.hook
verbose "Pacman hook for systemd-boot created."

# Update mirrorlist
verbose "Updating mirrorlist with reflector."
reflector --save /etc/pacman.d/mirrorlist --protocol https --country France,Germany --latest 5 --sort age
verbose "Mirrorlist updated."

# Refresh package database
verbose "Refreshing package database..."
pacman -Syy
verbose "Package database refreshed."

# Install essential packages
verbose "Installing essential packages."
pacman -S plasma-meta kde-graphics-meta kde-multimedia-meta kde-network-meta kde-sdk-meta kde-system-meta kde-utilities-meta ttf-dejavu breeze xdg-user-dirs sddm pulseaudio pulseaudio-bluetooth firewalld ipset thunderbird firefox keepassxc bluez bluez-utils networkmanager-vpnc htop gimp vlc libreoffice-fresh gparted ntfs-3g git nm-connection-editor acpid dbus avahi cups nss-mdns qt5-wayland android-tools scrcpy system-config-printer linux-headers dkms dosfstools tree power-profiles-daemon xdg-desktop-portal efibootmgr
verbose "Essential packages installed."

# Configure services
verbose "Configuring services."
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable sshd.service
systemctl enable NetworkManager.service
sed -i 's/^#\s*--country/--country/' /etc/xdg/reflector/reflector.conf
systemctl enable reflector.timer
systemctl enable reflector.service
systemctl enable fstrim.timer
sed -i '/^hosts:/ s/resolve/mdns_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf
systemctl disable systemd-resolved.service
systemctl enable avahi-daemon.service
systemctl enable acpid.service
systemctl enable cups.service
systemctl enable bluetooth.service
verbose "Services configured."

# Create user and configure sudo
verbose "Creating user and configuring sudo."
useradd -m -g users -s /bin/zsh mss
passwd mss
sed -i 's/^#\s*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
gpasswd -a mss wheel
gpasswd -a mss audio
gpasswd -a mss video
gpasswd -a mss games
gpasswd -a mss power
verbose "User 'mss' created and configured."

# Enable time synchronization
verbose "Enabling time synchronization."
systemctl enable systemd-timesyncd.service
verbose "Time synchronization enabled."

# Install NVIDIA drivers and configure
verbose "Installing NVIDIA drivers and configuring."
pacman -S nvidia-dkms
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P
echo "options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp" > /etc/modprobe.d/nvidia-power-management.conf
mkinitcpio -P
systemctl enable nvidia-suspend.service
systemctl enable nvidia-hibernate.service
verbose "NVIDIA drivers installed and configured."

# Install additional packages
verbose "Installing additional packages."
pacman -S plasma-workspace xorg-xwayland
verbose "Additional packages installed."

# Set environment variables in /etc/security/pam_env.conf
verbose "Setting environment variables in /etc/security/pam_env.conf."
echo "XDG_CONFIG_HOME   DEFAULT=@{HOME}/.config" >> /etc/security/pam_env.conf
echo "XDG_CACHE_HOME   DEFAULT=@{HOME}/.cache" >> /etc/security/pam_env.conf
echo "XDG_DATA_HOME   DEFAULT=@{HOME}/.local/share" >> /etc/security/pam_env.conf
echo "XDG_STATE_HOME   DEFAULT=@{HOME}/.local/state" >> /etc/security/pam_env.conf
verbose "Environment variables set."

# Enable firewall service
verbose "Enabling Firewalld service."
systemctl enable firewalld.service
verbose "Firewalld service enabled."

# Final instructions to exit and reboot
verbose "Setup complete. To exit the chroot environment, type 'exit', and then reboot the system by typing 'reboot'."
