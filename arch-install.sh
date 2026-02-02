#!/bin/bash
set -e

##############################################################################
# Arch Linux Installation Script for HP Pavilion Gaming (Single-GPU Passthrough)
# User: muhammad | Hostname: arch | Timezone: Africa/Cairo
##############################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
USERNAME="muhammad"
HOSTNAME="arch"
TIMEZONE="Africa/Cairo"
LOCALE="en_US.UTF-8"
DISK="/dev/nvme0n1"
EFI_SIZE="1G"
BOOT_SIZE="1G"

# Function to print colored messages
print_msg() {
    echo -e "${GREEN}[*]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

##############################################################################
# Phase 1: Disk Partitioning
##############################################################################
print_msg "Phase 1: Partitioning disk ${DISK}"

# Wipe disk
print_warning "This will DESTROY all data on ${DISK}. Press ENTER to continue or CTRL+C to abort."
read

sgdisk --zap-all ${DISK}

# Create partitions
sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" ${DISK}
sgdisk -n 2:0:+${BOOT_SIZE} -t 2:8300 -c 2:"BOOT" ${DISK}
sgdisk -n 3:0:0 -t 3:8300 -c 3:"CRYPTROOT" ${DISK}

# Inform kernel of partition changes
partprobe ${DISK}
sleep 2

print_msg "Partitions created:"
lsblk ${DISK}

##############################################################################
# Phase 2: LUKS2 Encryption
##############################################################################
print_msg "Phase 2: Setting up LUKS2 encryption on ${DISK}p3"

print_warning "Enter encryption passphrase (you'll need this at every boot):"
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha256 \
    --pbkdf argon2id \
    ${DISK}p3

print_msg "Opening encrypted container..."
cryptsetup open ${DISK}p3 cryptroot

##############################################################################
# Phase 3: Filesystem Formatting
##############################################################################
print_msg "Phase 3: Formatting filesystems"

mkfs.fat -F32 ${DISK}p1
mkfs.ext4 ${DISK}p2
mkfs.btrfs -f -L arch /dev/mapper/cryptroot

##############################################################################
# Phase 4: BTRFS Subvolumes
##############################################################################
print_msg "Phase 4: Creating BTRFS subvolumes"

mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_lib_docker
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@qemu
btrfs subvolume create /mnt/@shared
btrfs subvolume create /mnt/@ai_workspace

umount /mnt

##############################################################################
# Phase 5: Mounting with Proper Options
##############################################################################
print_msg "Phase 5: Mounting subvolumes with optimized options"

# Mount root
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@ /dev/mapper/cryptroot /mnt

# Create mount points
mkdir -p /mnt/{home,var/log,var/lib/docker,.snapshots,var/lib/libvirt/images,mnt/shared,boot,boot/efi}
mkdir -p /mnt/home/${USERNAME}/ai_workspace

# Mount subvolumes
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd:2,space_cache=v2,ssd,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@var_lib_docker /dev/mapper/cryptroot /mnt/var/lib/docker
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@qemu /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
mount -o noatime,compress=zstd:3,space_cache=v2,ssd,subvol=@shared /dev/mapper/cryptroot /mnt/mnt/shared
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@ai_workspace /dev/mapper/cryptroot /mnt/home/${USERNAME}/ai_workspace

# Mount boot partitions
mount ${DISK}p2 /mnt/boot
mount ${DISK}p1 /mnt/boot/efi

print_msg "Mount structure:"
lsblk -f

##############################################################################
# Phase 6: Install Base System
##############################################################################
print_msg "Phase 6: Installing base system (this will take a while...)"

# Add CachyOS repository
cat >> /etc/pacman.conf << 'EOF'

[cachyos]
Server = https://mirror.cachyos.org/repo/$arch/$repo
EOF

# Import CachyOS keys
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47

# Update package databases
pacman -Sy

# Install base system
pacstrap /mnt \
    base linux-cachyos linux-cachyos-headers linux-cachyos-lts linux-cachyos-lts-headers \
    linux-firmware amd-ucode base-devel git neovim \
    btrfs-progs cryptsetup \
    networkmanager openssh \
    nvidia-dkms nvidia-utils lib32-nvidia-utils \
    qemu-full libvirt virt-manager virt-viewer ovmf swtpm edk2-ovmf dnsmasq iptables-nft bridge-utils \
    usbutils libusb \
    docker docker-compose docker-buildx \
    python python-pip python-virtualenv python-numpy \
    ffmpeg \
    hyprland xdg-desktop-portal-hyprland polkit-kde-agent qt5-wayland qt6-wayland \
    sddm \
    waybar rofi-wayland dunst swww grim slurp wl-clipboard cliphist \
    kitty \
    thunar thunar-volman gvfs \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol \
    ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji \
    brightnessctl playerctl bluez bluez-utils \
    nm-connection-editor \
    zram-generator

##############################################################################
# Phase 7: Generate fstab
##############################################################################
print_msg "Phase 7: Generating fstab"

genfstab -U /mnt >> /mnt/etc/fstab

# Verify fstab
print_msg "Verifying fstab:"
cat /mnt/etc/fstab

##############################################################################
# Phase 8: Chroot Configuration
##############################################################################
print_msg "Phase 8: Configuring system (chroot)"

# Create chroot configuration script
cat > /mnt/chroot-config.sh << 'CHROOTEOF'
#!/bin/bash
set -e

USERNAME="muhammad"
HOSTNAME="arch"
TIMEZONE="Africa/Cairo"
LOCALE="en_US.UTF-8"
DISK="/dev/nvme0n1"

# Set timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# Hosts file
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# mkinitcpio configuration
cat > /etc/mkinitcpio.conf << 'EOF'
MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
EOF

# Regenerate initramfs
mkinitcpio -P

# Nvidia configuration
cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia_drm modeset=1
EOF

# VFIO configuration
cat > /etc/modprobe.d/vfio.conf << 'EOF'
options vfio-pci ids=10de:25a0,10de:2291
softdep nvidia pre: vfio-pci
EOF

# KVM configuration
cat > /etc/modprobe.d/kvm.conf << 'EOF'
options kvm_amd nested=1
options kvm_amd npt=1
options kvm_amd avic=1
EOF

# Bootloader installation
bootctl install

# Get LUKS UUID
LUKS_UUID=$(blkid -s UUID -o value ${DISK}p3)

# Bootloader configuration
cat > /boot/loader/loader.conf << 'EOF'
default arch-cachyos.conf
timeout 5
console-mode max
editor no
EOF

# Main boot entry
cat > /boot/loader/entries/arch-cachyos.conf << EOF
title   Arch Linux (CachyOS Kernel)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw amd_iommu=on iommu=pt video=efifb:off kvm.ignore_msrs=1 kvm_amd.npt=1 kvm_amd.avic=1
EOF

# Fallback boot entry
cat > /boot/loader/entries/arch-cachyos-lts.conf << EOF
title   Arch Linux (CachyOS LTS Kernel)
linux   /vmlinuz-linux-cachyos-lts
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos-lts.img
options rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw amd_iommu=on iommu=pt video=efifb:off kvm.ignore_msrs=1 kvm_amd.npt=1 kvm_amd.avic=1
EOF

# Fallback initramfs entry
cat > /boot/loader/entries/arch-cachyos-fallback.conf << EOF
title   Arch Linux (CachyOS Kernel - Fallback)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos-fallback.img
options rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw amd_iommu=on iommu=pt video=efifb:off
EOF

# Root password
echo "Set root password:"
passwd

# Create user
useradd -m -G wheel,libvirt,docker,video,audio,input -s /bin/bash ${USERNAME}
echo "Set password for ${USERNAME}:"
passwd ${USERNAME}

# Sudoers
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel

# Enable services
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable libvirtd
systemctl enable docker
systemctl enable bluetooth

# Libvirt configuration
cat >> /etc/libvirt/libvirtd.conf << 'EOF'
unix_sock_group = "libvirt"
unix_sock_rw_perms = "0770"
EOF

cat >> /etc/libvirt/qemu.conf << EOF
user = "${USERNAME}"
group = "libvirt"
EOF

# Docker configuration
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
    "data-root": "/var/lib/docker",
    "storage-driver": "overlay2",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

# zram configuration
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 4
compression-algorithm = zstd
swap-priority = 100
EOF

# Create swap file
mkdir -p /swap
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
btrfs property set /swap/swapfile compression none
dd if=/dev/zero of=/swap/swapfile bs=1M count=16384 status=progress
chmod 600 /swap/swapfile
mkswap /swap/swapfile

# Add swap to fstab
echo "/swap/swapfile none swap sw,pri=10 0 0" >> /etc/fstab

# Disable CoW on specific subvolumes
chattr +C /var/lib/docker
chattr +C /var/lib/libvirt/images
chattr +C /home/${USERNAME}/ai_workspace

# Create AI workspace structure
mkdir -p /home/${USERNAME}/ai_workspace/{videos_input,videos_processing,models/{whisper,deepface,ocr},output/{transcripts,facial_analysis,ocr_results},cache}
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/ai_workspace
chmod -R 755 /home/${USERNAME}/ai_workspace

# Create Hyprland config directory
mkdir -p /home/${USERNAME}/.config/hypr
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config

# Create installation complete marker
touch /home/${USERNAME}/INSTALLATION_COMPLETE.txt
cat > /home/${USERNAME}/INSTALLATION_COMPLETE.txt << 'EOF'
Arch Linux Installation Complete!

Next steps:
1. Reboot: exit chroot, umount -R /mnt, reboot
2. Login as muhammad
3. Install AUR helper: 
   cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si
4. Install AUR packages:
   paru -S nvidia-container-toolkit ttf-jetbrains-mono-nerd
5. Configure Hyprland
6. Set up GPU dynamic switching scripts
7. Create Windows VM with virt-manager

Documentation saved in ~/arch-install-configs/
EOF

chown ${USERNAME}:${USERNAME} /home/${USERNAME}/INSTALLATION_COMPLETE.txt

echo "Chroot configuration complete!"

CHROOTEOF

chmod +x /mnt/chroot-config.sh
arch-chroot /mnt /chroot-config.sh

##############################################################################
# Phase 9: Cleanup and Finish
##############################################################################
print_msg "Phase 9: Installation complete!"

rm /mnt/chroot-config.sh

print_msg "======================================================================"
print_msg "Installation finished successfully!"
print_msg "======================================================================"
print_msg ""
print_msg "Next steps:"
print_msg "1. exit (if you ran this as root in chroot)"
print_msg "2. umount -R /mnt"
print_msg "3. cryptsetup close cryptroot"
print_msg "4. reboot"
print_msg ""
print_msg "After reboot:"
print_msg "- Login as: ${USERNAME}"
print_msg "- Check ~/INSTALLATION_COMPLETE.txt for post-install steps"
print_msg ""
print_warning "Don't forget your LUKS passphrase!"
print_msg "======================================================================"