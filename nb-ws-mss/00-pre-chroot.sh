#!/bin/bash

# Exit on error
set -e

# Function to print verbose messages
verbose() {
  echo -e "\033[1;32m[INFO]\033[0m $1"
}

abort() {
  echo -e "\033[1;31m[ABORT]\033[0m $1" >&2
  exit 1
}

# Pre-setup: Set timezone and NTP
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

# ---------------- Windows side: ensure last Windows partition ends at 50% ----------------
# Strategy:
#   - Find right-most Windows-family partition (EFI/MSR/Basic/Recovery by GUID).
#   - If it's Basic NTFS: shrink so END == HALF.
#   - If it's Recovery: move it so END == HALF (shrink OS NTFS before it if needed to make room).
#   - If it's EFI/MSR: abort (not safely shrinkable/movable here).

# helper: nvme pN vs sdXN
part_path() {
  local d="$1" n="$2"
  [[ "$d" =~ nvme ]] && echo "${d}p${n}" || echo "${d}${n}"
}

partprobe "$TARGET_DISK" || true

SECTOR_SIZE=$(blockdev --getss "$TARGET_DISK")
DISK_BYTES=$(blockdev --getsize64 "$TARGET_DISK")
HALF_BYTES=$(( DISK_BYTES / 2 ))
HALF_END_SEC=$(( (HALF_BYTES / SECTOR_SIZE) - 1 ))
verbose "Disk total: $DISK_BYTES bytes; half-boundary end sector: $HALF_END_SEC"

# Windows GUIDs
WIN_EFI_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
WIN_MSR_GUID='e3c9e316-0b5c-4db8-817d-f92df00215ae'
WIN_BASIC_GUID='ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'  # NTFS OS/Data
WIN_REC_GUID='de94bba4-06d1-4d40-a16a-bfd50179d6ac'   # Recovery

# Collect all partitions on target disk, sorted by start
mapfile -t PARTS < <(lsblk -rno NAME,PATH "$TARGET_DISK" | awk '$1 ~ /[0-9]+$/ {print $2}')
[[ ${#PARTS[@]} -gt 0 ]] || abort "No partitions found on $TARGET_DISK"

# Read geometry for each partition
get_start() { blkid -po udev "$1" | awk -F= '/ID_PART_ENTRY_OFFSET=/{print $2}'; }
get_size()  { blkid -po udev "$1" | awk -F= '/ID_PART_ENTRY_SIZE=/{print $2}'; }
get_type()  { blkid -po udev "$1" | awk -F= '/ID_PART_ENTRY_TYPE=/{print tolower($2)}'; }
get_num()   { lsblk -no PARTN "$1"; }

# Find right-most Windows-family partition
LAST_PATH=""; LAST_NUM=""; LAST_START=""; LAST_END=""; LAST_TYPE=""
for p in "${PARTS[@]}"; do
  tg=$(get_type "$p")
  case "$tg" in
    "$WIN_EFI_GUID"|"$WIN_MSR_GUID"|"$WIN_BASIC_GUID"|"$WIN_REC_GUID")
      s=$(get_start "$p"); z=$(get_size "$p")
      [[ -n "$s" && -n "$z" ]] || continue
      e=$(( s + z - 1 ))
      if [[ -z "$LAST_END" || $e -gt $LAST_END ]]; then
        LAST_PATH="$p"; LAST_NUM=$(get_num "$p"); LAST_START="$s"; LAST_END="$e"; LAST_TYPE="$tg"
      fi
    ;;
  esac
done
[[ -n "$LAST_PATH" ]] || abort "No Windows-family partition detected."
verbose "Right-most Windows-family partition: $LAST_PATH (start=$LAST_START, end=$LAST_END, type=$LAST_TYPE)"

# Half boundary must be to the right of its start
(( HALF_END_SEC > LAST_START )) || abort "Half boundary lies before that partition's start; cannot fit."

# No partition should START beyond half (we don't move arbitrary non-Windows partitions)
for p in "${PARTS[@]}"; do
  s=$(get_start "$p"); [[ -n "$s" ]] || continue
  if (( s > HALF_END_SEC )); then
    abort "Found a partition ($p) starting beyond the half boundary. Aborting to avoid moving non-Windows partitions."
  fi
done

# Helper: NTFS shrink to an absolute END sector
shrink_ntfs_to_end() {
  local part_path="$1" start_sec="$2" new_end_sec="$3"
  local new_size_sec=$(( new_end_sec - start_sec + 1 ))
  local new_size_bytes=$(( new_size_sec * SECTOR_SIZE ))
  local mp

  verbose "Checking NTFS minimum size for $part_path…"
  ntfsresize --info --force "$part_path" >/tmp/ntfs.info 2>&1 || true
  local min_str
  min_str=$(grep -Ei "minimum .*size" /tmp/ntfs.info | grep -Eo '[0-9]+(\.[0-9]+)?[[:space:]]*[KMGT]?B' | tail -n1)
  local min_bytes=""
  if command -v numfmt >/dev/null 2>&1 && [[ -n "$min_str" ]]; then
    min_bytes=$(numfmt --from=iec "$min_str" 2>/dev/null || echo "")
  fi
  if [[ -n "$min_bytes" && $new_size_bytes -lt $min_bytes ]]; then
    abort "Target size ($new_size_bytes) < NTFS minimum ($min_bytes) for $part_path."
  fi

  mp=$(lsblk -no MOUNTPOINT "$part_path" || true)
  [[ -n "$mp" ]] && { verbose "Unmounting $part_path from $mp"; umount -f "$mp" || true; }

  verbose "Resizing NTFS $part_path to $new_size_bytes bytes…"
  ntfsresize --force --size "$new_size_bytes" "$part_path"

  local num ptype
  num=$(get_num "$part_path")
  ptype=$(blkid -po udev "$part_path" | awk -F= '/ID_PART_ENTRY_TYPE=/{print $2}')
  verbose "Updating GPT entry for $part_path (delete+recreate to new end)…"
  sgdisk -d "$num" "$TARGET_DISK"
  sgdisk -n "$num":"$start_sec":"$new_end_sec" -t "$num":$ptype "$TARGET_DISK"
  partprobe "$TARGET_DISK" || true
}

# Case A: last is NTFS Basic → shrink to half
if [[ "$LAST_TYPE" == "$WIN_BASIC_GUID" && "$(blkid -s TYPE -o value "$LAST_PATH" || true)" == "ntfs" ]]; then
  shrink_ntfs_to_end "$LAST_PATH" "$LAST_START" "$HALF_END_SEC"

# Case B: last is Recovery → move it so it ends at half (shrink OS before it if needed)
elif [[ "$LAST_TYPE" == "$WIN_REC_GUID" ]]; then
  REC_OLD_PATH="$LAST_PATH"
  REC_OLD_NUM="$LAST_NUM"
  REC_START="$LAST_START"
  REC_SIZE_SEC=$(get_size "$REC_OLD_PATH")
  REC_NEW_END="$HALF_END_SEC"
  REC_NEW_START=$(( REC_NEW_END - REC_SIZE_SEC + 1 ))

  # Find the partition immediately before Recovery (by max END < REC_START)
  PREV_PATH=""; PREV_END=""
  for p in "${PARTS[@]}"; do
    s=$(get_start "$p"); z=$(get_size "$p"); e=$(( s + z - 1 ))
    [[ $e -lt $REC_START ]] || continue
    if [[ -z "$PREV_END" || $e -gt $PREV_END ]]; then
      PREV_PATH="$p"; PREV_END="$e"
    fi
  done
  [[ -n "$PREV_PATH" ]] || abort "Could not find the partition before Recovery."

  # If not enough gap, shrink the OS NTFS (which should be PREV if it's the OS)
  if (( PREV_END >= REC_NEW_START )); then
    # Need to shrink previous partition so its end == REC_NEW_START-1
    OS_PATH="$PREV_PATH"
    OS_START=$(get_start "$OS_PATH")
    OS_TYPE_GUID=$(get_type "$OS_PATH")
    OS_FS=$(blkid -s TYPE -o value "$OS_PATH" || true)
    [[ "$OS_TYPE_GUID" == "$WIN_BASIC_GUID" && "$OS_FS" == "ntfs" ]] || abort "Previous partition before Recovery is not NTFS Basic; cannot shrink to make room."
    OS_NEW_END=$(( REC_NEW_START - 1 ))
    verbose "Shrinking OS $OS_PATH to end at $OS_NEW_END to make room for Recovery move…"
    shrink_ntfs_to_end "$OS_PATH" "$OS_START" "$OS_NEW_END"
    PREV_END="$OS_NEW_END"
  fi

  # Now we have free space [REC_NEW_START .. REC_NEW_END]; create a new REC there and dd-copy
  ALIGN_WARN=0
  if (( REC_NEW_START <= PREV_END )); then
    abort "After attempted shrink there is still not enough space for Recovery move."
  fi

  verbose "Creating temporary Recovery destination [$REC_NEW_START .. $REC_NEW_END]…"
  # Pick a free partition number
  OCCUPIED=$(lsblk -no PARTN "$TARGET_DISK" | tr '\n' ' ')
  NEW_NUM=2; while grep -qw "$NEW_NUM" <<<"$OCCUPIED"; do NEW_NUM=$((NEW_NUM+1)); done
  sgdisk -n "$NEW_NUM":"$REC_NEW_START":"$REC_NEW_END" -t "$NEW_NUM":$WIN_REC_GUID "$TARGET_DISK"
  partprobe "$TARGET_DISK" || true
  REC_NEW_PATH=$(part_path "$TARGET_DISK" "$NEW_NUM")
  verbose "New Recovery partition: $REC_NEW_PATH"

  # Bitwise copy old → new
  verbose "Copying old Recovery to new location (dd)…"
  dd if="$REC_OLD_PATH" of="$REC_NEW_PATH" bs=4M conv=fsync,noerror status=progress

  sync
  verbose "Deleting old Recovery partition…"
  sgdisk -d "$REC_OLD_NUM" "$TARGET_DISK"
  partprobe "$TARGET_DISK" || true

  # After move, the new right-most Windows partition (Recovery) ends at HALF_END_SEC — as required.
  verbose "Recovery moved: Windows side now ends exactly at half."

# Case C: EFI/MSR last → abort
else
  abort "Right-most Windows partition is EFI/MSR (not safely movable here)."
fi

# ---------------- Create Linux second EFI (550 MiB) and LUKS with the rest ----------------
ALIGN_SEC=2048
NEXT_START=$(( HALF_END_SEC + 1 ))
if (( NEXT_START % ALIGN_SEC != 0 )); then
  NEXT_START=$(( ((NEXT_START + ALIGN_SEC - 1) / ALIGN_SEC) * ALIGN_SEC ))
fi
EFI_SIZE_BYTES=$(( 550 * 1024 * 1024 ))
EFI_SIZE_SEC=$(( EFI_SIZE_BYTES / SECTOR_SIZE ))
EFI_END=$(( NEXT_START + EFI_SIZE_SEC - 1 ))

OCCUPIED=$(lsblk -no PARTN "$TARGET_DISK" | tr '\n' ' ')
EFI_NUM=2; while grep -qw "$EFI_NUM" <<<"$OCCUPIED"; do EFI_NUM=$((EFI_NUM+1)); done
sgdisk -n "$EFI_NUM":"$NEXT_START":"$EFI_END" -t "$EFI_NUM":ef00 "$TARGET_DISK"
partprobe "$TARGET_DISK" || true
LINUX_EFI_PART=$(part_path "$TARGET_DISK" "$EFI_NUM")
verbose "Created Linux EFI: $LINUX_EFI_PART"

NEXT_START=$(( EFI_END + 1 ))
if (( NEXT_START % ALIGN_SEC != 0 )); then
  NEXT_START=$(( ((NEXT_START + ALIGN_SEC - 1) / ALIGN_SEC) * ALIGN_SEC ))
fi
sgdisk -n 0:"$NEXT_START":0 -t 0:8309 "$TARGET_DISK"
partprobe "$TARGET_DISK" || true
LUKS_PART=$(lsblk -o PATH -nr "$TARGET_DISK" | tail -n1)
verbose "Created LUKS partition: $LUKS_PART"

sync
verbose "Partitioning of $TARGET_DISK complete."

# ---------------- LVM on LUKS setup (your original flow) ----------------
verbose "Setting up LVM on LUKS..."
cryptsetup luksFormat "$LUKS_PART" --batch-mode
cryptsetup open "$LUKS_PART" cryptlvm
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

# after creating LINUX_EFI_PART and LUKS_PART and before arch-chroot step:
echo "$LINUX_EFI_PART" > /mnt/linux_efi_part.txt
echo "$LUKS_PART"      > /mnt/luks_part.txt

# Formatting and mounting EFI partition
verbose "Formatting EFI partition..."
mkfs.fat -F32 "$LINUX_EFI_PART"
verbose "Formatted EFI partition as FAT32."

mount --mkdir "$LINUX_EFI_PART" /mnt/boot
verbose "EFI partition mounted on /mnt/boot."

# Add a CacheServer entry after the Include line in the [core] and [extra] sections
verbose "Adding CacheServer entries to pacman.conf."
sed -i '/^\[core\]/,/^Include/ s|^Include.*|&\nCacheServer = http://192.168.112.103:9129/repo/archlinux/$repo/os/$arch|' /etc/pacman.conf
sed -i '/^\[extra\]/,/^Include/ s|^Include.*|&\nCacheServer = http://192.168.112.103:9129/repo/archlinux/$repo/os/$arch|' /etc/pacman.conf
verbose "CacheServer entries added."

# Update mirrorlist
verbose "Updating mirrorlist with reflector."
reflector --save /etc/pacman.d/mirrorlist --protocol https --country France,Germany --latest 5 --sort age
verbose "Mirrorlist updated."

# Refresh package database
verbose "Refreshing package database..."
pacman -Syy
verbose "Package database refreshed."

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
curl -fsSLo /mnt/01-post-chroot.sh https://raw.githubusercontent.com/mschabhuettl/arch-linux-install/refs/heads/main/nb-ws-mss/01-post-chroot.sh
verbose "Post-chroot script downloaded to /mnt/."

# Make the script executable
verbose "Making the post-chroot script executable..."
chmod +x /mnt/01-post-chroot.sh
verbose "Post-chroot script is now executable."

# Note: Up to this point, we have not switched to the chroot environment.
verbose "The base installation is complete. To continue, run 'arch-chroot /mnt' manually and execute './01-post-chroot.sh' inside the chroot environment to proceed with further setup."

verbose "Arch Linux pre-chroot setup is complete."
