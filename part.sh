#!/bin/bash
set -e

DISK="/dev/nvme0n1"
HOSTNAME="arch-hybrid"
USERNAME="user"
REGION="Africa"
CITY="Cairo"

echo -e "\033[0;32m>>> STEP 0: CLEANUP <<<\033[0m"
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
wipefs --all --force ${DISK} 2>/dev/null || true
sgdisk -Z ${DISK}

echo -e "\033[0;32m>>> STEP 1: PREPARING REPOS <<<\033[0m"
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
rm -f cachyos-repo.tar.xz
curl -O https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
pacman -Sy

echo -e "\033[0;32m>>> STEP 2: PARTITIONING <<<\033[0m"
# p1: EFI (1GB)
sgdisk -n 1::+1024M -t 1:ef00 -c 1:"EFI" ${DISK}
# p2: XBOOTLDR (1GB)
sgdisk -n 2::+1024M -t 2:ea00 -c 2:"XBOOTLDR" ${DISK}
# p3: Root (Rest)
sgdisk -n 3:::: -t 3:8300 -c 3:"ROOT" ${DISK}

echo "Waiting for partitions to appear..."
partprobe ${DISK}
sleep 5

# WAIT LOOP: Ensure p3 exists before formatting
while [ ! -e "${DISK}p3" ]; do
    echo "Waiting for ${DISK}p3..."
    sleep 1
done

echo -e "\033[0;32m>>> STEP 3: FORMATTING & SUBVOLUMES <<<\033[0m"
mkfs.fat -F32 -n "EFI" "${DISK}p1"
mkfs.ext4 -L "BOOT" "${DISK}p2"
mkfs.btrfs -L "ARCH_ROOT" -f "${DISK}p3"

mount -t btrfs "${DISK}p3" /mnt

# Subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@vm_images
btrfs subvolume create /mnt/@swap

# NoCoW
chattr +C /mnt/@vm_images
chattr +C /mnt/@swap

umount /mnt

echo -e "\033[0;32m>>> STEP 4: MOUNTING <<<\033[0m"
MOUNT_OPTS="defaults,noatime,compress=zstd,ssd"
mount -t btrfs -o ${MOUNT_OPTS},subvol=@ "${DISK}p3" /mnt

mkdir -p /mnt/{efi,boot,home,.snapshots,var/log,swap,var/lib/libvirt/images}

mount -t btrfs -o ${MOUNT_OPTS},subvol=@home "${DISK}p3" /mnt/home
mount -t btrfs -o ${MOUNT_OPTS},subvol=@snapshots "${DISK}p3" /mnt/.snapshots
mount -t btrfs -o ${MOUNT_OPTS},subvol=@var_log "${DISK}p3" /mnt/var/log
mount -t btrfs -o ${MOUNT_OPTS},subvol=@vm_images "${DISK}p3" /mnt/var/lib/libvirt/images
mount -t btrfs -o ${MOUNT_OPTS},subvol=@swap "${DISK}p3" /mnt/swap
mount "${DISK}p1" /mnt/efi
mount "${DISK}p2" /mnt/boot

# CHECK: If mount failed, this will stop the script
if ! mountpoint -q /mnt/boot; then
    echo "ERROR: Partitions not mounted correctly!"
    exit 1
fi

echo -e "\033[0;32m>>> STEP 5: INSTALLING PACKAGES <<<\033[0m"
pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-nvidia linux-firmware sof-firmware amd-ucode networkmanager vim git sudo

echo -e "\033[0;32m>>> STEP 6: CONFIGURING SYSTEM <<<\033[0m"
genfstab -U /mnt >> /mnt/etc/fstab

cat <<EOF > /mnt/setup_inside.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/${REGION}/${CITY} /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname

systemctl enable NetworkManager

echo "root:root" | chpasswd
useradd -m -G wheel,storage,power,kvm,libvirt,video -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USERNAME}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# REPO SETUP INSIDE
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
wget https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
rm -rf cachyos-repo*
pacman -Sy

# SWAP (16GB)
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
btrfs property set /swap/swapfile compression none
dd if=/dev/zero of=/swap/swapfile bs=1G count=16 status=progress
chmod 600 /swap/swapfile
mkswap /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

# BOOTLOADER
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

echo "DONE. Reboot now."
