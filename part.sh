#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
DISK="/dev/nvme0n1"
HOSTNAME="arch-hybrid"
USERNAME="user"      # Change this if you want a different username
REGION="Africa"
CITY="Cairo"
# ---------------------------------------------------------------------------

echo -e "\033[0;32m>>> STEP 1: PREPARING CACHYOS REPOS ON LIVE ISO <<<\033[0m"
# We need to add CachyOS repos to the LIVE environment so pacstrap can find the kernel
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
rm -f cachyos-repo.tar.xz
curl -O https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
pacman -Sy

echo -e "\033[0;32m>>> STEP 2: PARTITIONING & FORMATTING <<<\033[0m"
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
sgdisk -Z ${DISK}

# p1: EFI (1GB)
sgdisk -n 1::+1024M -t 1:ef00 -c 1:"EFI" ${DISK}
# p2: XBOOTLDR (1GB) - For Kernels
sgdisk -n 2::+1024M -t 2:ea00 -c 2:"XBOOTLDR" ${DISK}
# p3: Root (Rest)
sgdisk -n 3:::: -t 3:8300 -c 3:"ROOT" ${DISK}

partprobe ${DISK}
sleep 2

# Formatting
mkfs.fat -F32 -n "EFI" "${DISK}p1"
mkfs.ext4 -L "BOOT" "${DISK}p2"
mkfs.btrfs -L "ARCH_ROOT" -f "${DISK}p3"

echo -e "\033[0;32m>>> STEP 3: SUBVOLUMES & NoCoW SETUP <<<\033[0m"
mount -t btrfs "${DISK}p3" /mnt

# Create Subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@vm_images
btrfs subvolume create /mnt/@swap

# Disable CoW on specific subvolumes (Must be done while empty)
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

# Mount Boot Partitions
mount "${DISK}p1" /mnt/efi
mount "${DISK}p2" /mnt/boot

echo -e "\033[0;32m>>> STEP 5: INSTALLING SYSTEM (BASE + CACHYOS KERNEL) <<<\033[0m"
# Installing CachyOS Kernel + Nvidia + Microcode + Firmware
pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-nvidia linux-firmware sof-firmware amd-ucode networkmanager vim git sudo

echo -e "\033[0;32m>>> STEP 6: GENERATING FSTAB <<<\033[0m"
genfstab -U /mnt >> /mnt/etc/fstab

echo -e "\033[0;32m>>> STEP 7: CONFIGURING SYSTEM (CHROOT) <<<\033[0m"
cat <<EOF > /mnt/setup_inside.sh
#!/bin/bash

# Timezone & Locale
ln -sf /usr/share/zoneinfo/${REGION}/${CITY} /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname

# Network
systemctl enable NetworkManager

# Users
echo "root:root" | chpasswd
useradd -m -G wheel,storage,power,kvm,libvirt,video -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USERNAME}" | chpasswd
# Allow wheel group sudo access
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ---------------------------------------------------------------------------
# REPO SETUP INSIDE INSTALLATION
# ---------------------------------------------------------------------------
# We need to make sure the installed system also has the CachyOS repos
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
wget https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
rm -rf cachyos-repo*
pacman -Sy

# ---------------------------------------------------------------------------
# SWAP FILE (16GB)
# ---------------------------------------------------------------------------
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
btrfs property set /swap/swapfile compression none
dd if=/dev/zero of=/swap/swapfile bs=1G count=16 status=progress
chmod 600 /swap/swapfile
mkswap /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

# ---------------------------------------------------------------------------
# BOOTLOADER (Systemd-boot)
# ---------------------------------------------------------------------------
bootctl install

# 1. HYBRID/LINUX ENTRY
cat <<BOOTCONF > /boot/loader/entries/arch.conf
title   Arch CachyOS (Hybrid)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=PARTUUID=$(blkid -s PARTUUID -o value ${DISK}p3) rw rootflags=subvol=@ nvidia-drm.modeset=1 quiet
BOOTCONF

# 2. WINDOWS VM ISOLATION ENTRY
cat <<BOOTCONF > /boot/loader/entries/arch-vfio.conf
title   Arch CachyOS (VFIO/VM)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=PARTUUID=$(blkid -s PARTUUID -o value ${DISK}p3) rw rootflags=subvol=@ amd_iommu=on iommu=pt vfio-pci.ids=10de:25a0,10de:2291 quiet
BOOTCONF

# Set Default
echo "default arch.conf" > /boot/loader/loader.conf
echo "timeout 3" >> /boot/loader/loader.conf
echo "console-mode max" >> /boot/loader/loader.conf

EOF

# Make script executable and run it inside chroot
chmod +x /mnt/setup_inside.sh
arch-chroot /mnt /setup_inside.sh
rm /mnt/setup_inside.sh

echo -e "\033[0;32m>>> INSTALLATION COMPLETE <<<\033[0m"
echo "Root password is: root"
echo "User password is: ${USERNAME}"
echo "You can now reboot."
