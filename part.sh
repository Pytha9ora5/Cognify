
#!/bin/bash
# Arch Linux + Hyprland Installation Script for HP Pavilion ec2019ne
# Ryzen 7 5800H + RTX 3050Ti | iGPU-focused config

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Arch Linux Installation Script ===${NC}"

# Verify boot mode
if [ ! -d /sys/firmware/efi ]; then
    echo -e "${RED}Not booted in UEFI mode. Exiting.${NC}"
    exit 1
fi

# Set keyboard layout
loadkeys us

# Sync time
timedatectl set-ntp true

# Partition disk
echo -e "${YELLOW}Partitioning /dev/nvme0n1...${NC}"
parted /dev/nvme0n1 --script mklabel gpt \
    mkpart ESP fat32 1MiB 1025MiB \
    set 1 esp on \
    mkpart BOOT ext4 1025MiB 2049MiB \
    mkpart ROOT btrfs 2049MiB 100%

# Format partitions
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.ext4 -F /dev/nvme0n1p2
mkfs.btrfs -f /dev/nvme0n1p3

# Mount root and create subvolumes
mount /dev/nvme0n1p3 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

# Mount with optimal options
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ /dev/nvme0n1p3 /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount /dev/nvme0n1p2 /mnt/boot
mkdir /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home /dev/nvme0n1p3 /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots /dev/nvme0n1p3 /mnt/.snapshots
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@var_log /dev/nvme0n1p3 /mnt/var/log

# Install base system with CachyOS kernel
pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers linux-firmware amd-ucode

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot and configure
arch-chroot /mnt /bin/bash <<EOF
# Set timezone
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "arch-hp" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-hp.localdomain arch-hp
HOSTS

# Root password
echo "root:root" | chpasswd

# Create swapfile
btrfs filesystem mkswapfile --size 16g /swap/swapfile
swapon /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

# Install essential packages
pacman -S --noconfirm \
    grub efibootmgr networkmanager git vim nano \
    hyprland kitty waybar wofi dunst \
    pipewire pipewire-pulse pipewire-alsa wireplumber \
    mesa vulkan-radeon libva-mesa-driver \
    xdg-desktop-portal-hyprland polkit-kde-agent \
    thunar grim slurp wl-clipboard \
    btop htop neofetch \
    ttf-font-awesome ttf-dejavu noto-fonts-emoji

# Install bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Enable services
systemctl enable NetworkManager

# Create user
useradd -m -G wheel,audio,video,storage -s /bin/bash user
echo "user:user" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

EOF

# Finish
echo -e "${GREEN}Installation complete!${NC}"
echo -e "${YELLOW}Unmounting and ready to reboot.${NC}"
umount -R /mnt
echo -e "${GREEN}You can now reboot. Remove installation media.${NC}"
```
