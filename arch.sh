#!/bin/bash
set -euo pipefail

##############################################################################
# Arch Linux Automated Installation Script
# HP Pavilion Gaming - R7 5800H - RTX 3050 Ti - 500GB NVMe
# FIXED: Multilib support, Mount Order, Deprecated Packages
##############################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

##############################################################################
# CONFIGURATION - MODIFY THESE IF NEEDED
##############################################################################

USERNAME=""
HOSTNAME=""
TIMEZONE="Africa/Cairo"
LOCALE="en_US.UTF-8"
DISK="/dev/nvme0n1"

##############################################################################
# Helper Functions
##############################################################################

print_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

print_msg() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

confirm() {
    echo -e "${YELLOW}$1${NC}"
    read -p "Press ENTER to continue or CTRL+C to abort: "
}

##############################################################################
# Pre-flight Checks
##############################################################################

print_header "PRE-FLIGHT CHECKS"

if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root. Use: sudo ./install.sh"
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    print_error "Not booted in UEFI mode. Reboot in UEFI mode and try again."
fi

print_step "Checking internet connectivity..."
if ! ping -c 1 archlinux.org &>/dev/null; then
    print_error "No internet connection detected."
fi
print_msg "Internet connection OK"

if [[ ! -b ${DISK} ]]; then
    print_error "Disk ${DISK} not found."
fi

print_step "System Information:"
echo "  CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Target Disk: ${DISK}"
echo ""

##############################################################################
# Get User Configuration
##############################################################################

print_header "CONFIGURATION"

while [[ -z "${USERNAME}" ]]; do
    read -p "Enter username for new user: " USERNAME
    if [[ ! "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "Invalid username. Use lowercase letters."
        USERNAME=""
    fi
done

while [[ -z "${HOSTNAME}" ]]; do
    read -p "Enter hostname: " HOSTNAME
    if [[ ! "${HOSTNAME}" =~ ^[a-z0-9-]+$ ]]; then
        print_error "Invalid hostname."
        HOSTNAME=""
    fi
done

echo ""
confirm "WARNING: This will DESTROY ALL DATA on ${DISK}!"

##############################################################################
# Cleanup
##############################################################################

print_header "CLEANUP"
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
sleep 2
print_msg "Cleanup complete"

##############################################################################
# PHASE 1: Disk Partitioning
##############################################################################

print_header "PHASE 1: DISK PARTITIONING"

print_step "Wiping disk..."
wipefs -af ${DISK} >/dev/null 2>&1
sgdisk --zap-all ${DISK} >/dev/null 2>&1

print_step "Creating partitions..."
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" ${DISK} >/dev/null
sgdisk -n 2:0:+1G -t 2:8300 -c 2:"BOOT" ${DISK} >/dev/null
sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" ${DISK} >/dev/null

partprobe ${DISK}
sleep 3
print_msg "Partitions created"

##############################################################################
# PHASE 2: Format Filesystems
##############################################################################

print_header "PHASE 2: FORMATTING"

print_step "Formatting EFI (FAT32)..."
mkfs.fat -F32 ${DISK}p1 >/dev/null 2>&1

print_step "Formatting BOOT (ext4)..."
mkfs.ext4 -F ${DISK}p2 >/dev/null 2>&1

print_step "Formatting ROOT (BTRFS)..."
mkfs.btrfs -f -L archlinux ${DISK}p3 >/dev/null 2>&1

print_msg "Formatting complete"

##############################################################################
# PHASE 3: Create BTRFS Subvolumes
##############################################################################

print_header "PHASE 3: BTRFS SUBVOLUMES"

mount ${DISK}p3 /mnt
btrfs subvolume create /mnt/@ >/dev/null
btrfs subvolume create /mnt/@home >/dev/null
btrfs subvolume create /mnt/@var_log >/dev/null
btrfs subvolume create /mnt/@var_lib_docker >/dev/null
btrfs subvolume create /mnt/@snapshots >/dev/null
btrfs subvolume create /mnt/@qemu >/dev/null
btrfs subvolume create /mnt/@shared >/dev/null
btrfs subvolume create /mnt/@ai_workspace >/dev/null
umount /mnt

print_msg "Subvolumes created"

##############################################################################
# PHASE 4: Mounting (FIXED ORDER)
##############################################################################

print_header "PHASE 4: MOUNTING FILESYSTEMS"

# 1. Mount ROOT first
print_step "Mounting root subvolume..."
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@ ${DISK}p3 /mnt

# 2. Create Level-1 Mount Points
print_step "Creating base directories..."
mkdir -p /mnt/{home,boot,var/log,var/lib/docker,.snapshots,var/lib/libvirt/images,mnt/shared}

# 3. Mount Level-1 Subvolumes/Partitions
print_step "Mounting home, var, and boot..."
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@home ${DISK}p3 /mnt/home
mount -o noatime,compress=zstd:2,space_cache=v2,ssd,subvol=@var_log ${DISK}p3 /mnt/var/log
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@var_lib_docker ${DISK}p3 /mnt/var/lib/docker
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@snapshots ${DISK}p3 /mnt/.snapshots
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@qemu ${DISK}p3 /mnt/var/lib/libvirt/images
mount -o noatime,compress=zstd:3,space_cache=v2,ssd,subvol=@shared ${DISK}p3 /mnt/mnt/shared

# Mount Boot Partition (p2)
mount ${DISK}p2 /mnt/boot

# 4. Create Level-2 Mount Points (Nested)
print_step "Creating nested directories..."
mkdir -p /mnt/boot/efi
mkdir -p /mnt/home/${USERNAME}/ai_workspace

# 5. Mount Level-2 Subvolumes/Partitions
print_step "Mounting EFI and Workspace..."
mount ${DISK}p1 /mnt/boot/efi
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@ai_workspace ${DISK}p3 /mnt/home/${USERNAME}/ai_workspace

print_msg "Mounts complete"

##############################################################################
# PHASE 5: Configure Package Manager (FIXED MULTILIB)
##############################################################################

print_header "PHASE 5: CONFIGURING PACMAN"

print_step "Enabling parallel downloads..."
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

print_step "Enabling multilib repository (Required for lib32)..."
# This uncommenting command fixes the 'lib32-nvidia-utils' error
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

print_step "Adding CachyOS repository..."
if ! grep -q "\[cachyos\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf << 'EOF'

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

    cat > /etc/pacman.d/cachyos-mirrorlist << 'EOF'
Server = https://mirror.cachyos.org/repo/$arch/$repo
Server = https://cdn.cachyos.org/repo/$arch/$repo
EOF
fi

print_step "Importing keys..."
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com 2>/dev/null || true
pacman-key --lsign-key F3B607488DB35A47 2>/dev/null || true

print_step "Syncing databases..."
pacman -Sy --noconfirm >/dev/null

##############################################################################
# PHASE 6: Install Base System (FIXED PACKAGES)
##############################################################################

print_header "PHASE 6: INSTALLING PACKAGES"
print_warning "Downloading packages..."

# Removed: bridge-utils (deprecated)
# Added: [multilib] is enabled, so lib32-nvidia-utils will work
pacstrap -K /mnt \
    base linux-cachyos linux-cachyos-headers \
    linux-firmware amd-ucode \
    base-devel git neovim vim nano \
    btrfs-progs \
    networkmanager openssh \
    nvidia-dkms nvidia-utils lib32-nvidia-utils \
    qemu-full libvirt virt-manager virt-viewer ovmf swtpm edk2-ovmf \
    dnsmasq iptables-nft \
    usbutils libusb \
    docker docker-compose docker-buildx \
    python python-pip python-virtualenv python-numpy \
    ffmpeg \
    hyprland xdg-desktop-portal-hyprland \
    polkit-kde-agent qt5-wayland qt6-wayland \
    sddm \
    waybar rofi-wayland dunst swww grim slurp wl-clipboard cliphist \
    kitty \
    thunar thunar-volman gvfs \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol \
    ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji \
    brightnessctl playerctl bluez bluez-utils \
    nm-connection-editor \
    zram-generator \
    man-db man-pages \
    htop btop \
    wget curl unzip zip \
    2>&1 | while read line; do echo "  $line"; done

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    print_error "Pacstrap failed. Check internet or mirror status."
fi

print_msg "Base system installed"

##############################################################################
# PHASE 7: Generate fstab
##############################################################################

print_header "PHASE 7: GENERATING FSTAB"
genfstab -U /mnt >> /mnt/etc/fstab
print_msg "fstab generated"

##############################################################################
# PHASE 8: Chroot Configuration
##############################################################################

print_header "PHASE 8: SYSTEM CONFIGURATION"

cat > /mnt/root/chroot-config.sh << CHROOTEOF
#!/bin/bash
set -euo pipefail

# Ensure multilib is enabled inside chroot as well for future updates
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

echo "[*] Setting timezone..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echo "[*] Configuring locale..."
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen >/dev/null 2>&1
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "[*] Setting hostname..."
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

echo "[*] Configuring mkinitcpio..."
# Added nvidia modules
sed -i 's/^MODULES=()/MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P >/dev/null 2>&1

echo "[*] Configuring Bootloader..."
bootctl install >/dev/null 2>&1

ROOT_UUID=\$(blkid -s UUID -o value ${DISK}p3)

cat > /boot/loader/loader.conf << 'EOF'
default 01-arch-vfio.conf
timeout 5
console-mode max
editor no
EOF

# Note: Using linux-cachyos image names
cat > /boot/loader/entries/01-arch-vfio.conf << EOF
title   Arch Linux (VFIO)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw amd_iommu=on iommu=pt video=efifb:off vfio-pci.ids=10de:25a0,10de:2291 kvm.ignore_msrs=1 kvm_amd.npt=1 kvm_amd.avic=1
EOF

cat > /boot/loader/entries/02-arch-nvidia.conf << EOF
title   Arch Linux (NVIDIA)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw amd_iommu=on iommu=pt kvm.ignore_msrs=1 kvm_amd.npt=1 kvm_amd.avic=1
EOF

echo "[*] User Configuration..."
echo "Set ROOT password:"
passwd
useradd -m -G wheel,libvirt,docker,video,audio,input -s /bin/bash ${USERNAME}
echo "Set USER password for ${USERNAME}:"
passwd ${USERNAME}
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "[*] Enabling Services..."
systemctl enable NetworkManager sddm libvirtd docker bluetooth

echo "[*] ZRAM Config..."
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 4
compression-algorithm = zstd
EOF

echo "[*] Swapfile..."
mkdir -p /swap
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
dd if=/dev/zero of=/swap/swapfile bs=1M count=8192 status=none
chmod 600 /swap/swapfile
mkswap /swap/swapfile >/dev/null
echo "/swap/swapfile none swap sw,pri=10 0 0" >> /etc/fstab

echo "[*] Permissions..."
# Fix permissions for the nested AI workspace
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/ai_workspace
chmod -R 755 /home/${USERNAME}/ai_workspace

CHROOTEOF

chmod +x /mnt/root/chroot-config.sh
print_step "Running chroot configuration..."
arch-chroot /mnt /root/chroot-config.sh
rm /mnt/root/chroot-config.sh

##############################################################################
# PHASE 9: Finalize
##############################################################################

print_header "PHASE 9: FINISHING UP"
print_step "Unmounting..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  INSTALLATION COMPLETE! REBOOTING...${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
confirm "Press ENTER to reboot."
reboot