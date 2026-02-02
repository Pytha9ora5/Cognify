#!/bin/bash
# Arch Linux Installer for HP Pavilion Gaming (R7 5800H + RTX 3050 Ti)
# Setup: BTRFS, CachyOS Kernel, Hyprland, VFIO/QEMU, Docker AI Workspace

set -e

# --- Configuration Variables ---
HOSTNAME="arch"
USERNAME="muhammad"
TIMEZONE="Africa/Cairo"
VFIO_IDS="10de:25a0,10de:2291" # RTX 3050 Ti and Audio
SWAP_SIZE="16G"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Starting Arch Linux Installation for AI & VFIO...${NC}"

# --- Step 1: Disk Selection ---
lsblk
echo -e "${GREEN}Enter the drive to install to (e.g., /dev/nvme0n1):${NC}"
read DISK

if [ -z "$DISK" ]; then
    echo -e "${RED}No disk selected. Exiting.${NC}"
    exit 1
fi

echo -e "${RED}WARNING: ALL DATA ON $DISK WILL BE ERASED! TYPE 'YES' TO CONTINUE.${NC}"
read CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    exit 1
fi

# --- Step 2: Partitioning & Formatting ---
echo -e "${GREEN}Partitioning $DISK...${NC}"
sgdisk -Z $DISK
sgdisk -n 1:0:+1G -t 1:ef00 $DISK  # EFI
sgdisk -n 2:0:0 -t 2:8300 $DISK    # Root

# Format EFI
mkfs.vfat -F32 "${DISK}p1"

# Format Root (BTRFS)
mkfs.btrfs -f -L ARCH "${DISK}p2"

# --- Step 3: BTRFS Subvolumes ---
echo -e "${GREEN}Creating BTRFS Subvolumes...${NC}"
mount "${DISK}p2" /mnt

# Create subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_lib_docker
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@qemu
btrfs subvolume create /mnt/@shared
btrfs subvolume create /mnt/@ai_workspace

# Setup NoCoW (No Copy-on-Write) for specific subvolumes
# We must unmount, mount normally, chattr +C, then organize
umount /mnt
mount "${DISK}p2" /mnt

# Disable CoW on these directories before writing data
chattr +C /mnt/@var_lib_docker
chattr +C /mnt/@qemu
chattr +C /mnt/@ai_workspace
chattr +C /mnt/@shared

umount /mnt

# --- Step 4: Mounting Subvolumes ---
echo -e "${GREEN}Mounting Subvolumes...${NC}"
MOUNT_OPT="noatime,compress=zstd:3,space_cache=v2"
MOUNT_NOCOW="noatime,nodatacow,space_cache=v2" # Compression usually disabled by nodatacow implied by chattr +C but safe to list

mount -o $MOUNT_OPT,subvol=@ "${DISK}p2" /mnt
mkdir -p /mnt/{home,var/log,var/lib/docker,.snapshots,var/lib/libvirt/images,shared_vm}

mount -o $MOUNT_OPT,subvol=@home "${DISK}p2" /mnt/home
mount -o $MOUNT_OPT,subvol=@var_log "${DISK}p2" /mnt/var/log
mount -o $MOUNT_OPT,subvol=@snapshots "${DISK}p2" /mnt/.snapshots
# NoCoW Mounts (redundant options but clear intent)
mount -o $MOUNT_NOCOW,subvol=@var_lib_docker "${DISK}p2" /mnt/var/lib/docker
mount -o $MOUNT_NOCOW,subvol=@qemu "${DISK}p2" /mnt/var/lib/libvirt/images
mount -o $MOUNT_NOCOW,subvol=@shared "${DISK}p2" /mnt/shared_vm

# AI Workspace Mount (We will create user directory later, temporarily mount to mnt root to Create)
mkdir -p /mnt/home/$USERNAME/ai_workspace
mount -o $MOUNT_NOCOW,subvol=@ai_workspace "${DISK}p2" /mnt/home/$USERNAME/ai_workspace

# EFI
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot

# --- Step 5: Base Install & CachyOS Prep ---
echo -e "${GREEN}Installing Base System...${NC}"
# Standard Arch Base first
pacstrap /mnt base base-devel linux-firmware git neovim btrfs-progs networkmanager amd-ucode

# Generate Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# --- Step 6: Chroot Configuration Script ---
cat <<EOF > /mnt/setup_system.sh
#!/bin/bash
set -e

# 1. Time & Locales
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# 2. User Setup
useradd -m -G wheel,storage,power,video,input,libvirt,docker -s /bin/bash $USERNAME
echo "$USERNAME:password" | chpasswd
echo "root:password" | chpasswd
echo "Please change passwords after first login!"
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# 3. CachyOS Repos & Kernel
echo "Adding CachyOS Repos..."
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
rm -U /var/lib/pacman/sync/cachyos* 2>/dev/null || true
pacman -U 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst' 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v3-mirrorlist-18-1-any.pkg.tar.zst' --noconfirm

cat <<REPO >> /etc/pacman.conf
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
REPO

pacman -Sy

# Install CachyOS Kernel & Nvidia
# Note: For Laptop VFIO, we want the host to use the dGPU sometimes, or bind it. 
# We install standard nvidia drivers. VFIO isolation will happen via Hooks/Kernel cmdline.
pacman -S --noconfirm linux-cachyos linux-cachyos-headers nvidia-dkms-cachyos nvidia-utils nvidia-settings \
    libva-nvidia-driver mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon

# 4. Hyprland & SDDM
pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland kitty waybar rofi-wayland \
    sddm qt5-graphicaleffects qt5-quickcontrols2 qt5-svg polkit-kde-agent \
    dunst thunar brightnessctl network-manager-applet bluez bluez-utils

systemctl enable sddm
systemctl enable NetworkManager
systemctl enable bluetooth

# 5. Virtualization (QEMU/KVM/Libvirt)
pacman -S --noconfirm qemu-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat \
    libguestfs swtpm look-glass-module-dkms qemu-audio-jack

sed -i 's/#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' /etc/libvirt/libvirtd.conf
sed -i 's/#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' /etc/libvirt/libvirtd.conf
sed -i 's/#user = "root"/user = "$USERNAME"/' /etc/libvirt/qemu.conf
sed -i 's/#group = "root"/group = "$USERNAME"/' /etc/libvirt/qemu.conf

systemctl enable libvirtd

# 6. Docker & AI Workspace Setup
pacman -S --noconfirm docker docker-compose nvidia-container-toolkit python-pip zram-generator

systemctl enable docker

# Configure NVIDIA Container Toolkit
nvidia-ctk runtime configure --runtime=docker
# Set up n8n via docker-compose later, just ensure structure exists
mkdir -p /home/$USERNAME/ai_workspace/{videos_input,models,output,n8n_data}
chown -R $USERNAME:$USERNAME /home/$USERNAME/ai_workspace

# 7. Storage: Swap & ZRAM
# ZRAM Config
echo "[zram0]" > /etc/systemd/zram-generator.conf
echo "zram-size = 4096" >> /etc/systemd/zram-generator.conf
echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf
echo "swap-priority = 100" >> /etc/systemd/zram-generator.conf

# Swapfile (16GB) on BTRFS
# Note: We must create a zero length file, set chattr +C, then allocate
truncate -s 0 /swapfile
chattr +C /swapfile
btrfs property set /swapfile compression none
fallocate -l $SWAP_SIZE /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo "/swapfile none swap defaults,priority=10 0 0" >> /etc/fstab

# 8. Bootloader (GRUB) & VFIO Config
pacman -S --noconfirm grub efibootmgr

# Enable IOMMU and set VFIO
# On laptops with 5800H + RTX, we usually don't blacklist nvidia globally if we want dynamic switching.
# We will use kernel parameters to prepare IOMMU.
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet amd_iommu=on iommu=pt kvm.ignore_msrs=1 video=efifb:off"/' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 9. VFIO Hooks Setup (Skeleton)
mkdir -p /etc/libvirt/hooks
wget -O /etc/libvirt/hooks/qemu https://raw.githubusercontent.com/PassthroughPOST/VFIO-Tools/master/libvirt_hooks/qemu
chmod +x /etc/libvirt/hooks/qemu
mkdir -p /etc/libvirt/hooks/qemu.d/win11/prepare/begin
mkdir -p /etc/libvirt/hooks/qemu.d/win11/release/end

# Create the Start Hook (Dynamic Unbind)
cat <<HOOK_START > /etc/libvirt/hooks/qemu.d/win11/prepare/begin/start.sh
#!/bin/bash
set -x

# Stop Display Manager
systemctl stop sddm

# Unbind VTconsoles
echo 0 > /sys/class/vtconsole/vtcon0/bind
echo 0 > /sys/class/vtconsole/vtcon1/bind

# Unbind EFI Framebuffer
echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind

# Detach Nvidia
virsh nodedev-detach pci_0000_01_00_0
virsh nodedev-detach pci_0000_01_00_1

# Load VFIO
modprobe vfio-pci
HOOK_START

# Create the Revert Hook
cat <<HOOK_END > /etc/libvirt/hooks/qemu.d/win11/release/end/revert.sh
#!/bin/bash
set -x

# Unload VFIO
modprobe -r vfio-pci

# Re-attach Nvidia
virsh nodedev-reattach pci_0000_01_00_0
virsh nodedev-reattach pci_0000_01_00_1

# Rebind Framebuffer
echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/bind

# Rebind VTconsoles
echo 1 > /sys/class/vtconsole/vtcon0/bind
echo 1 > /sys/class/vtconsole/vtcon1/bind

# Restart Display Manager
systemctl start sddm
HOOK_END

chmod +x /etc/libvirt/hooks/qemu.d/win11/prepare/begin/start.sh
chmod +x /etc/libvirt/hooks/qemu.d/win11/release/end/revert.sh

# 10. Looking Glass Shared Memory Config
echo "f /dev/shm/looking-glass 0660 $USERNAME kvm -" > /etc/tmpfiles.d/looking-glass.conf

EOF

# --- Execute Chroot Script ---
chmod +x /mnt/setup_system.sh
arch-chroot /mnt /setup_system.sh

# --- Cleanup ---
rm /mnt/setup_system.sh
umount -R /mnt
echo -e "${GREEN}Installation Complete! Rebooting in 5 seconds...${NC}"
sleep 5
reboot