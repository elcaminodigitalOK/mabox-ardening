#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")"
trap on_error ERR

# Redirect outputs to files for easier debugging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log" >&2)

# Dialog
BACKTITLE="Manjaro Hardened Installation"

on_error() {
  ret=$?
  echo "[$0] Error on line $LINENO: $BASH_COMMAND"
  exit $ret
}

get_input() {
  title="$1"
  description="$2"

  input=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --inputbox "$description" 0 0)
  echo "$input"
}

get_password() {
  title="$1"
  description="$2"

  init_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description" 0 0)
  test -z "$init_pass" && echo >&2 "password cannot be empty" && exit 1

  test_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description again" 0 0)
  if [[ "$init_pass" != "$test_pass" ]]; then
    echo "Passwords did not match" >&2
    exit 1
  fi
  echo "$init_pass"
}

get_choice() {
  title="$1"
  description="$2"
  shift 2
  options=("$@")
  dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --menu "$description" 0 0 0 "${options[@]}"
}

# Basic settings
timedatectl set-ntp true
hwclock --systohc --utc

# Keyring from ISO might be outdated, upgrading it just in case
pacman -Sy --noconfirm --needed archlinux-keyring manjaro-keyring

# Make sure some basic tools that will be used in this script are installed
pacman -Sy --noconfirm --needed git reflector terminus-font dialog wget

# Adjust the font size in case the screen is hard to read
noyes=("Yes" "The font is too small" "No" "The font size is just fine")
hidpi=$(get_choice "Font size" "Is your screen HiDPI?" "${noyes[@]}") || exit 1
clear
[[ "$hidpi" == "Yes" ]] && font="ter-132n" || font="ter-716n"
setfont "$font"

# Ask for desktop environment
de_list=("Mabox" "Instalar Mabox con hardening" "None" "Sin entorno gráfico")
de_choice=$(get_choice "Entorno de Escritorio" "Selecciona el entorno de escritorio" "${de_list[@]}") || exit 1
clear

# Setup CPU/GPU target
cpu_list=("Intel" "" "AMD" "")
cpu_target=$(get_choice "Installation" "Select the targetted CPU vendor" "${cpu_list[@]}") || exit 1
clear

noyes=("Yes" "" "No" "")
install_igpu_drivers=$(get_choice "Installation" "Does your CPU have integrated graphics ?" "${noyes[@]}") || exit 1
clear

gpu_list=("Nvidia" "" "AMD" "" "None" "I don't have any GPU")
gpu_target=$(get_choice "Installation" "Select the targetted GPU vendor" "${gpu_list[@]}") || exit 1
clear

# Ask which device to install Manjaro on
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac | tr '\n' ' ')
read -r -a devicelist <<<"$devicelist"
device=$(get_choice "Installation" "Select installation disk" "${devicelist[@]}") || exit 1
clear

noyes=("Yes" "I want to remove everything on $device except /home" "No" "GOD NO !! ABORT MISSION")
lets_go=$(get_choice "Are you absolutely sure ?" "YOU ARE ABOUT TO ERASE EVERYTHING ON $device EXCEPT /home" "${noyes[@]}") || exit 1
clear
[[ "$lets_go" == "No" ]] && exit 1

hostname=$(get_input "Hostname" "Enter hostname") || exit 1
clear
test -z "$hostname" && echo >&2 "hostname cannot be empty" && exit 1

user=$(get_input "User" "Enter username") || exit 1
clear
test -z "$user" && echo >&2 "user cannot be empty" && exit 1

user_password=$(get_password "User" "Enter password") || exit 1
clear
test -z "$user_password" && echo >&2 "user password cannot be empty" && exit 1

luks_password=$(get_password "LUKS" "Enter password") || exit 1
clear
test -z "$luks_password" && echo >&2 "LUKS password cannot be empty" && exit 1

echo "Setting up fastest mirrors..."
reflector --country France,Germany --latest 30 --sort rate --save /etc/pacman.d/mirrorlist
clear

# Setting up partitions
echo "Creating partitions..."
parted -s "${device}" mklabel msdos
parted -s "${device}" mkpart primary 1MiB 512MiB
parted -s "${device}" set 1 boot on
parted -s "${device}" mkpart primary 512MiB 100%

# Format boot partition
mkfs.ext4 "${device}1"

# Setup LUKS on root partition
echo -n "$luks_password" | cryptsetup luksFormat "${device}2"
echo -n "$luks_password" | cryptsetup luksOpen "${device}2" cryptroot

# Setup BTRFS
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@cache
umount /mnt

# Mount subvolumes
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,.snapshots,var,var/lib/docker,var/cache,home}
mount "${device}1" /mnt/boot
mount -o subvol=@snapshots,compress=zstd /dev/mapper/cryptroot /mnt/.snapshots
mount -o subvol=@var,compress=zstd /dev/mapper/cryptroot /mnt/var
mount -o subvol=@docker,compress=zstd /dev/mapper/cryptroot /mnt/var/lib/docker
mount -o subvol=@cache,compress=zstd /dev/mapper/cryptroot /mnt/var/cache

# Mount existing /home partition
mount /dev/sdXN /mnt/home  # Replace /dev/sdXN with the actual device name of your /home partition

# Install base system
pacstrap /mnt base base-devel linux linux-headers linux-firmware btrfs-progs

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configure system
arch-chroot /mnt /bin/bash -c "
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
echo 'es_ES.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=es_ES.UTF-8' > /etc/locale.conf
echo '$hostname' > /etc/hostname
echo '127.0.0.1 localhost' >> /etc/hosts
echo '::1 localhost' >> /etc/hosts
echo '127.0.1.1 $hostname.localdomain $hostname' >> /etc/hosts

# Add Mabox repository
cat <<EOF >> /etc/pacman.conf
[maboxlinux]
SigLevel = Optional TrustAll
Server = http://repo.maboxlinux.org/stable/\$arch/
EOF

# Install Mabox packages
pacman -S --noconfirm \
  mabox-meta-core \
  mabox-meta-desktop \
  mabox-meta-multimedia \
  mabox-common \
  mabox-tools \
  mabox-hotfixes \
  mabox-release \
  mabox-keyring \
  mabox-exo \
  mabox-artwork \
  mabox-themes \
  mabox-themes-eithne \
  mabox-wallpapers-2021 \
  mabox-wallpapers-2020 \
  mabox-wallpapers-2023 \
  mabox-browser-settings \
  mabox-i18n-files \
  mabox-pipemenus \
  mabox-utilities \
  mabox-colorizer \
  mabox-labwc-files \
  mabox-scripts-labwc \
  mabox-gkrellm-themes \
  mabox-pcmanfm-actions \
  mabox-jgtools \
  filesystem \
  mb-jgtools \
  bashrc-mabox
"

# Install and configure bootloader
arch-chroot /mnt pacman -S --noconfirm grub
arch-chroot /mnt grub-install --target=i386-pc "${device}"
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Create user
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$user"
echo "$user:$user_password" | arch-chroot /mnt chpasswd
echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/wheel

# Install base packages
arch-chroot /mnt pacman -S --noconfirm \
  networkmanager \
  apparmor \
  firejail \
  nftables \
  docker \
  keepassxc \
  firefox

# Install Mabox if selected
if [ "$de_choice" = "Mabox" ]; then
  arch-chroot /mnt pacman -S --noconfirm \
    xorg \
    xorg-server \
    mabox-meta-core \
    mabox-meta-desktop \
    mabox-meta-multimedia \
    lightdm \
    lightdm-gtk-greeter

  # Enable LightDM
  arch-chroot /mnt systemctl enable lightdm
fi

# Enable core services
arch-chroot /mnt systemctl enable NetworkManager
arch-chroot /mnt systemctl enable apparmor
arch-chroot /mnt systemctl enable docker
arch-chroot /mnt systemctl enable nftables

echo "Installation completed!"
