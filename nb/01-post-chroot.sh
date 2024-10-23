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
echo "NB-Matthias" > /etc/hostname
verbose "Locale, keymap, and hostname set."

# Edit /etc/hosts
verbose "Editing /etc/hosts."
echo "127.0.0.1       localhost" >> /etc/hosts
echo "::1             localhost" >> /etc/hosts
echo "127.0.1.1       NB-Matthias" >> /etc/hosts
verbose "/etc/hosts configured."

# Generate initramfs
verbose "Editing /etc/mkinitcpio.conf and generating initramfs."
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
verbose "Initramfs generated."

# Set root password
verbose "Setting root password."
passwd

# Install and configure bootloader
verbose "Installing bootloader and configuring entries."
bootctl install

UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
SWAP_UUID=$(blkid -s UUID -o value /dev/mapper/vg-swap)
verbose "UUID of system partition: $UUID"
verbose "UUID of swap partition: $SWAP_UUID"

echo -e "default  arch.conf
timeout  4
console-mode max
editor   no" > /boot/loader/loader.conf

echo -e "title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=$UUID=cryptlvm root=/dev/vg/root resume=UUID=$SWAP_UUID rd.luks.options=timeout=0 rootflags=x-systemd.device-timeout=0 vt.global_cursor_default=0 ipv6.disable=1" > /boot/loader/entries/arch.conf

echo -e "title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux-fallback.img
options rd.luks.name=$UUID=cryptlvm root=/dev/vg/root resume=UUID=$SWAP_UUID rd.luks.options=timeout=0 rootflags=x-systemd.device-timeout=0 vt.global_cursor_default=0 ipv6.disable=1" > /boot/loader/entries/arch-fallback.conf

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

# Install essential packages
verbose "Installing essential packages."
pacman -S plasma-desktop ttf-dejavu breeze breeze-gtk kde-gtk-config xdg-user-dirs sddm sddm-kcm konsole plasma-nm plasma-pa pulseaudio pulseaudio-bluetooth powerdevil firewalld ipset thunderbird firefox plasma-browser-integration kwallet-pam kwalletmanager kinfocenter keepassxc bluez bluez-utils bluedevil networkmanager-vpnc dolphin dolphin-plugins ark htop gimp kate vlc libreoffice-fresh print-manager gwenview okular spectacle gparted ntfs-3g yakuake git nm-connection-editor acpid dbus avahi cups nss-mdns chrony plasma-systemmonitor kscreen
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
systemctl disable systemd-timesyncd.service
systemctl enable chronyd.service
verbose "Time synchronization configured with chrony."

# Install Mesa drivers and configure
verbose "Installing Mesa drivers."
pacman -S mesa
verbose "Mesa drivers installed."

sed -i 's/^MODULES=.*/MODULES=(amdgpu)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install additional packages
verbose "Installing additional packages."
pacman -S plasma-workspace xorg-xwayland
verbose "Additional packages installed."

# Set environment variables in /etc/security/pam_env.conf
verbose "Setting environment variables in /etc/security/pam_env.conf."
echo "XDG_CONFIG_HOME   DEFAULT=@{HOME}/.config" >> /etc/security/pam_env.conf
verbose "Environment variables set."
