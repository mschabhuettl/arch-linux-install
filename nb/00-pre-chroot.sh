#!/bin/bash

# Exit on error
set -e

# Function to print verbose messages
verbose() {
  echo -e "\033[1;32m[INFO]\033[0m $1"
}

# Pre-setup: Set timezone and enable NTP
verbose "Setting up timezone and NTP."
timedatectl set-timezone Europe/Vienna
verbose "Timezone set to Europe/Vienna."
timedatectl set-ntp true
verbose "NTP enabled."

# Disk selection and partitioning
verbose "Listing available NVMe devices..."
nvme list

read -p "Enter the target NVMe device (e.g., /dev/nvme0n1): " TARGET_DISK
verbose "Target disk set to $TARGET_DISK. Starting partitioning..."
echo "$TARGET_DISK" > target_disk.txt

sgdisk -o $TARGET_DISK
sgdisk -n 1:0:+1M -t 1:ef02 $TARGET_DISK
verbose "Created BIOS boot partition (1M, type ef02)."

sgdisk -n 2:0:+550M -t 2:ef00 $TARGET_DISK
verbose "Created EFI partition (550M, type ef00)."

sgdisk -n 3:0:0 -t 3:8309 $TARGET_DISK
verbose "Created LUKS partition (remaining space, type 8309)."

sync
verbose "Partitioning of $TARGET_DISK complete."

# LVM on LUKS setup
verbose "Setting up LVM on LUKS..."
cryptsetup luksFormat ${TARGET_DISK}p3 --batch-mode
cryptsetup open ${TARGET_DISK}p3 cryptlvm
verbose "Opened LUKS container."

pvcreate /dev/mapper/cryptlvm
verbose "Physical volume created."

vgcreate vg /dev/mapper/cryptlvm
verbose "Volume group 'vg' created."

lvcreate -L 32G -n swap vg
verbose "Logical volume 'swap' created (32G)."

lvcreate -L 512G -n root vg
verbose "Logical volume 'root' created (512G)."

lvcreate -l 100%FREE -n home vg
verbose "Logical volume 'home' created with remaining space."

lvreduce -L -256M vg/home
verbose "Reduced 'home' logical volume by 256M."

# Formatting LVM partitions
verbose "Formatting LVM partitions..."
mkfs.ext4 /dev/vg/root
verbose "Formatted root logical volume as ext4."

mkfs.ext4 /dev/vg/home
verbose "Formatted home logical volume as ext4."

mkswap /dev/vg/swap
verbose "Formatted swap logical volume."

# Mounting LVM partitions and swap
verbose "Mounting root logical volume..."
mount /dev/vg/root /mnt
verbose "Root logical volume mounted on /mnt."

mount --mkdir /dev/vg/home /mnt/home
verbose "Home logical volume mounted on /mnt/home."

swapon /dev/vg/swap
verbose "Swap activated."

# Formatting and mounting EFI partition
verbose "Formatting EFI partition..."
mkfs.fat -F32 ${TARGET_DISK}p2
verbose "Formatted EFI partition as FAT32."

mount --mkdir ${TARGET_DISK}p2 /mnt/boot
verbose "EFI partition mounted on /mnt/boot."

# Add a CacheServer entry after the Include line in the [core] and [extra] sections
verbose "Adding CacheServer entries to pacman.conf."
sed -i '/^\[core\]/,/^Include/ s|^Include.*|&\nCacheServer = http://192.168.112.103:9129/repo/archlinux/$repo/os/$arch|' /etc/pacman.conf
sed -i '/^\[extra\]/,/^Include/ s|^Include.*|&\nCacheServer = http://192.168.112.103:9129/repo/archlinux/$repo/os/$arch|' /etc/pacman.conf
verbose "CacheServer entries added."

# Base installation (Base, Linux Kernel, Firmware)
verbose "Starting base installation..."
pacstrap -K /mnt base base-devel linux linux-firmware lvm2 networkmanager iwd openssh tmux nano vi vim amd-ucode man-db man-pages texinfo reflector bash-completion zsh zsh-completions nvme-cli
verbose "Base and additional package installation complete."

# Generate fstab
verbose "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
verbose "fstab generated."

# Modify fstab to replace 'relatime' with 'noatime'
verbose "Modifying fstab to replace 'relatime' with 'noatime'..."
sed -i 's/relatime/noatime/g' /mnt/etc/fstab
verbose "fstab modified."

# Download the post-chroot script directly to /mnt/
verbose "Downloading the post-chroot script directly to /mnt/..."
curl -sSLo /mnt/01-post-chroot.sh https://raw.githubusercontent.com/mschabhuettl/arch-linux-install/refs/heads/main/pc/01-post-chroot.sh
verbose "Post-chroot script downloaded to /mnt/."

# Copy the target_disk.txt to /mnt/
verbose "Copying target_disk.txt to /mnt/..."
cp target_disk.txt /mnt/
verbose "target_disk.txt copied to /mnt/."

# Make the script executable
verbose "Making the post-chroot script executable..."
chmod +x /mnt/01-post-chroot.sh
verbose "Post-chroot script is now executable."

# Note: Up to this point, we have not switched to the chroot environment.
verbose "The base installation is complete. To continue, run 'arch-chroot /mnt' manually and execute './01-post-chroot.sh' inside the chroot environment to proceed with further setup."

verbose "Arch Linux pre-chroot setup is complete."
