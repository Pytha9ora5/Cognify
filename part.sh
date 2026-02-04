#!/bin/bash
# Arch Linux + Hyprland Installation Script for HP Pavilion ec2019ne

set -e

echo "=== Arch Linux Installation ==="

# Check UEFI
[ ! -d /sys/firmware/efi ] && echo "ERROR: Boot in UEFI mode" && exit 1

# Setup
loadkeys us
timedatectl set-ntp true

# Partition
echo "Partitioning /dev/nvme0n1..."
parted /dev/nvme0n1 --script mklabel gpt
parted /dev/nvme0n1 --script mkpart ESP fat32 1MiB 1025MiB
parted /dev/nvme0n1 --script set 1 esp on
parted /dev/nvme0n1 --script mkpart BOOT ext4 1025MiB 2049MiB
parted /dev/nvme0n1 --script mkpart ROOT btrfs 2049MiB 100%

# Format
echo "Formatting partitions..."
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.ext4 -F /dev/nvme0n1p2
mkfs.btrfs -f /dev/nvme0n1p3

# Create subvolumes
echo "Creating btrfs subvolumes..."
mount /dev/nvme0n1p3 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
umount /mnt

# Mount
echo "Mounting filesystems..."
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ /dev/nvme0n1p3 /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount /dev/nvme0n1p2 /mnt/boot
mkdir /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home /dev/nvme0n1p3 /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots /dev/nvme0n1p3 /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,subvol=@log /dev/nvme0n1p3 /mnt/var/log

# Install base
echo "Installing base system..."
pacstrap -K /mnt base linux-cachyos linux-cachyos-headers linux-firmware amd-ucode btrfs-progs

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configure system
echo "Configuring system..."
arch-chroot /mnt /bin/bash <<'CHROOT'
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch-hp" > /etc/hostname
pacman -S --noconfirm grub efibootmgr networkmanager
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager
echo "root:root" | chpasswd
dd if=/dev/zero of=/swapfile bs=1M count=16384 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab
CHROOT

echo "DONE! Reboot now: umount -R /mnt && reboot"
