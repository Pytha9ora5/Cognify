#!/bin/bash
set -euo pipefail

################################################################################
# ARCH LINUX "JUST WORKS" INSTALLER
# Target: HP Pavilion (R7 5800H / RTX 3050 Ti)
# Logic: Mimics 'archinstall' default layout (ESP mounted at /boot)
################################################################################

# --- CONFIGURATION (MODIFY THIS SECTION) ---
DISK="/dev/nvme0n1"
HOSTNAME="arch-hp"
USERNAME="admin"
PASSWORD="password"     # Change this!
ROOT_PASSWORD="password" # Change this!
TIMEZONE="Africa/Cairo"
LOCALE="en_US.UTF-8"
KEYMAP="us"
# Mirror Country
MIRROR_COUNTRY="Germany"

# --- HARDWARE SPECIFIC (VFIO / GPU) ---
# RTX 3050 Ti IDs: 10de:25a0,10de:2291
VFIO_IDS="10de:25a0,10de:2291"

################################################################################
# 1. CLEANUP & PREP
################################################################################
echo "==> Cleaning up previous attempts..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af ${DISK} >/dev/null
sgdisk --zap-all ${DISK} >/dev/null

################################################################################
# 2. PARTITIONING (The "Archinstall" Layout)
# Partition 1: 2GB FAT32 (EFI + Boot) -> Mounts to /boot
# Partition 2: Rest BTRFS (Root)      -> Mounts to /
################################################################################
echo "==> Partitioning (Simple Layout)..."
sgdisk -n 1:0:+2G -t 1:ef00 -c 1:"EFI_BOOT" ${DISK}
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT"     ${DISK}

partprobe ${DISK}
sleep 2

echo "==> Formatting..."
mkfs.fat -F32 -n BOOT ${DISK}p1
mkfs.btrfs -f -L ROOT ${DISK}p2

################################################################################
# 3. SUBVOLUMES & MOUNTING
################################################################################
echo "==> Creating Subvolumes..."
mount ${DISK}p2 /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_lib_docker
btrfs subvolume create /mnt/@qemu
btrfs subvolume create /mnt/@ai_workspace

umount /mnt

echo "==> Mounting..."
# Mount Root
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ ${DISK}p2 /mnt

# Create directories
mkdir -p /mnt/{boot,home,.snapshots,var/log,var/lib/docker,var/lib/libvirt/images}
mkdir -p /mnt/home/${USERNAME}/ai_workspace

# Mount BOOT (The fix for HP Laptops)
mount ${DISK}p1 /mnt/boot

# Mount Subvolumes
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home ${DISK}p2 /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots ${DISK}p2 /mnt/.snapshots
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@var_log ${DISK}p2 /mnt/var/log
mount -o noatime,compress=no,nodatacow,subvol=@var_lib_docker ${DISK}p2 /mnt/var/lib/docker
mount -o noatime,compress=no,nodatacow,subvol=@qemu ${DISK}p2 /mnt/var/lib/libvirt/images
# AI Workspace (NoCoW for speed)
mount -o noatime,compress=no,nodatacow,subvol=@ai_workspace ${DISK}p2 /mnt/home/${USERNAME}/ai_workspace

################################################################################
# 4. PACMAN CONFIG & CACHYOS REPOS
################################################################################
echo "==> Configuring Repositories..."

# 1. Enable Multilib (Critical for Steam/Wine/Nvidia 32bit)
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# 2. Add CachyOS Keys & Repos (Before Pacstrap)
pacman-key --init
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47

# Add CachyOS to top of pacman.conf
if ! grep -q "\[cachyos\]" /etc/pacman.conf; then
    sed -i '1i [cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
    # Create mirrorlist
    echo "Server = https://mirror.cachyos.org/repo/\$arch/\$repo" > /etc/pacman.d/cachyos-mirrorlist
    echo "Server = https://cdn.cachyos.org/repo/\$arch/\$repo" >> /etc/pacman.d/cachyos-mirrorlist
fi

# 3. Optimize Mirrors (Germany)
reflector --country ${MIRROR_COUNTRY} --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

pacman -Sy

################################################################################
# 5. INSTALLATION (PACSTRAP)
################################################################################
echo "==> Installing Packages..."

PACKAGES=(
    # Core
    base base-devel linux-cachyos linux-cachyos-headers linux-firmware amd-ucode
    btrfs-progs networkmanager openssh
    
    # Bootloader
    efibootmgr
    
    # GPU / Passthrough
    nvidia-dkms nvidia-utils lib32-nvidia-utils
    
    # Virtualization
    qemu-full libvirt virt-manager virt-viewer ovmf swtpm edk2-ovmf dnsmasq iptables-nft
    
    # Docker / AI
    docker docker-compose docker-buildx python python-pip python-virtualenv python-numpy ffmpeg
    
    # Desktop (Hyprland)
    hyprland xdg-desktop-portal-hyprland polkit-kde-agent qt5-wayland qt6-wayland sddm
    waybar rofi-wayland dunst swww grim slurp wl-clipboard cliphist kitty
    thunar thunar-volman gvfs
    
    # Audio / Bluetooth
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol
    bluez bluez-utils
    
    # Utils
    git neovim vim htop btop wget curl unzip zip zram-generator
    
    # Fonts
    ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji
)

pacstrap -K /mnt "${PACKAGES[@]}"

################################################################################
# 6. SYSTEM CONFIGURATION
################################################################################
echo "==> Generating Fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Configuring System..."

cat > /mnt/root/setup.sh <<EOF
#!/bin/bash

# Time & Locale
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

# Users
echo "root:${ROOT_PASSWORD}" | chpasswd
useradd -m -G wheel,libvirt,docker,video,audio,input -s /bin/bash ${USERNAME}
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Fix Permissions
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/ai_workspace

# Initramfs (Nvidia Modules)
sed -i 's/^MODULES=()/MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (Systemd-boot)
bootctl install

# HP BIOS FIX: Copy bootloader to fallback path
mkdir -p /boot/EFI/BOOT
cp /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI

# Loader Config
echo "timeout 5" > /boot/loader/loader.conf
echo "default arch-vfio.conf" >> /boot/loader/loader.conf

# 1. VFIO Entry (Windows VM Ready)
cat > /boot/loader/entries/arch-vfio.conf <<BOOT
title   Arch Linux (VFIO)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=$(blkid -s UUID -o value ${DISK}p2) rootflags=subvol=@ rw amd_iommu=on iommu=pt video=efifb:off vfio-pci.ids=${VFIO_IDS} kvm.ignore_msrs=1
BOOT

# 2. NVIDIA Entry (AI/Docker Ready)
cat > /boot/loader/entries/arch-nvidia.conf <<BOOT
title   Arch Linux (NVIDIA/AI)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=$(blkid -s UUID -o value ${DISK}p2) rootflags=subvol=@ rw amd_iommu=on iommu=pt
BOOT

# Enable Services
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable libvirtd
systemctl enable docker
systemctl enable bluetooth

# ZRAM (Swap)
echo "[zram0]" > /etc/systemd/zram-generator.conf
echo "zram-size = ram / 2" >> /etc/systemd/zram-generator.conf
echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf

# 16GB Swap File (BTRFS friendly)
truncate -s 0 /swapfile
chattr +C /swapfile
dd if=/dev/zero of=/swapfile bs=1M count=16384 status=none
chmod 600 /swapfile
mkswap /swapfile
echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab

EOF

chmod +x /mnt/root/setup.sh
arch-chroot /mnt /root/setup.sh
rm /mnt/root/setup.sh

################################################################################
# 7. FINISH
################################################################################
echo "==> Installation Complete!"
echo "    Rebooting in 5 seconds..."
sleep 5
umount -R /mnt
reboot