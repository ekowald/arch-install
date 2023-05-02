#!/bin/bash

# Arch Linux Installation Script
# This script will install Arch Linux with X11, i3-gaps, and a minimalistic yet work-ready environment.

# Make sure you run the script as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run the script as root"
  exit 1
fi

# Update the system clock
timedatectl set-ntp true

# Partition the disks
# NOTE: This partitioning scheme assumes UEFI and a single disk (/dev/nvme0n1)
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart primary fat32 1MiB 513MiB
parted -s /dev/nvme0n1 set 1 esp on
parted -s /dev/nvme0n1 mkpart primary ext4 513MiB 100%

# Format the partitions
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.ext4 /dev/nvme0n1p2

# Mount the file systems
mount /dev/nvme0n1p2 /mnt
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

# Install essential packages
pacstrap /mnt base base-devel linux linux-firmware git vim

# Generate an fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt

# Set the time zone
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime

# Run hwclock(8) to generate /etc/adjtime
hwclock --systohc

# Localization
# Uncomment the en_US.UTF-8 UTF-8 line in /etc/locale.gen
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# Set the LANG variable in locale.conf(5)
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Network configuration
# Replace "erik-arch" with your desired hostname
echo "erik-arch" > /etc/hostname

# Add matching entries to hosts(5)
{
echo "127.0.0.1 localhost"
echo "::1       localhost"
echo "127.0.1.1 erik-arch.localdomain erik-arch"
} > /etc/hosts

# Enable dhcpcd
systemctl enable dhcpcd

# Root password
passwd root

# Add a new user
# Replace "myusername" with your desired username
useradd -m -G wheel -s /bin/bash erik
passwd myusername

# Configure sudo
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Install bootloader (systemd-boot)
bootctl --path=/boot install

# Create loader configuration
echo "default arch" > /boot/loader/loader.conf
echo "timeout 3" >> /boot/loader/loader.conf

# Create an entry for Arch Linux
{
echo "title Arch Linux"
echo "linux /vmlinuz-linux"
echo "initrd /initramfs-linux.img"
echo "options root=$(findmnt -no UUID /) rw"
} > /boot/loader/entries/arch.conf

# Exit chroot environment
exit

# Unmount all partitions
umount -R /mnt

# Reboot
reboot