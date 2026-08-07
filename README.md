# arch-linux-install

Host-parameterized Arch Linux install scripts for my machines. One shared
implementation in `common/`, per-machine settings in `hosts/`.

**Warning: these scripts irreversibly secure-erase NVMe drives and repartition
the target disk. Do not run them unless you have read them and they match your
hardware.**

## Layout

```
common/00-pre-chroot.sh    live ISO part: erase, partition, LUKS+LVM, pacstrap
common/01-post-chroot.sh   chroot part: system config, packages, services, user
common/lib.sh              shared helpers (logging, run, cache server, checks)
common/defaults.env        shared constants and package sets
hosts/pc.env               PC-Matthias (desktop, NVIDIA, 10GbE)
hosts/nb.env               NB-Matthias (laptop, AMD iGPU)
```

## What the scripts do

`00-pre-chroot.sh` (run from the Arch live ISO):

- Optional NVMe secure erase per controller device (press Enter at the drive
  prompt to skip): `nvme format -s 2`, sanitize crypto-erase, sanitize
  block-erase, `nvme format -s 2` again, with
  progress polling via the sanitize log (JSON, parsed with jq) and a
  confirmation step that shows model and serial and requires typing `ERASE`.
- GPT partitioning of the target namespace device: 1M BIOS boot (ef02),
  1G EFI system partition, remainder LUKS2 (8309).
- LUKS2 with `--allow-discards` and the two no-workqueue performance flags
  persisted in the header, LVM on top (swap, root, home; 256M left
  unallocated for e2scrub snapshots), ext4 with labels, FAT32 ESP.
- CacheServer entries and reflector mirrorlist for the live system, then
  `pacstrap` and an fstab with `noatime`.
- Stages `01-post-chroot.sh` plus its env files into `/mnt/root/install` and
  offers to run it inside `arch-chroot` automatically.

`01-post-chroot.sh` (runs inside the chroot):

- Timezone, locales, keymap, hostname, hosts file, root password.
- systemd-boot with hibernation support (`resume=`), boot entries built from
  the host config, pacman hook for bootloader updates.
- One interactive pacman transaction: KDE Plasma, applications, and the
  GPU / power / timesync packages selected by the host env.
- mkinitcpio configured once (systemd hooks, sd-encrypt, `kms` only on
  amdgpu, NVIDIA modules and power management options on nvidia) with a
  single `mkinitcpio -P`.
- Services: sshd, NetworkManager, plasmalogin (SDDM successor), firewalld,
  cups, avahi with mdns_minimal, bluetooth, fstrim.timer, reflector.timer,
  plus the per-host timesync and power daemon; NVIDIA suspend/resume
  services on nvidia hosts.
- sudo via a validated `/etc/sudoers.d/` drop-in, user creation with zsh,
  XDG user directories, pam_env XDG base dirs, KDE keyboard and locale
  defaults, SSH hardened to key-only logins.

## Usage

On the Arch live ISO:

```
pacman -Sy git           # git is not on the live ISO (jq already is)
git clone https://github.com/mschabhuettl/arch-linux-install.git
cd arch-linux-install
git checkout <tag-or-commit>    # pin the revision you reviewed
./common/00-pre-chroot.sh pc    # or: nb
```

Answer the prompts. At the end the script offers to run `01-post-chroot.sh`
inside `arch-chroot` automatically (default: yes). Afterwards:

```
umount -R /mnt
reboot
```

## Host configuration

Per-host switches in `hosts/<host>.env`:

| Variable        | Meaning                                              |
| --------------- | ---------------------------------------------------- |
| `HOSTNAME`      | System hostname                                      |
| `SWAP_SIZE`     | Swap LV size (sized for hibernation)                 |
| `ROOT_SIZE`     | Root LV size (home gets the rest)                    |
| `GPU`           | `nvidia` or `amdgpu`                                 |
| `TIMESYNC`      | `timesyncd` or `chrony`                              |
| `POWER`         | `ppd` (power-profiles-daemon) or `tlp`               |
| `MODULES_EXTRA` | Extra initramfs modules (e.g. NIC drivers)           |
| `EXTRA_PKGS`    | Host-only packages, same transaction as the rest     |
| `CMDLINE_EXTRA` | Appended to the kernel command line                  |

Shared constants (user name, VG name, timezone, cache server, package sets)
live in `common/defaults.env`.

## Notes

- SSH allows key-based logins only (`PasswordAuthentication no`,
  `PermitRootLogin no`). Deploy a public key before relying on remote access.
- pacman runs interactively by design; answer its prompts.
- `01-post-chroot.sh` is not idempotent. If it fails mid-run, fix the issue
  and continue manually via `arch-chroot /mnt` (the staged files are kept at
  `/mnt/root/install` in that case).
- plymouth is installed but intentionally left unconfigured for now.
