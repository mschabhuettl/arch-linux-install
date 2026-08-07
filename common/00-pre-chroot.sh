#!/bin/bash
#
# 00-pre-chroot.sh - run from the Arch Linux live ISO.
#
# Usage: ./common/00-pre-chroot.sh <host>        (host: pc | nb | ...)
#
# Secure-erases the selected NVMe drives, partitions the target disk
# (GPT: 1M BIOS boot, 1G ESP, rest LUKS2 + LVM), installs the base system
# and stages 01-post-chroot.sh into the new root at /root/install.
#
# WARNING: destructive. Read the script before running it.

# Variables referenced below are assigned in the sourced env files.
# shellcheck disable=SC2154
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=defaults.env
source "$SCRIPT_DIR/defaults.env"

usage() {
  echo "usage: ${0##*/} <host>"
  echo "  host: name of a config in hosts/ (e.g. pc, nb)"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

HOST="$1"
HOST_ENV="$REPO_DIR/hosts/$HOST.env"
if [[ ! -f "$HOST_ENV" ]]; then
  die "Unknown host '$HOST' ($HOST_ENV not found)."
fi
# shellcheck source=/dev/null
source "$HOST_ENV"

require_root
require_tools timedatectl nvme jq sgdisk cryptsetup pvcreate vgcreate \
  lvcreate lvreduce mkfs.ext4 mkfs.fat mkswap reflector pacstrap genfstab \
  arch-chroot lsblk udevadm partprobe
require_vars VG_NAME TIMEZONE CACHE_SERVER REFLECTOR_COUNTRIES \
  SANITIZE_TIMEOUT PACSTRAP_PKGS HOSTNAME SWAP_SIZE ROOT_SIZE UCODE

case "$UCODE" in
  amd|intel) ;;
  *) die "Unknown UCODE '$UCODE' (expected amd or intel)." ;;
esac

verbose "Installing host '$HOST' ($HOSTNAME)."

# --- timezone / NTP on the live system ---------------------------------------
verbose "Setting up timezone and NTP."
run timedatectl set-timezone "$TIMEZONE"
run timedatectl set-ntp true

# --- secure erase ------------------------------------------------------------
validate_controller() {
  local device="$1"
  if [[ ! "$device" =~ ^/dev/nvme[0-9]+$ ]]; then
    die "Unsupported device format: $device (only controller devices like /dev/nvme0)."
  fi
  if [[ ! -e "$device" ]]; then
    die "Device $device does not exist."
  fi
}

check_nvme_sanitize() {
  local device="$1"
  local deadline=$(( SECONDS + SANITIZE_TIMEOUT ))
  local output sprog sstat status
  while true; do
    if ! output=$(nvme sanitize-log "$device" -o json 2>/dev/null); then
      die "Failed to read sanitize log for $device."
    fi
    sprog=$(jq -r '.sprog // empty' <<<"$output")
    sstat=$(jq -r '.sstat // empty' <<<"$output")
    if [[ -z "$sprog" || -z "$sstat" ]]; then
      die "Sanitize log for $device is missing sprog/sstat (unexpected nvme-cli JSON)."
    fi
    # SSTAT bits 2:0 - 1: completed, 2: in progress, 3: failed,
    # 4: completed (no-deallocate). SPROG 65535 means 100%.
    status=$(( sstat & 0x7 ))
    if [[ "$sprog" -eq 65535 ]] && { [[ "$status" -eq 1 ]] || [[ "$status" -eq 4 ]]; }; then
      verbose "Sanitize completed on $device (SPROG=$sprog, SSTAT=$sstat)."
      return 0
    fi
    if [[ "$status" -eq 3 ]]; then
      die "Sanitize FAILED on $device (SSTAT=$sstat)."
    fi
    if (( SECONDS >= deadline )); then
      die "Sanitize on $device did not finish within ${SANITIZE_TIMEOUT}s (SPROG=$sprog, SSTAT=$sstat)."
    fi
    verbose "Waiting for sanitize on $device... (SPROG=$sprog, SSTAT=$sstat)"
    sleep 5
  done
}

secure_erase_nvme() {
  local device="$1"
  run nvme format "$device" -s 2 -n 1 --force
  run nvme sanitize "$device" -a start-crypto-erase
  check_nvme_sanitize "$device"
  run nvme sanitize "$device" -a start-block-erase
  check_nvme_sanitize "$device"
  run nvme format "$device" -s 2 -n 1 --force
}

verbose "Listing available NVMe devices..."
nvme list
verbose "Secure erase targets must be controller devices (/dev/nvmeX),"
verbose "NOT namespace devices like /dev/nvmeXnY or /dev/ngXnY."

read -r -p "Enter controller device(s) to secure-erase (space-separated, e.g. /dev/nvme0), or press Enter to skip: " -a selected_drives
if [[ ${#selected_drives[@]} -eq 0 ]]; then
  verbose "No devices entered; skipping secure erase."
else
  for drive in "${selected_drives[@]}"; do
    validate_controller "$drive"
  done

  verbose "The following devices will be COMPLETELY AND IRREVERSIBLY ERASED:"
  for drive in "${selected_drives[@]}"; do
    ctrl_json=$(nvme id-ctrl "$drive" -o json)
    model=$(jq -r '.mn' <<<"$ctrl_json" | xargs)
    serial=$(jq -r '.sn' <<<"$ctrl_json" | xargs)
    verbose "  $drive  model: $model  serial: $serial"
  done

  read -r -p "Type ERASE (all caps) to continue: " erase_confirm
  if [[ "$erase_confirm" != "ERASE" ]]; then
    die "Aborted by user."
  fi

  for drive in "${selected_drives[@]}"; do
    secure_erase_nvme "$drive"
  done
  verbose "Secure erase completed successfully."
fi

# --- target disk selection & partitioning ------------------------------------
verbose "Listing NVMe devices for installation target selection..."
nvme list

read -r -p "Enter the target NVMe namespace device for installation (e.g. /dev/nvme0n1): " TARGET_DISK
if [[ ! "$TARGET_DISK" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
  die "Invalid target: $TARGET_DISK (expected a namespace device like /dev/nvme0n1)."
fi
if [[ ! -b "$TARGET_DISK" ]]; then
  die "$TARGET_DISK is not a block device."
fi

verbose "Selected target disk:"
lsblk "$TARGET_DISK"
read -r -p "Partition $TARGET_DISK now? ALL DATA ON IT WILL BE LOST. [y/N] " part_confirm
if [[ "$part_confirm" != [yY] ]]; then
  die "Aborted by user."
fi

verbose "Partitioning $TARGET_DISK..."
run sgdisk -o "$TARGET_DISK"
run sgdisk -n 1:0:+1M -t 1:ef02 "$TARGET_DISK"
verbose "Created BIOS boot partition (1M, type ef02)."
run sgdisk -n 2:0:+1G -t 2:ef00 "$TARGET_DISK"
verbose "Created EFI system partition (1G, type ef00)."
run sgdisk -n 3:0:0 -t 3:8309 "$TARGET_DISK"
verbose "Created LUKS partition (remaining space, type 8309)."
run sync
# sgdisk only asks the kernel to re-read the partition table; udev creates the
# /dev/...p3 node asynchronously. Wait for it, otherwise cryptsetup below can
# race ahead and fail with "device does not exist" on a freshly wiped disk.
run partprobe "$TARGET_DISK"
run udevadm settle
if [[ ! -b "${TARGET_DISK}p3" ]]; then
  die "Partition node ${TARGET_DISK}p3 did not appear after partitioning."
fi
verbose "Partitioning of $TARGET_DISK complete."

# --- LUKS + LVM --------------------------------------------------------------
verbose "Setting up LVM on LUKS..."
verbose "cryptsetup will ask you to set the passphrase (twice), then to unlock once."
run cryptsetup luksFormat "${TARGET_DISK}p3" --batch-mode
# --persistent writes the flags into the LUKS2 header, so sd-encrypt applies
# them automatically on every boot (TRIM through dm-crypt + NVMe performance).
run cryptsetup open "${TARGET_DISK}p3" cryptlvm \
  --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent
verbose "Opened LUKS container (discard + no-workqueue flags persisted)."

run pvcreate /dev/mapper/cryptlvm
run vgcreate "$VG_NAME" /dev/mapper/cryptlvm
run lvcreate -L "$SWAP_SIZE" -n swap "$VG_NAME"
run lvcreate -L "$ROOT_SIZE" -n root "$VG_NAME"
run lvcreate -l 100%FREE -n home "$VG_NAME"
# Keep 256M unallocated in the VG so e2scrub_all can create snapshots.
run lvreduce -f -L -256M "$VG_NAME/home"

verbose "Formatting logical volumes..."
run mkfs.ext4 -L root "/dev/$VG_NAME/root"
run mkfs.ext4 -L home "/dev/$VG_NAME/home"
run mkswap -L swap "/dev/$VG_NAME/swap"

verbose "Mounting volumes..."
run mount "/dev/$VG_NAME/root" /mnt
run mount --mkdir "/dev/$VG_NAME/home" /mnt/home
run swapon "/dev/$VG_NAME/swap"

verbose "Formatting and mounting the EFI system partition..."
run mkfs.fat -F32 -n ESP "${TARGET_DISK}p2"
run mount -t vfat -o fmask=0137,dmask=0027 --mkdir "${TARGET_DISK}p2" /mnt/boot

# --- package mirrors & base install ------------------------------------------
verbose "Adding CacheServer entries to the live system's pacman.conf."
add_cache_server /etc/pacman.conf

verbose "Updating mirrorlist with reflector."
run reflector --save /etc/pacman.d/mirrorlist --protocol https \
  --country "$REFLECTOR_COUNTRIES" --latest 5 --sort age

verbose "Refreshing package databases..."
run pacman -Syy

verbose "Installing the base system with pacstrap..."
run pacstrap -K /mnt "${PACSTRAP_PKGS[@]}" "${UCODE}-ucode"

# --- fstab -------------------------------------------------------------------
verbose "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab
run sed -i 's/relatime/noatime/g' /mnt/etc/fstab
run sed -i '/\/boot/ s/fmask=[0-9]\{4\}/fmask=0137/; s/dmask=[0-9]\{4\}/dmask=0027/' /mnt/etc/fstab
verbose "fstab written (noatime, ESP fmask=0137/dmask=0027)."

# --- stage the post-chroot step ----------------------------------------------
STAGE_DIR=/mnt/root/install
verbose "Staging post-chroot files to $STAGE_DIR..."
run install -d -m 700 "$STAGE_DIR"
run install -m 700 "$SCRIPT_DIR/01-post-chroot.sh" "$STAGE_DIR/01-post-chroot.sh"
run install -m 600 "$SCRIPT_DIR/lib.sh" "$STAGE_DIR/lib.sh"
run install -m 600 "$SCRIPT_DIR/defaults.env" "$STAGE_DIR/defaults.env"
run install -m 600 "$HOST_ENV" "$STAGE_DIR/host.env"
cat > "$STAGE_DIR/state.env" <<EOF
# Generated by 00-pre-chroot.sh
TARGET_DISK="$TARGET_DISK"
HOST="$HOST"
EOF
verbose "Staged 01-post-chroot.sh, lib.sh, env files and state.env."

# --- hand over to the chroot -------------------------------------------------
read -r -p "Run 01-post-chroot.sh inside arch-chroot now? [Y/n] " chroot_confirm
if [[ "$chroot_confirm" == [nN] ]]; then
  verbose "Manual mode. To continue:"
  verbose "  arch-chroot /mnt /root/install/01-post-chroot.sh"
  verbose "Afterwards: rm -rf /mnt/root/install, then umount -R /mnt and reboot."
  exit 0
fi

verbose "Entering chroot to run 01-post-chroot.sh..."
if arch-chroot /mnt /root/install/01-post-chroot.sh; then
  run rm -rf "$STAGE_DIR"
  verbose "Removed staging files from /root/install."
  verbose "Installation complete. Next: umount -R /mnt && reboot"
else
  error_message "01-post-chroot.sh failed inside the chroot."
  error_message "The staged files are kept at /mnt/root/install."
  error_message "Fix the problem, then continue manually with: arch-chroot /mnt"
  error_message "Note: 01-post-chroot.sh is not idempotent; re-run only the missing steps."
  exit 1
fi
