#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Variables
HOSTNAME="archy"
USERNAME="erik"
TIMEZONE="America/Chicago"
LOCALE="en_US.UTF-8"
LANGUAGE="en_US.UTF-8"
KEYMAP="us"
FONT="lat9w-16"
DISK="/dev/sda"  # Adjust if necessary

# Partitions
BOOT_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"

# Update system clock
timedatectl set-ntp true

# Partition the disk (GPT)
echo "Partitioning the disk..."
parted -s $DISK mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB \
  set 1 boot on \
  mkpart primary btrfs 513MiB 100%

# Format the partitions
echo "Formatting the partitions..."
mkfs.fat -F32 $BOOT_PARTITION
mkfs.btrfs -f $ROOT_PARTITION

# Mount the root partition
echo "Mounting the root partition..."
mount -o noatime,compress=zstd,subvol=@ $ROOT_PARTITION /mnt

# Create mount points and mount other subvolumes
mkdir -p /mnt/{boot,home,var,tmp,.snapshots}
mount -o noatime,compress=zstd,subvol=@home $ROOT_PARTITION /mnt/home
mount -o noatime,compress=zstd,subvol=@var $ROOT_PARTITION /mnt/var
mount -o noatime,compress=zstd,subvol=@tmp $ROOT_PARTITION /mnt/tmp
mount -o noatime,compress=zstd,subvol=@.snapshots $ROOT_PARTITION /mnt/.snapshots

# Unmount and remount the subvolumes
umount /mnt
mount -o noatime,compress=zstd,space_cache,subvol=@ $ROOT_PARTITION /mnt

# Create mount points and mount other subvolumes
mkdir -p /mnt/{boot,home,var,tmp,.snapshots}
mount -o noatime,compress=zstd,space_cache,subvol=@home $ROOT_PARTITION /mnt/home
mount -o noatime,compress=zstd,space_cache,subvol=@var $ROOT_PARTITION /mnt/var
mount -o noatime,compress=zstd,space_cache,subvol=@tmp $ROOT_PARTITION /mnt/tmp
mount -o noatime,compress=zstd,space_cache,subvol=@.snapshots $ROOT_PARTITION /mnt/.snapshots

# Mount the boot partition
mount $BOOT_PARTITION /mnt/boot

# Install essential packages
echo "Installing essential packages..."
pacstrap /mnt base linux linux-firmware base-devel git wget neovim \
  intel-ucode networkmanager openssh btrfs-progs sudo vim htop \
  alacritty gnome gnome-extra i3 fish docker docker-compose \
  xorg xorg-server xorg-apps xorg-xinit net-tools dnsutils zip unzip rsync tree

# Generate fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
echo "Entering chroot environment..."
arch-chroot /mnt /bin/bash <<EOF

# Set the timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LANGUAGE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname and hosts file
echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Install and configure systemd-boot
bootctl install
cat > /boot/loader/loader.conf <<EOL
default arch.conf
timeout 3
editor 0
EOL

# Get the PARTUUID for the root partition
PARTUUID=$(blkid -s PARTUUID -o value $ROOT_PARTITION)

# Create boot entry
cat > /boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=$PARTUUID rw rootflags=subvol=@
EOL

# Set root password
echo "Set root password:"
passwd root

# Create new user
useradd -m -G wheel,docker -s /usr/bin/fish $USERNAME
echo "Set password for $USERNAME:"
passwd $USERNAME

# Configure sudoers
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Enable services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable docker

# Install yay (AUR helper)
cd /home/$USERNAME
git clone https://aur.archlinux.org/yay.git
chown -R $USERNAME:$USERNAME yay
cd yay
sudo -u $USERNAME makepkg -si --noconfirm

# Install AUR packages
sudo -u $USERNAME yay -S --noconfirm visual-studio-code-bin nerd-fonts-jetbrains-mono oh-my-fish

# Install themes and icons
pacman -S --noconfirm arc-gtk-theme arc-icon-theme papirus-icon-theme

# Install ClamAV and rkhunter
pacman -S --noconfirm clamav rkhunter
systemctl enable clamav-freshclam.service
freshclam

# Configure firewall (UFW)
pacman -S --noconfirm ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow from any to any port 22 proto tcp
ufw enable

# Set up parallel downloads in pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

# Install Neovim and configure
pacman -S --noconfirm neovim python-pynvim nodejs npm
sudo -u $USERNAME mkdir -p /home/$USERNAME/.config/nvim

# Set default shell to fish
chsh -s /usr/bin/fish $USERNAME

# Install Fisher (Fish plugin manager)
sudo -u $USERNAME fish -c 'curl -sL https://git.io/fisher | source && fisher install jorgebucaran/fisher'

# Install Fish plugins
sudo -u $USERNAME fish -c 'fisher install IlanCosman/tide@v5'

# Enable Wayland for GDM
sed -i 's/#WaylandEnable=false/WaylandEnable=true/' /etc/gdm/custom.conf

# Enable GDM
systemctl enable gdm

EOF

# Unmount all partitions
echo "Unmounting partitions..."
umount -R /mnt

echo "Installation complete! Rebooting..."
reboot
