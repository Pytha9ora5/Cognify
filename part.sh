pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-nvidia linux-firmware sof-firmware amd-ucode networkmanager vim git sudo

echo -e "\033[0;32m>>> STEP 6: CONFIGURING SYSTEM <<<\033[0m"
echo -e "\033[0;32m>>> STEP 8: CONFIGURING <<<\033[0m"
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot Script
cat <<EOF > /mnt/setup_inside.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/${REGION}/${CITY} /etc/localtime
ln -sf /usr/share/zoneinfo/Africa/Cairo /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname
echo "arch-hybrid" > /etc/hostname

systemctl enable NetworkManager

echo "root:root" | chpasswd
useradd -m -G wheel,storage,power,kvm,libvirt,video -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USERNAME}" | chpasswd
useradd -m -G wheel,storage,power,kvm,libvirt,video -s /bin/bash user
echo "user:user" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# REPO SETUP INSIDE
# Repo inside
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
wget https://mirror.cachyos.org/cachyos-repo.tar.xz
@@ -116,7 +134,7 @@
rm -rf cachyos-repo*
pacman -Sy

# SWAP (16GB)
# Swap
truncate -s 0 /swap/swapfile
chattr +C /swap/swapfile
btrfs property set /swap/swapfile compression none
@@ -125,7 +143,7 @@
mkswap /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

# BOOTLOADER
# Bootloader
bootctl install

cat <<BOOTCONF > /boot/loader/entries/arch.conf
@@ -152,4 +170,4 @@
arch-chroot /mnt /setup_inside.sh
rm /mnt/setup_inside.sh

echo "DONE. Reboot now."
echo "SUCCESS! Reboot now."
