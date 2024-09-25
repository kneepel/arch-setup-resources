#!/bin/bash

# Copyright (C) 2021-2024 Thien Tran, Tommaso Chiti
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

set -u

output(){
    printf '\e[1;34m%-6s\e[m\n' "${@}"
}

installation_date=$(date "+%Y-%m-%d %H:%M:%S")

disk_prompt (){
    lsblk
    output 'Please select the number of the corresponding disk (e.g. 1):'
    select entry in $(lsblk -dpnoNAME|grep -P "/dev/sd|nvme|vd");
    do
        disk="${entry}"
        output "Arch Linux will be installed on the following disk: ${disk}"
        break
    done
}

username_prompt (){
    output 'Enter your username:'
    read -r username

    if [ -z "${username}" ]; then
        output 'You need to enter a username.'
        username_prompt
    fi
}

user_password_prompt () {
    output 'Enter your user password (the password will not be shown on the screen):'
    read -r -s user_password

    if [ -z "${user_password}" ]; then
        output 'You need to enter a password.'
        user_password_prompt
    fi

    output 'Confirm your user password (the password will not be shown on the screen):'
    read -r -s user_password2
    if [ "${user_password}" != "${user_password2}" ]; then
        output 'Passwords do not match, please try again.'
        user_password_prompt
    fi
}

hostname_prompt () {
    output 'Enter your hostname:'
    read -r hostname

    if [ -z "${hostname}" ]; then
        output 'You need to enter a hostname.'
        hostname_prompt
    fi
}

# Set locale/kb layout
locale=en_US
kblayout=us

# Cleaning the TTY.
clear

# Initial prompts
disk_prompt
username_prompt
user_password_prompt
hostname_prompt

# Installation

## Do not update the live environment
pacman -Sy

## Installing curl
pacman -S --noconfirm curl

## Wipe the disk
sgdisk --zap-all "${disk}"

## Creating a new partition scheme.
output "Creating new partition scheme on ${disk}."
sgdisk -g "${disk}"
sgdisk -I -n 1:0:+512M -t 1:ef00 -c 1:'ESP' "${disk}"
sgdisk -I -n 2:0:0 -c 2:'rootfs' "${disk}"

ESP='/dev/disk/by-partlabel/ESP'
BTRFS='/dev/disk/by-partlabel/rootfs'

## Informing the Kernel of the changes.
output 'Informing the Kernel about the disk changes.'
partprobe "${disk}"

## Formatting the ESP as FAT32.
output 'Formatting the EFI Partition as FAT32.'
mkfs.fat -F 32 -s 2 "${ESP}"

## Formatting the partition as BTRFS.
output 'Formatting the rootfs as BTRFS.'
mkfs.btrfs -f "${BTRFS}"
mount "${BTRFS}" /mnt

## Creating BTRFS subvolumes.
output 'Creating BTRFS subvolumes.'

btrfs su cr /mnt/@
btrfs su cr /mnt/@/.snapshots
mkdir -p /mnt/@/.snapshots/1
btrfs su cr /mnt/@/.snapshots/1/snapshot
btrfs su cr /mnt/@/boot_grub
btrfs su cr /mnt/@/home
btrfs su cr /mnt/@/root
btrfs su cr /mnt/@/srv
btrfs su cr /mnt/@/opt
btrfs su cr /mnt/@/var
btrfs su cr /mnt/@/tmp
btrfs su cr /mnt/@/usr_local

## Disable CoW on subvols we are not taking snapshots of
chattr +C /mnt/@/boot_grub
chattr +C /mnt/@/home
chattr +C /mnt/@/root
chattr +C /mnt/@/srv
chattr +C /mnt/@/var
chattr +C /mnt/@/opt
chattr +C /mnt/@/tmp
chattr +C /mnt/@/usr_local

## Set the default BTRFS Subvol to Snapshot 1 before pacstrapping
btrfs subvolume set-default "$(btrfs subvolume list /mnt | grep "@/.snapshots/1/snapshot" | grep -oP '(?<=ID )[0-9]+')" /mnt

echo "<?xml version=\"1.0\"?>
<snapshot>
  <type>single</type>
  <num>1</num>
  <date>${installation_date}</date>
  <description>First Root Filesystem</description>
  <cleanup>number</cleanup>
</snapshot>" > /mnt/@/.snapshots/1/info.xml

chmod 600 /mnt/@/.snapshots/1/info.xml

## Mounting the newly created subvolumes.
umount /mnt
output 'Mounting the newly created subvolumes.'
mount -o ssd,noatime,compress=zstd "${BTRFS}" /mnt
mkdir -p /mnt/{root,home,.snapshots,srv,tmp,var,opt,boot/grub,usr/local}
mkdir -p /mnt/{var/lib/machines,var/lib/portables} #to prevent unwanted subvolumes made by systemd-nspawn on boot

mount -o ssd,noatime,compress=zstd,nodev,nosuid,noexec,subvol=@/boot_grub "${BTRFS}" /mnt/boot/grub
mount -o ssd,noatime,compress=zstd,nodev,nosuid,subvol=@/root "${BTRFS}" /mnt/root
mount -o ssd,noatime,compress=zstd,nodev,nosuid,subvol=@/home "${BTRFS}" /mnt/home
mount -o ssd,noatime,compress=zstd,subvol=@/.snapshots "${BTRFS}" /mnt/.snapshots
mount -o ssd,noatime,compress=zstd,subvol=@/srv "${BTRFS}" /mnt/srv
mount -o ssd,noatime,compress=zstd,subvol=@/tmp "${BTRFS}" /mnt/tmp
mount -o ssd,noatime,compress=zstd,subvol=@/opt "${BTRFS}" /mnt/opt
mount -o ssd,noatime,compress=zstd,subvol=@/usr_local "${BTRFS}" /mnt/usr/local
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var "${BTRFS}" /mnt/var

mkdir -p /mnt/efi
mount -o nodev,nosuid,noexec "${ESP}" /mnt/efi

## Pacstrap
output 'Installing the base system (it may take a while).'

output "You may see an error when mkinitcpio tries to generate a new initramfs."
output "It is okay. The script will regenerate the initramfs later in the installation process."

pacstrap /mnt base base-devel chrony efibootmgr grub grub-btrfs inotify-tools linux-firmware linux-zen linux-zen-headers nano reflector snapper zram-generator

CPU=$(grep vendor_id /proc/cpuinfo)

if [[ "${CPU}" == *"AuthenticAMD"* ]]; then
    microcode=amd-ucode
else
    microcode=intel-ucode
fi

pacstrap /mnt "${microcode}"

pacstrap /mnt networkmanager 

pacstrap /mnt plasma-meta sddm konsole kwrite dolphin ark plasma-workspace egl-wayland xdg-desktop-portal-gtk flatpak pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber libpulse gst-plugin-pipewire bluez openssh

## Install snap-pac list otherwise we will have problems
pacstrap /mnt snap-pac

## Generate /etc/fstab.
output 'Generating a new fstab.'
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's#,subvolid=258,subvol=/@/.snapshots/1/snapshot,subvol=@/.snapshots/1/snapshot##g' /mnt/etc/fstab

output 'Setting up hostname, locale and keyboard layout' 

## Set hostname.
echo "$hostname" > /mnt/etc/hostname

## Setting hosts file.
echo 'Setting hosts file.'
echo "127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname" > /mnt/etc/hosts

## Setup locales.
echo "$locale.UTF-8 UTF-8"  > /mnt/etc/locale.gen
echo "LANG=$locale.UTF-8" > /mnt/etc/locale.conf

## Setup keyboard layout.
echo "KEYMAP=$kblayout" > /mnt/etc/vconsole.conf

## Configure /etc/mkinitcpio.conf
output 'Configuring /etc/mkinitcpio for ZSTD compression'
sed -i 's/#COMPRESSION="zstd"/COMPRESSION="zstd"/g' /mnt/etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(btrfs)/g' /mnt/etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect microcode modconf keyboard sd-vconsole block grub-btrfs-overlayfs)/g' /mnt/etc/mkinitcpio.conf

## Do not preload part_msdos
sed -i 's/ part_msdos//g' /mnt/etc/default/grub

## Ensure correct GRUB settings
echo '' >> /mnt/etc/default/grub
echo '# Booting with BTRFS subvolume
GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=true' >> /mnt/etc/default/grub

## Disable root subvol pinning.
## This is **extremely** important, as snapper expects to be able to set the default btrfs subvol.
# shellcheck disable=SC2016
sed -i 's/rootflags=subvol=${rootsubvol}//g' /mnt/etc/grub.d/10_linux
# shellcheck disable=SC2016
sed -i 's/rootflags=subvol=${rootsubvol}//g' /mnt/etc/grub.d/20_linux_xen

#set kernel parameters
sed -i "s#quiet#root=${BTRFS} quiet splash intel_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff#g" /mnt/etc/default/grub

## Setup NTS
cat > /mnt/etc/chrony.conf <<EOF
server time.cloudflare.com iburst nts
server ntppool1.time.nl iburst nts
server nts.netnod.se iburst nts
server ptbtime1.ptb.de iburst nts
server time.dfm.dk iburst nts
server time.cifelli.xyz iburst nts

minsources 3
authselectmode require

# EF
dscp 46

driftfile /var/lib/chrony/drift
ntsdumpdir /var/lib/chrony

leapsectz right/UTC
makestep 1.0 3

rtconutc
rtcsync

cmdport 0

noclientlog
EOF

## ZRAM configuration
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram, 8192)
EOF

## Setup Networking

cat > /mnt/etc/NetworkManager/conf.d/01-transient-hostname.conf <<EOF
[main]
hostname-mode=none
EOF

## Configuring the system.
arch-chroot /mnt /bin/bash -e <<EOF

    # Setting up timezone
    # Temporarily hardcoding here
    ln -sf /usr/share/zoneinfo/America/Vancouver /etc/localtime

    # Setting up clock
    hwclock --systohc

    # Generating locales
    locale-gen

    # Generating a new initramfs
    chmod 600 /boot/initramfs-linux*
    mkinitcpio -P

    # Installing GRUB
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --disable-shim-lock

    # Creating grub config file
    grub-mkconfig -o /boot/grub/grub.cfg

    # Adding user with sudo privilege
    useradd -m $username
    usermod -aG wheel $username

    # Snapper configuration
    umount /.snapshots
    sleep 5
    rm -r /.snapshots
    snapper --no-dbus -c root create-config /
    snapper --no-dbus set-config TIMELINE_LIMIT_HOURLY=6
    snapper --no-dbus set-config TIMELINE_LIMIT_DAILY=7
    snapper --no-dbus set-config TIMELINE_LIMIT_WEEKLY=0
    snapper --no-dbus set-config TIMELINE_LIMIT_MONTHLY=0
    snapper --no-dbus set-config TIMELINE_LIMIT_YEARLY=0
    btrfs subvolume delete /.snapshots --commit-after
    mkdir /.snapshots
    mount -a
    chmod 750 /.snapshots 
EOF

## Set user password.
[ -n "$username" ] && echo "Setting user password for ${username}." && echo -e "${user_password}\n${user_password}" | arch-chroot /mnt passwd "$username"

## Give wheel user sudo access.
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' /mnt/etc/sudoers

# Pacman eye-candy features.
output "Enabling colours, animations, and parallel downloads for pacman."
sed -Ei 's/^#(Color)$/\1\nILoveCandy/;s/^#(ParallelDownloads).*/\1 = 10/' /mnt/etc/pacman.conf

## Enable services
systemctl enable chronyd --root=/mnt
systemctl enable fstrim.timer --root=/mnt
systemctl enable grub-btrfsd.service --root=/mnt
systemctl enable reflector.timer --root=/mnt
systemctl enable snapper-timeline.timer --root=/mnt
systemctl enable snapper-cleanup.timer --root=/mnt
systemctl disable systemd-timesyncd --root=/mnt
systemctl enable NetworkManager --root=/mnt
systemctl enable iptables --root=/mnt
systemctl enable sddm.service --root=/mnt 
systemctl enable systemd-resolved --root=/mnt
systemctl enable sshd --root=/mnt


## Set umask to 077.
sed -i 's/^UMASK.*/UMASK 077/g' /mnt/etc/login.defs
sed -i 's/^HOME_MODE/#HOME_MODE/g' /mnt/etc/login.defs
sed -i 's/umask 022/umask 077/g' /mnt/etc/bash.bashrc

# Finish up
echo "Install script finished - Reboot or chroot into /mnt for more changes"
exit
