#!/bin/bash
set -euo pipefail

##############################################################################
# Arch Linux Automated Installation Script
# HP Pavilion Gaming - R7 5800H - RTX 3050 Ti - 500GB NVMe
# No Encryption | BTRFS Subvolumes | Hyprland | VFIO Default Boot
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

# Check root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root. Use: sudo ./install.sh"
fi

# Check UEFI
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    print_error "Not booted in UEFI mode. Reboot in UEFI mode and try again."
fi

# Check internet
print_step "Checking internet connectivity..."
if ! ping -c 1 archlinux.org &>/dev/null; then
    print_error "No internet connection detected.

To connect WiFi:
  iwctl
  station wlan0 connect \"YOUR_WIFI_NAME\"
  exit

Then run this script again."
fi
print_msg "Internet connection OK"

# Check disk exists
if [[ ! -b ${DISK} ]]; then
    print_error "Disk ${DISK} not found. Available disks:"
    lsblk -d -o NAME,SIZE,TYPE | grep disk
fi

# Display system info
print_step "System Information:"
echo "  CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Target Disk: ${DISK} ($(lsblk -dno SIZE ${DISK}))"
echo ""

##############################################################################
# Get User Configuration
##############################################################################

print_header "CONFIGURATION"

# Get username
while [[ -z "${USERNAME}" ]]; do
    read -p "Enter username for new user: " USERNAME
    if [[ ! "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "Invalid username. Use lowercase letters, numbers, dash, underscore only."
        USERNAME=""
    fi
done

# Get hostname
while [[ -z "${HOSTNAME}" ]]; do
    read -p "Enter hostname for this system: " HOSTNAME
    if [[ ! "${HOSTNAME}" =~ ^[a-z0-9-]+$ ]]; then
        print_error "Invalid hostname. Use lowercase letters, numbers, dash only."
        HOSTNAME=""
    fi
done

echo ""
print_msg "Configuration:"
echo "  Username: ${USERNAME}"
echo "  Hostname: ${HOSTNAME}"
echo "  Timezone: ${TIMEZONE}"
echo "  Locale: ${LOCALE}"
echo ""

confirm "WARNING: This will DESTROY ALL DATA on ${DISK}!"

##############################################################################
# Cleanup Previous Attempts
##############################################################################

print_header "CLEANUP"

print_step "Unmounting any previous installation attempts..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
sleep 2
print_msg "Cleanup complete"

##############################################################################
# PHASE 1: Disk Partitioning
##############################################################################

print_header "PHASE 1: DISK PARTITIONING"

print_step "Wiping existing partition table..."
wipefs -af ${DISK} >/dev/null 2>&1
sgdisk --zap-all ${DISK} >/dev/null 2>&1

print_step "Creating new GPT partition table..."
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" ${DISK} >/dev/null
sgdisk -n 2:0:+1G -t 2:8300 -c 2:"BOOT" ${DISK} >/dev/null
sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" ${DISK} >/dev/null

print_step "Informing kernel of partition changes..."
partprobe ${DISK}
sleep 3

print_msg "Partitions created:"
lsblk ${DISK}

##############################################################################
# PHASE 2: Format Filesystems
##############################################################################

print_header "PHASE 2: FORMATTING FILESYSTEMS"

print_step "Formatting EFI partition (FAT32)..."
mkfs.fat -F32 ${DISK}p1 >/dev/null 2>&1

print_step "Formatting boot partition (ext4)..."
mkfs.ext4 -F ${DISK}p2 >/dev/null 2>&1

print_step "Formatting root partition (BTRFS)..."
mkfs.btrfs -f -L archlinux ${DISK}p3 >/dev/null 2>&1

print_msg "All filesystems formatted"

##############################################################################
# PHASE 3: Create BTRFS Subvolumes
##############################################################################

print_header "PHASE 3: CREATING BTRFS SUBVOLUMES"

print_step "Mounting root partition temporarily..."
mount ${DISK}p3 /mnt

print_step "Creating subvolumes..."
btrfs subvolume create /mnt/@ >/dev/null
btrfs subvolume create /mnt/@home >/dev/null
btrfs subvolume create /mnt/@var_log >/dev/null
btrfs subvolume create /mnt/@var_lib_docker >/dev/null
btrfs subvolume create /mnt/@snapshots >/dev/null
btrfs subvolume create /mnt/@qemu >/dev/null
btrfs subvolume create /mnt/@shared >/dev/null
btrfs subvolume create /mnt/@ai_workspace >/dev/null

print_msg "Subvolumes created:"
btrfs subvolume list /mnt | sed 's/^/  /'

umount /mnt

##############################################################################
# PHASE 4: Mount with Optimized Options
##############################################################################

print_header "PHASE 4: MOUNTING FILESYSTEMS"

print_step "Mounting root subvolume..."
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@ ${DISK}p3 /mnt

print_step "Creating mount point directories..."
mkdir -p /mnt/boot
mkdir -p /mnt/boot/efi
mkdir -p /mnt/home
mkdir -p /mnt/var/log
mkdir -p /mnt/var/lib/docker
mkdir -p /mnt/.snapshots
mkdir -p /mnt/var/lib/libvirt/images
mkdir -p /mnt/mnt/shared

print_step "Mounting subvolumes with optimized options..."
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@home ${DISK}p3 /mnt/home
mount -o noatime,compress=zstd:2,space_cache=v2,ssd,subvol=@var_log ${DISK}p3 /mnt/var/log
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@var_lib_docker ${DISK}p3 /mnt/var/lib/docker
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@snapshots ${DISK}p3 /mnt/.snapshots
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@qemu ${DISK}p3 /mnt/var/lib/libvirt/images
mount -o noatime,compress=zstd:3,space_cache=v2,ssd,subvol=@shared ${DISK}p3 /mnt/mnt/shared

print_step "Creating user home directory structure..."
mkdir -p /mnt/home/${USERNAME}
mkdir -p /mnt/home/${USERNAME}/ai_workspace

print_step "Mounting ai_workspace subvolume..."
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@ai_workspace ${DISK}p3 /mnt/home/${USERNAME}/ai_workspace

print_step "Mounting boot partitions..."
mount ${DISK}p2 /mnt/boot
mount ${DISK}p1 /mnt/boot/efi

print_msg "Mount structure complete:"
lsblk -f ${DISK} | sed 's/^/  /'

##############################################################################
# PHASE 5: Configure Package Manager
##############################################################################

print_header "PHASE 5: CONFIGURING PACKAGE MANAGER"

print_step "Optimizing mirrorlist..."
reflector --country Egypt,Germany --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || print_warning "Reflector skipped, using default mirrors"

print_step "Enabling parallel downloads..."
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

print_step "Adding CachyOS repository..."
if ! grep -q "\[cachyos\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf << 'EOF'

# CachyOS Repository
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

    cat > /etc/pacman.d/cachyos-mirrorlist << 'EOF'
Server = https://mirror.cachyos.org/repo/$arch/$repo
Server = https://cdn.cachyos.org/repo/$arch/$repo
EOF
fi

print_step "Importing CachyOS GPG keys..."
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com 2>/dev/null || true
pacman-key --lsign-key F3B607488DB35A47 2>/dev/null || true

print_step "Updating package databases..."
pacman -Sy --noconfirm >/dev/null

print_msg "Package manager configured"

##############################################################################
# PHASE 6: Install Base System
##############################################################################

print_header "PHASE 6: INSTALLING BASE SYSTEM"

print_warning "This will take 10-15 minutes depending on internet speed..."

print_step "Installing packages via pacstrap..."

pacstrap -K /mnt \
    base linux-cachyos linux-cachyos-headers \
    linux-firmware amd-ucode \
    base-devel git neovim vim nano \
    btrfs-progs \
    networkmanager openssh \
    nvidia-dkms nvidia-utils lib32-nvidia-utils \
    qemu-full libvirt virt-manager virt-viewer ovmf swtpm edk2-ovmf \
    dnsmasq iptables-nft bridge-utils \
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
    wget curl \
    unzip zip \
    2>&1 | while read line; do
        echo "  $line"
    done

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    print_error "Pacstrap failed. Check your internet connection and try again."
fi

print_msg "Base system installed successfully"

##############################################################################
# PHASE 7: Generate fstab
##############################################################################

print_header "PHASE 7: GENERATING FSTAB"

genfstab -U /mnt >> /mnt/etc/fstab

print_msg "fstab generated"

##############################################################################
# PHASE 8: Chroot Configuration
##############################################################################

print_header "PHASE 8: CONFIGURING SYSTEM"

cat > /mnt/root/chroot-config.sh << CHROOTEOF
#!/bin/bash
set -euo pipefail

USERNAME="${USERNAME}"
HOSTNAME="${HOSTNAME}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
DISK="${DISK}"

echo "[*] Setting timezone..."
ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

echo "[*] Configuring locale..."
sed -i "s/^#\${LOCALE}/\${LOCALE}/" /etc/locale.gen
locale-gen >/dev/null 2>&1
echo "LANG=\${LOCALE}" > /etc/locale.conf

echo "[*] Setting hostname..."
echo "\${HOSTNAME}" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
EOF

echo "[*] Configuring mkinitcpio..."
cat > /etc/mkinitcpio.conf << 'EOF'
MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
EOF

echo "[*] Regenerating initramfs..."
mkinitcpio -P 2>&1 | grep -E "Preset|==>" || true

echo "[*] Configuring NVIDIA modules..."
mkdir -p /etc/modprobe.d

cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia_drm modeset=1
EOF

cat > /etc/modprobe.d/vfio.conf << 'EOF'
options vfio-pci ids=10de:25a0,10de:2291
softdep nvidia pre: vfio-pci
EOF

cat > /etc/modprobe.d/kvm.conf << 'EOF'
options kvm_amd nested=1
options kvm_amd npt=1
options kvm_amd avic=1
EOF

echo "[*] Installing bootloader..."
bootctl install 2>&1 | grep -v "Copied" || true

ROOT_UUID=\$(blkid -s UUID -o value \${DISK}p3)

cat > /boot/loader/loader.conf << 'EOF'
default 01-arch-vfio.conf
timeout 5
console-mode max
editor no
EOF

cat > /boot/loader/entries/01-arch-vfio.conf << EOF
title   Arch Linux (VFIO - Windows VM Ready) [DEFAULT]
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw amd_iommu=on iommu=pt video=efifb:off vfio-pci.ids=10de:25a0,10de:2291 kvm.ignore_msrs=1 kvm_amd.npt=1 kvm_amd.avic=1
EOF

cat > /boot/loader/entries/02-arch-nvidia.conf << EOF
title   Arch Linux (NVIDIA - AI/CUDA Mode)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw amd_iommu=on iommu=pt kvm.ignore_msrs=1 kvm_amd.npt=1 kvm_amd.avic=1
EOF

cat > /boot/loader/entries/03-arch-fallback.conf << EOF
title   Arch Linux (Fallback Initramfs)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos-fallback.img
options root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw
EOF

echo "[*] Setting root password..."
echo "Enter password for root user:"
passwd

echo "[*] Creating user: \${USERNAME}..."
useradd -m -G wheel,libvirt,docker,video,audio,input -s /bin/bash \${USERNAME}
echo "Enter password for \${USERNAME}:"
passwd \${USERNAME}

echo "[*] Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "[*] Enabling services..."
systemctl enable NetworkManager >/dev/null 2>&1
systemctl enable sddm >/dev/null 2>&1
systemctl enable libvirtd >/dev/null 2>&1
systemctl enable docker >/dev/null 2>&1
systemctl enable bluetooth >/dev/null 2>&1

echo "[*] Configuring libvirt..."
sed -i 's/^#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' /etc/libvirt/libvirtd.conf
sed -i 's/^#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' /etc/libvirt/libvirtd.conf

cat >> /etc/libvirt/qemu.conf << EOF
user = "\${USERNAME}"
group = "libvirt"
EOF

echo "[*] Configuring Docker..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
    "data-root": "/var/lib/docker",
    "storage-driver": "overlay2"
}
EOF

echo "[*] Configuring zram..."
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 4
compression-algorithm = zstd
swap-priority = 100
EOF

echo "[*] Creating swap file..."
mkdir -p /swap
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
dd if=/dev/zero of=/swap/swapfile bs=1M count=16384 status=none
chmod 600 /swap/swapfile
mkswap /swap/swapfile >/dev/null

echo "/swap/swapfile none swap sw,pri=10 0 0" >> /etc/fstab

echo "[*] Disabling CoW on performance-critical directories..."
chattr +C /var/lib/docker 2>/dev/null || true
chattr +C /var/lib/libvirt/images 2>/dev/null || true
chattr +C /home/\${USERNAME}/ai_workspace 2>/dev/null || true

echo "[*] Creating AI workspace structure..."
mkdir -p /home/\${USERNAME}/ai_workspace/{videos_input,videos_processing,models/{whisper,deepface,ocr},output/{transcripts,facial_analysis,ocr_results},cache}
chown -R \${USERNAME}:\${USERNAME} /home/\${USERNAME}/ai_workspace
chmod -R 755 /home/\${USERNAME}/ai_workspace

echo "[*] Creating Hyprland config directory..."
mkdir -p /home/\${USERNAME}/.config/hypr
chown -R \${USERNAME}:\${USERNAME} /home/\${USERNAME}/.config

echo "[*] Creating post-install guide..."
cat > /home/\${USERNAME}/POST_INSTALL_GUIDE.txt << 'POSTEOF'
╔═══════════════════════════════════════════════════════════════════╗
║           ARCH LINUX INSTALLATION COMPLETE!                        ║
║           HP Pavilion Gaming - R7 5800H - RTX 3050 Ti             ║
╚═══════════════════════════════════════════════════════════════════╝

LOGIN INFORMATION:
  Username: $(whoami | head -n1)
  
BOOT MODES:
  Your system has 2 boot modes (select at startup):
  
  1. [DEFAULT] VFIO Mode - Windows VM Ready
     - NVIDIA GPU reserved for Windows VM
     - Linux uses AMD iGPU for desktop
     - Windows VM boots instantly with full GPU
     - Use this for daily work + occasional Windows
  
  2. NVIDIA Mode - AI/CUDA
     - NVIDIA GPU available to Linux
     - CUDA works for AI video analysis
     - Windows VM cannot start in this mode
     - Reboot to VFIO mode when Windows needed

TO SWITCH MODES:
  sudo reboot
  (Select mode at boot menu - 5 second timeout)

POST-INSTALLATION STEPS:

1. Install AUR helper (paru):
   cd /tmp
   git clone https://aur.archlinux.org/paru.git
   cd paru
   makepkg -si

2. Install AUR packages:
   paru -S nvidia-container-toolkit ttf-jetbrains-mono-nerd

3. Configure Hyprland:
   cp /usr/share/hyprland/hyprland.conf ~/.config/hypr/
   nano ~/.config/hypr/hyprland.conf
   
   Add these environment variables at the top:
   env = LIBVA_DRIVER_NAME,nvidia
   env = GBM_BACKEND,nvidia-drm
   env = __GLX_VENDOR_LIBRARY_NAME,nvidia
   env = WLR_NO_HARDWARE_CURSORS,1

4. Enable Docker GPU support:
   After installing nvidia-container-toolkit:
   
   sudo nano /etc/docker/daemon.json
   
   Change to:
   {
       "data-root": "/var/lib/docker",
       "storage-driver": "overlay2",
       "runtimes": {
           "nvidia": {
               "path": "nvidia-container-runtime",
               "runtimeArgs": []
           }
       },
       "default-runtime": "nvidia"
   }
   
   sudo systemctl restart docker

5. Test Docker GPU (boot in NVIDIA mode first):
   docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi

6. Setup Windows 11 VM:
   - Copy vbios.rom to home directory if on USB
   - Open virt-manager
   - Create new VM with Windows 11 ISO
   - Configure GPU passthrough (attach vbios.rom)
   - Install Looking Glass for seamless display

7. Setup n8n + AI services:
   Create docker-compose.yml in ~/docker/

IMPORTANT DIRECTORIES:
  ~/ai_workspace/          - AI video analysis workspace
  /mnt/shared/             - Share files with Windows VM
  /var/lib/libvirt/images/ - VM disk images
  ~/.config/hypr/          - Hyprland configuration

USEFUL COMMANDS:
  nvidia-smi              - Check GPU status (NVIDIA mode only)
  docker ps               - List running containers
  virt-manager            - Manage VMs
  btop                    - System monitor
  journalctl -b           - View boot logs

TROUBLESHOOTING:
  - If Hyprland won't start: Check ~/.config/hypr/hyprland.conf
  - If VM won't start: Boot in VFIO mode
  - If CUDA not working: Boot in NVIDIA mode
  - For system logs: journalctl -xe

╔═══════════════════════════════════════════════════════════════════╗
║  Next: Install paru, configure Hyprland, create Windows VM        ║
╚═══════════════════════════════════════════════════════════════════╝
POSTEOF

chown \${USERNAME}:\${USERNAME} /home/\${USERNAME}/POST_INSTALL_GUIDE.txt

echo ""
echo "=========================================="
echo "  Chroot configuration complete!"
echo "=========================================="

CHROOTEOF

chmod +x /mnt/root/chroot-config.sh

print_step "Entering chroot environment..."
arch-chroot /mnt /root/chroot-config.sh

rm /mnt/root/chroot-config.sh

print_msg "System configuration complete"

##############################################################################
# PHASE 9: Unmount and Finish
##############################################################################

print_header "PHASE 9: FINALIZING INSTALLATION"

print_step "Unmounting all filesystems..."
umount -R /mnt 2>/dev/null || true

print_msg "All filesystems unmounte
