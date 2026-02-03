#!/bin/bash
set -euo pipefail

##############################################################################
# Arch Linux - Partitioning & BTRFS Subvolumes Only
# HP Pavilion Gaming - 500GB NVMe
##############################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

##############################################################################
# Configuration
##############################################################################

DISK="/dev/nvme0n1"
USERNAME="muhammad"  # Used for creating home directory path

##############################################################################
# Helper Functions
##############################################################################

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

##############################################################################
# Pre-flight Checks
##############################################################################

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PARTITIONING & BTRFS SUBVOLUMES SETUP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
fi

# Check disk exists
if [[ ! -b ${DISK} ]]; then
    print_error "Disk ${DISK} not found"
fi

# Show disk info
print_step "Target disk information:"
lsblk ${DISK}
echo ""

print_warning "WARNING: This will DESTROY ALL DATA on ${DISK}"
read -p "Type 'YES' to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    print_error "Aborted by user"
fi

##############################################################################
# Cleanup
##############################################################################

print_step "Cleaning up any previous mounts..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
sleep 2
print_msg "Cleanup complete"

##############################################################################
# PHASE 1: Disk Partitioning
##############################################################################

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 1: DISK PARTITIONING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_step "Wiping existing partition table..."
wipefs -af ${DISK} >/dev/null 2>&1
sgdisk --zap-all ${DISK} >/dev/null 2>&1
print_msg "Disk wiped"

print_step "Creating GPT partition table..."
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" ${DISK} >/dev/null
sgdisk -n 2:0:+1G -t 2:8300 -c 2:"BOOT" ${DISK} >/dev/null
sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" ${DISK} >/dev/null
print_msg "Partitions created"

print_step "Informing kernel of changes..."
partprobe ${DISK}
sleep 3
print_msg "Kernel updated"

echo ""
print_msg "Partition layout:"
lsblk ${DISK}
echo ""

##############################################################################
# PHASE 2: Format Filesystems
##############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 2: FORMATTING FILESYSTEMS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_step "Formatting ${DISK}p1 (EFI) as FAT32..."
mkfs.fat -F32 ${DISK}p1 >/dev/null 2>&1
print_msg "EFI partition formatted"

print_step "Formatting ${DISK}p2 (Boot) as ext4..."
mkfs.ext4 -F ${DISK}p2 >/dev/null 2>&1
print_msg "Boot partition formatted"

print_step "Formatting ${DISK}p3 (Root) as BTRFS..."
mkfs.btrfs -f -L archlinux ${DISK}p3 >/dev/null 2>&1
print_msg "Root partition formatted"

echo ""
print_msg "All filesystems formatted successfully"
echo ""

##############################################################################
# PHASE 3: Create BTRFS Subvolumes
##############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 3: CREATING BTRFS SUBVOLUMES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_step "Mounting root partition temporarily..."
mount ${DISK}p3 /mnt
print_msg "Mounted to /mnt"

print_step "Creating subvolumes..."

btrfs subvolume create /mnt/@ >/dev/null
echo "  ✓ @ (root)"

btrfs subvolume create /mnt/@home >/dev/null
echo "  ✓ @home (user data)"

btrfs subvolume create /mnt/@var_log >/dev/null
echo "  ✓ @var_log (system logs)"

btrfs subvolume create /mnt/@var_lib_docker >/dev/null
echo "  ✓ @var_lib_docker (Docker containers)"

btrfs subvolume create /mnt/@snapshots >/dev/null
echo "  ✓ @snapshots (system snapshots)"

btrfs subvolume create /mnt/@qemu >/dev/null
echo "  ✓ @qemu (Windows VM disk)"

btrfs subvolume create /mnt/@shared >/dev/null
echo "  ✓ @shared (host-VM data exchange)"

btrfs subvolume create /mnt/@ai_workspace >/dev/null
echo "  ✓ @ai_workspace (AI video analysis)"

echo ""
print_msg "All subvolumes created"

echo ""
print_step "Subvolume list:"
btrfs subvolume list /mnt

print_step "Unmounting temporary mount..."
umount /mnt
print_msg "Unmounted"

echo ""

##############################################################################
# PHASE 4: Mount with Optimized Options
##############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 4: MOUNTING FILESYSTEMS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_step "Mounting @ (root) subvolume..."
mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@ ${DISK}p3 /mnt
echo "  Mounted: @ → /mnt"
echo "  Options: noatime,compress=zstd:1,space_cache=v2,ssd"

print_step "Creating base directory structure..."
mkdir -p /mnt/boot
mkdir -p /mnt/boot/efi
mkdir -p /mnt/home
mkdir -p /mnt/var/log
mkdir -p /mnt/var/lib/docker
mkdir -p /mnt/.snapshots
mkdir -p /mnt/var/lib/libvirt/images
mkdir -p /mnt/mnt/shared
print_msg "Base directories created"

print_step "Mounting subvolumes..."

mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@home ${DISK}p3 /mnt/home
echo "  ✓ @home → /mnt/home (compress=zstd:1)"

mount -o noatime,compress=zstd:2,space_cache=v2,ssd,subvol=@var_log ${DISK}p3 /mnt/var/log
echo "  ✓ @var_log → /mnt/var/log (compress=zstd:2)"

mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@var_lib_docker ${DISK}p3 /mnt/var/lib/docker
echo "  ✓ @var_lib_docker → /mnt/var/lib/docker (no compress, no CoW)"

mount -o noatime,compress=zstd:1,space_cache=v2,ssd,subvol=@snapshots ${DISK}p3 /mnt/.snapshots
echo "  ✓ @snapshots → /mnt/.snapshots (compress=zstd:1)"

mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@qemu ${DISK}p3 /mnt/var/lib/libvirt/images
echo "  ✓ @qemu → /mnt/var/lib/libvirt/images (no compress, no CoW)"

mount -o noatime,compress=zstd:3,space_cache=v2,ssd,subvol=@shared ${DISK}p3 /mnt/mnt/shared
echo "  ✓ @shared → /mnt/mnt/shared (compress=zstd:3)"

print_step "Creating user home directory..."
mkdir -p /mnt/home/${USERNAME}
mkdir -p /mnt/home/${USERNAME}/ai_workspace
print_msg "User directories created"

print_step "Mounting ai_workspace subvolume..."
mount -o noatime,compress=no,space_cache=v2,ssd,nodatacow,subvol=@ai_workspace ${DISK}p3 /mnt/home/${USERNAME}/ai_workspace
echo "  ✓ @ai_workspace → /mnt/home/${USERNAME}/ai_workspace (no compress, no CoW)"

print_step "Mounting boot partitions..."
mount ${DISK}p2 /mnt/boot
echo "  ✓ ${DISK}p2 → /mnt/boot (ext4)"

mount ${DISK}p1 /mnt/boot/efi
echo "  ✓ ${DISK}p1 → /mnt/boot/efi (FAT32)"

echo ""
print_msg "All filesystems mounted"

echo ""

##############################################################################
# Verification & Summary
##############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VERIFICATION & SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_step "Current mount structure:"
echo ""
lsblk -f ${DISK}
echo ""

print_step "Mounted filesystems:"
echo ""
mount | grep ${DISK} | sed 's/^/  /'
echo ""

print_step "BTRFS subvolumes on ${DISK}p3:"
echo ""
btrfs subvolume list /mnt | sed 's/^/  /'
echo ""

print_step "Disk space usage:"
echo ""
df -h | grep -E "Filesystem|${DISK}|/mnt" | sed 's/^/  /'
echo ""

##############################################################################
# Summary Information
##############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PARTITIONING & SUBVOLUMES COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Partition Layout:"
echo "  ${DISK}p1  1GB    FAT32   /mnt/boot/efi"
echo "  ${DISK}p2  1GB    ext4    /mnt/boot"
echo "  ${DISK}p3  ~464GB BTRFS   /mnt (with 8 subvolumes)"
echo ""
echo "BTRFS Subvolumes:"
echo "  @                → /mnt                            (system files)"
echo "  @home            → /mnt/home                       (user data)"
echo "  @var_log         → /mnt/var/log                    (logs)"
echo "  @var_lib_docker  → /mnt/var/lib/docker             (Docker)"
echo "  @snapshots       → /mnt/.snapshots                 (snapshots)"
echo "  @qemu            → /mnt/var/lib/libvirt/images     (Windows VM)"
echo "  @shared          → /mnt/mnt/shared                 (host-VM share)"
echo "  @ai_workspace    → /mnt/home/${USERNAME}/ai_workspace (AI work)"
echo ""
echo "Mount Options Summary:"
echo "  System (@, @home, @snapshots):    compress=zstd:1"
echo "  Logs (@var_log):                  compress=zstd:2 (higher ratio)"
echo "  Shared (@shared):                 compress=zstd:3 (max compression)"
echo "  Performance (@docker, @qemu, @ai): compress=no, nodatacow"
echo ""
echo "Next Steps:"
echo "  1. Proceed with: pacstrap -K /mnt base linux ..."
echo "  2. Or unmount if just testing: umount -R /mnt"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
