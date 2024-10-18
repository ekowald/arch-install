#!/bin/bash

# Arch Linux Automated Installation Script
# This script installs Arch Linux with a customized setup in a VMware virtual machine.

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and ensure that the script exits
# if any command in a pipeline fails.
set -euo pipefail

# Enable logging to 'install.log' for troubleshooting.
exec > >(tee -i install.log)
exec 2>&1

# Trap to catch errors and clean up before exiting.
trap 'echo "An error occurred. Unmounting filesystems..."; umount -R /mnt || true; exit 1' INT TERM ERR

# Variables
HOSTNAME="archy"
USERNAME="erik"
TIMEZONE="America/Chicago"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Function to confirm disk selection
confirm_disk() {
  echo "Available disks:"
  lsblk -dpno NAME,SIZE | grep -E "/dev/sd|/dev/vd|/dev/nvme|/dev/hd"
  read -rp "Please enter the disk to install to (e.g., /dev/sda): " DISK
  if [ ! -b "$DISK" ]; then
    echo "Error: Disk $DISK does not exist."
    exit 1
  fi
  read -rp "Are you sure you want to install on $DISK and erase all data on it? [y/N]: " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Installation cancelled."
    exit 0
  fi
  BOOT_PARTITION="${DISK}1"
  ROOT_PARTITION="${DISK}2"
}

# Function to verify UEFI mode
check_uefi() {
  if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "Error: System is not booted in UEFI mode."
    exit 1
  fi
}

# Function to check internet connectivity
check_internet() {
  if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "Error: No internet connection."
    exit 1
  fi
}

# Function to update system clock
update_clock() {
  echo "Updating system clock..."
  if ! timedatectl set-ntp true; then
    echo "Error: Failed to update system clock."
    exit 1
  fi
}

# Function to partition the disk
partition_disk() {
  echo "Partitioning the disk..."
  parted -s "$DISK" mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 boot on \
    mkpart primary ext4 513MiB 100% || {
      echo "Error: Disk partitioning failed."
      exit 1
    }
}

# Function to format partitions
format_partitions() {
  echo "Formatting the partitions..."
  mkfs.fat -F32 "$BOOT_PARTITION" || { echo "Error formatting EFI partition."; exit 1; }
  mkfs.ext4 -F "$ROOT_PARTITION" || { echo "Error formatting root partition."; exit 1; }
}

# Function to mount partitions
mount_partitions() {
  echo "Mounting the partitions..."
  mount "$ROOT_PARTITION" /mnt || { echo "Error mounting root partition."; exit 1; }
  mkdir -p /mnt/boot
  mount "$BOOT_PARTITION" /mnt/boot || { echo "Error mounting boot partition."; exit 1; }
}

# Function to install base system
install_base_system() {
  echo "Installing base system..."
  pacstrap /mnt base linux linux-firmware base-devel \
    git wget neovim intel-ucode networkmanager openssh sudo htop \
    alacritty gnome gnome-extra i3 fish docker docker-compose \
    xorg xorg-server xorg-apps xorg-xinit net-tools dnsutils \
    zip unzip rsync tree || { echo "Error installing base system."; exit 1; }
}

# Function to generate fstab
generate_fstab() {
  echo "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab
  if [ ! -s /mnt/etc/fstab ]; then
    echo "Error: fstab file is empty."
    exit 1
  fi
}

# Function to configure system
configure_system() {
  echo "Configuring the system..."

  arch-chroot /mnt /bin/bash <<EOF

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Install and configure bootloader
bootctl install

# Configure sudoers
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# Enable services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable docker
systemctl enable gdm

# Set up parallel downloads in pacman
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

# Install yay (AUR helper)
cd /home
git clone https://aur.archlinux.org/yay.git
chown -R $USERNAME:$USERNAME yay
cd yay
sudo -u $USERNAME makepkg -si --noconfirm

# Install AUR packages
sudo -u $USERNAME yay -S --noconfirm visual-studio-code-bin nerd-fonts-jetbrains-mono oh-my-fish

# Install themes and icons
pacman -S --noconfirm arc-gtk-theme papirus-icon-theme

# Install ClamAV and rkhunter
pacman -S --noconfirm clamav rkhunter
systemctl enable clamav-freshclam.service
freshclam

# Configure firewall (UFW)
pacman -S --noconfirm ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw enable

# Set default shell to fish for root
chsh -s /usr/bin/fish

# Enable Wayland for GDM
sed -i 's/#WaylandEnable=false/WaylandEnable=true/' /etc/gdm/custom.conf

EOF
}

# Function to configure bootloader
configure_bootloader() {
  echo "Configuring bootloader..."
  PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PARTITION")
  if [ -z "$PARTUUID" ]; then
    echo "Error: Unable to retrieve PARTUUID for root partition."
    exit 1
  fi

  cat > /mnt/boot/loader/loader.conf <<EOL
default arch.conf
timeout 3
editor 0
EOL

  cat > /mnt/boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=$PARTUUID rw quiet
EOL
}

# Function to create user and set passwords
create_user_and_set_passwords() {
  echo "Creating user and setting passwords..."

  arch-chroot /mnt /bin/bash <<EOF
useradd -m -G wheel,docker -s /usr/bin/fish $USERNAME
EOF

  echo "Set root password:"
  arch-chroot /mnt passwd root

  echo "Set password for $USERNAME:"
  arch-chroot /mnt passwd $USERNAME
}

# Function to finalize installation
finalize_installation() {
  echo "Finalizing installation..."

  # Optionally, clone and apply dotfiles using GNU Stow
  # arch-chroot /mnt /bin/bash <<EOF
  # git clone https://your-dotfiles-repo.git /home/$USERNAME/dotfiles
  # chown -R $USERNAME:$USERNAME /home/$USERNAME/dotfiles
  # cd /home/$USERNAME/dotfiles
  # sudo -u $USERNAME stow */
  # EOF

  # Unmount partitions
  sync
  umount -R /mnt

  read -rp "Installation complete! Reboot now? [Y/n]: " REBOOT
  if [[ "$REBOOT" != "n" && "$REBOOT" != "N" ]]; then
    reboot
  else
    echo "Reboot cancelled. You can reboot manually when ready."
  fi
}

# Main script execution
main() {
  confirm_disk
  check_uefi
  check_internet
  update_clock
  partition_disk
  format_partitions
  mount_partitions
  install_base_system
  generate_fstab
  configure_system
  configure_bootloader
  create_user_and_set_passwords
  finalize_installation
}

# Run the main function
main
