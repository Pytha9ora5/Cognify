#!/bin/bash

# Partition the disk
cfdisk /dev/nvme0n1
# Create:
# nvme0n1p1 - 512M  - EFI System
# nvme0n1p2 - rest  - Linux filesystem

# Format partitions
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.btrfs -f /dev/nvme0n1p2

# Mount and create subvolumes
mount /dev/nvme0n1p2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@libvirt
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@swap
umount /mnt

# Mount subvolumes
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ /dev/nvme0n1p2 /mnt

mkdir -p /mnt/{home,boot/efi,.snapshots,var/cache,var/log,tmp,var/lib/libvirt,var/lib/docker,swap}

mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home /dev/nvme0n1p2 /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots /dev/nvme0n1p2 /mnt/.snapshots
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@cache /dev/nvme0n1p2 /mnt/var/cache
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@log /dev/nvme0n1p2 /mnt/var/log
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@tmp /dev/nvme0n1p2 /mnt/tmp
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@libvirt /dev/nvme0n1p2 /mnt/var/lib/libvirt
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@docker /dev/nvme0n1p2 /mnt/var/lib/docker
mount -o noatime,nodatacow,subvol=@swap /dev/nvme0n1p2 /mnt/swap

mount /dev/nvme0n1p1 /mnt/boot/efi

# Now run archinstall