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
hosts/nb-nee.env           NB-Nicola (laptop, Intel iGPU)
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
  the host config (including the amd/intel microcode initrd), pacman hook for bootloader updates.
- One interactive pacman transaction: KDE Plasma, applications, and the
  GPU / power / timesync packages selected by the host env.
- mkinitcpio configured once (systemd hooks, sd-encrypt, `kms` on
  amdgpu and intel, NVIDIA modules and power management options on nvidia) with a
  single `mkinitcpio -P`.
- Services: sshd, NetworkManager, plasmalogin (SDDM successor), firewalld,
  cups, avahi with mdns_minimal, bluetooth, fstrim.timer, reflector.timer,
  plus the per-host timesync and power daemon; NVIDIA suspend/resume
  services on nvidia hosts.
- sudo via a validated `/etc/sudoers.d/` drop-in, user creation with zsh,
  XDG user directories, pam_env XDG base dirs, KDE keyboard and locale
  defaults, root login over SSH disabled (password auth left on for initial
  setup, ready to switch to key-only).

## Usage

On the Arch live ISO (curl, tar and jq are already included, nothing to
install first):

```
curl -L https://github.com/mschabhuettl/arch-linux-install/archive/main.tar.gz | tar xz --strip-components=1 && ./common/00-pre-chroot.sh pc
```

Use `nb` instead of `pc` for the laptop. This runs whatever is currently on
main; put a tag or commit in the archive URL instead if you ever need a
fixed revision.

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
| `UCODE`         | `amd` or `intel` (microcode package + boot entries)  |
| `GPU`           | `nvidia`, `amdgpu` or `intel`                        |
| `TIMESYNC`      | `timesyncd` or `chrony`                              |
| `POWER`         | `ppd` (power-profiles-daemon) or `tlp`               |
| `MODULES_EXTRA` | Extra initramfs modules (e.g. NIC drivers)           |
| `EXTRA_PKGS`    | Host-only packages, same transaction as the rest     |
| `CMDLINE_EXTRA` | Appended to the kernel command line                  |

Shared constants (user name, VG name, timezone, cache server, package sets)
live in `common/defaults.env`. `USERNAME` and `USER_UID` can be overridden
per host, see `hosts/nb-nee.env`.

## Notes

- SSH root login is disabled (`PermitRootLogin no`). Password authentication
  is left enabled for initial file transfers; `PasswordAuthentication no` sits
  commented out in `/etc/ssh/sshd_config.d/10-hardening.conf`. After deploying
  your public key, uncomment it and restart sshd to go key-only.
- pacman runs interactively by design; answer its prompts.
- `01-post-chroot.sh` is not idempotent. If it fails mid-run, fix the issue
  and continue manually via `arch-chroot /mnt` (the staged files are kept at
  `/mnt/root/install` in that case).
- plymouth is installed but intentionally left unconfigured for now.
