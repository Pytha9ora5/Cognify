#!/bin/bash
set -e

DISK="/dev/nvme0n1"
HOSTNAME="arch"
USERNAME="muhammad"
REGION="Africa"
CITY="Cairo"

echo -e "\033[0;31m>>> STEP 1: NUCLEAR CLEANUP (Ensuring disk is empty) <<<\033[0m"
# Unmount everything forcibly
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
# Remove any device mapper nodes (like old encryption/LVM)
dmsetup remove_all 2>/dev/null || true
# Wipe filesystem signatures
wipefs --all --force ${DISK}
# Zap the partition table
sgdisk -Z ${DISK}
# Force kernel to reload partition table
partprobe ${DISK}
udevadm settle # CRITICAL: Waits for /dev nodes to process

echo -e "\033[0;32m>>> STEP 2: PARTITIONING <<<\033[0m"
# p1: EFI (1GB)
sgdisk -n 1::+1024M -t 1:ef00 -c 1:"EFI" ${DISK}
# p2: XBOOTLDR (1GB)
sgdisk -n 2::+1024M -t 2:ea00 -c 2:"XBOOTLDR" ${DISK}
# p3: Root (Rest)
sgdisk -n 3:::: -t 3:8300 -c 3:"ROOT" ${DISK}

echo "Waiting for partition nodes..."
udevadm settle
sleep 2

# Verify p3 exists
if [ ! -b "${DISK}p3" ]; then
    echo "ERROR: Partition ${DISK}p3 was not created. Setup failed."
    exit 1
fi

echo -e "\033[0;32m>>> STEP 3: FORMATTING <<<\033[0m"
mkfs.fat -F32 -n "EFI" "${DISK}p1"
mkfs.ext4 -L "BOOT" "${DISK}p2"
mkfs.btrfs -L "ARCH_ROOT" -f "${DISK}p3"

echo -e "\033[0;32m>>> STEP 4: SUBVOLUMES <<<\033[0m"
# Mount root temporarily to create structure
mount -t btrfs "${DISK}p3" /mnt

# CHECK: Did mount succeed?
if ! mountpoint -q /mnt; then
    echo "CRITICAL ERROR: Failed to mount disk. Script stopped to prevent RAM overflow."
    exit 1
fi

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@vm_images
btrfs subvolume create /mnt/@swap

# NoCoW Attributes
chattr +C /mnt/@vm_images
chattr +C /mnt/@swap

umount /mnt

echo -e "\033[0;32m>>> STEP 5: FINAL MOUNT <<<\033[0m"
MOUNT_OPTS="defaults,noatime,compress=zstd,ssd"

mount -t btrfs -o ${MOUNT_OPTS},subvol=@ "${DISK}p3" /mnt
# Verify Root Mount AGAIN
if ! mountpoint -q /mnt; then
    echo "CRITICAL ERROR: Root fs failed to mount."
    exit 1
fi

mkdir -p /mnt/{efi,boot,home,.snapshots,var/log,swap,var/lib/libvirt/images}

mount -t btrfs -o ${MOUNT_OPTS},subvol=@home "${DISK}p3" /mnt/home
mount -t btrfs -o ${MOUNT_OPTS},subvol=@snapshots "${DISK}p3" /mnt/.snapshots
mount -t btrfs -o ${MOUNT_OPTS},subvol=@var_log "${DISK}p3" /mnt/var/log
mount -t btrfs -o ${MOUNT_OPTS},subvol=@vm_images "${DISK}p3" /mnt/var/lib/libvirt/images
mount -t btrfs -o ${MOUNT_OPTS},subvol=@swap "${DISK}p3" /mnt/swap
mount "${DISK}p1" /mnt/efi
mount "${DISK}p2" /mnt/boot

echo -e "\033[0;32m>>> STEP 6: PREPARING REPOS <<<\033[0m"
# Repo setup happens here to ensure network is up before pacstrap
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
rm -f cachyos-repo.tar.xz
curl -O https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
pacman -Sy

echo -e "\033[0;32m>>> STEP 7: INSTALLING (PACSTRAP) <<<\033[0m"
# Only runs if mount confirmed
pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-nvidia linux-firmware sof-firmware amd-ucode networkmanager vim git sudo

echo -e "\033[0;32m>>> STEP 8: CONFIGURING <<<\033[0m"
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot Script
cat <<EOF > /mnt/setup_inside.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/Africa/Cairo /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch-hybrid" > /etc/hostname

systemctl enable NetworkManager

echo "root:root" | chpasswd
useradd -m -G wheel,storage,power,kvm,libvirt,video -s /bin/bash user
echo "user:user" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Repo inside
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
wget https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
rm -rf cachyos-repo*
pacman -Sy

# Swap
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
btrfs property set /swap/swapfile compression none
dd if=/dev/zero of=/swap/swapfile bs=1G count=16 status=progress
chmod 600 /swap/swapfile
mkswap /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

# Bootloader
bootctl install

cat <<BOOTCONF > /boot/loader/entries/arch.conf
title   Arch CachyOS (Hybrid)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=PARTUUID=\$(blkid -s PARTUUID -o value ${DISK}p3) rw rootflags=subvol=@ nvidia-drm.modeset=1 quiet
BOOTCONF

cat <<BOOTCONF > /boot/loader/entries/arch-vfio.conf
title   Arch CachyOS (VFIO/VM)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=PARTUUID=\$(blkid -s PARTUUID -o value ${DISK}p3) rw rootflags=subvol=@ amd_iommu=on iommu=pt vfio-pci.ids=10de:25a0,10de:2291 quiet
BOOTCONF

echo "default arch.conf" > /boot/loader/loader.conf
echo "timeout 3" >> /boot/loader/loader.conf
EOF

chmod +x /mnt/setup_inside.sh
arch-chroot /mnt /setup_inside.sh
rm /mnt/setup_inside.sh

echo "SUCCESS! Reboot now."
